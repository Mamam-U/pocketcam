import AVFoundation
import Combine
import UIKit

/// 循环录制引擎：AVCaptureSession 采集 → AVAssetWriter 分段落盘 → 环形覆盖。
final class CameraRecorder: NSObject, ObservableObject {
    enum State: Equatable {
        case idle
        case preparing
        case recording
        case paused
        case failed(String)
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var currentSegmentDuration: TimeInterval = 0
    @Published private(set) var storedBytes: Int64 = 0

    let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(label: "pocketcam.session")
    private let writerQueue = DispatchQueue(label: "pocketcam.writer")
    private let keepAlive = BackgroundAudioKeepAlive()
    private let storage = LoopStorage()

    private var videoOutput: AVCaptureVideoDataOutput?
    private var audioOutput: AVCaptureAudioDataOutput?

    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var audioInput: AVAssetWriterInput?
    private var isWriting = false
    private var sessionStarted = false
    private var segmentFileURL: URL?

    private var segmentTimer: Timer?

    /// MJPEG 服务器从这里取最新视频帧。
    private(set) var latestSampleBuffer: CMSampleBuffer?

    override init() {
        super.init()
        observeInterruptions()
        storedBytes = storage.totalSize()
    }

    // MARK: - 对外控制

    func start() {
        guard state == .idle || state == .paused else { return }
        DispatchQueue.main.async { self.state = .preparing }
        keepAlive.start()
        sessionQueue.async { [weak self] in
            guard let self else { return }
            do {
                try self.configureSessionIfNeeded()
                if !self.session.isRunning {
                    self.session.startRunning()
                }
                DispatchQueue.main.async {
                    self.state = .recording
                    self.startSegmentTimer()
                }
                self.beginNewSegment()
            } catch {
                DispatchQueue.main.async { self.state = .failed(error.localizedDescription) }
            }
        }
    }

    func stop() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.segmentTimer?.invalidate()
            self.segmentTimer = nil
        }
        sessionQueue.async { [weak self] in
            guard let self else { return }
            if self.session.isRunning {
                self.session.stopRunning()
            }
            self.writerQueue.sync { self.finishCurrentWriter() }
            DispatchQueue.main.async {
                self.currentSegmentDuration = 0
                self.state = .idle
            }
        }
        keepAlive.stop()
    }

    func requestPermissions() async -> Bool {
        let camera = await AVCaptureDevice.requestAccess(for: .video)
        let mic = await AVCaptureDevice.requestAccess(for: .audio)
        return camera && mic
    }

    // MARK: - 采集配置

    private func configureSessionIfNeeded() throws {
        guard videoOutput == nil else { return }
        session.beginConfiguration()
        defer { session.commitConfiguration() }

        session.sessionPreset = .hd1920x1080
        session.automaticallyConfiguresApplicationAudioSession = false

        guard let camera = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back)
            ?? AVCaptureDevice.default(for: .video) else {
            throw RecorderError.noCamera
        }
        let cameraInput = try AVCaptureDeviceInput(device: camera)
        if session.canAddInput(cameraInput) {
            session.addInput(cameraInput)
        }

        if let mic = AVCaptureDevice.default(for: .audio),
           let micInput = try? AVCaptureDeviceInput(device: mic),
           session.canAddInput(micInput) {
            session.addInput(micInput)
        }

        let vOut = AVCaptureVideoDataOutput()
        vOut.alwaysDiscardsLateVideoFrames = true
        vOut.videoSettings = [kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA]
        if session.canAddOutput(vOut) {
            session.addOutput(vOut)
            vOut.setSampleBufferDelegate(self, queue: sessionQueue)
            videoOutput = vOut
        }

        let aOut = AVCaptureAudioDataOutput()
        if session.canAddOutput(aOut) {
            session.addOutput(aOut)
            aOut.setSampleBufferDelegate(self, queue: sessionQueue)
            audioOutput = aOut
        }

        if let connection = vOut.connection(with: .video),
           connection.isVideoOrientationSupported {
            connection.videoOrientation = .portrait
        }
    }

    // MARK: - 分段录制

    private func beginNewSegment() {
        writerQueue.async { [weak self] in
            guard let self else { return }
            self.finishCurrentWriter()
            self.startNewWriter()
        }
    }

    private func startNewWriter() {
        let url = storage.nextSegmentURL()
        segmentFileURL = url
        do {
            let w = try AVAssetWriter(outputURL: url, fileType: .mp4)

            let videoSettings: [String: Any] = [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: Config.videoWidth,
                AVVideoHeightKey: Config.videoHeight,
                AVVideoCompressionPropertiesKey: [
                    AVVideoAverageBitRateKey: Config.videoBitrate,
                    AVVideoProfileLevelKey: AVVideoProfileLevelH264MainAutoLevel,
                ] as [String: Any],
            ]
            let vIn = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
            vIn.expectsMediaDataInRealTime = true

            let audioSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVNumberOfChannelsKey: 1,
                AVSampleRateKey: Config.audioSampleRate,
                AVEncoderBitRateKey: Config.audioBitrate,
            ]
            let aIn = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
            aIn.expectsMediaDataInRealTime = true

            if w.canAdd(vIn) { w.add(vIn) }
            if w.canAdd(aIn) { w.add(aIn) }

            writer = w
            videoInput = vIn
            audioInput = aIn
            isWriting = true
            sessionStarted = false
        } catch {
            DispatchQueue.main.async {
                self.state = .failed("创建写入器失败: \(error.localizedDescription)")
            }
        }
    }

    private func finishCurrentWriter() {
        guard let writer, let vIn = videoInput, let aIn = audioInput else { return }
        isWriting = false
        vIn.markAsFinished()
        aIn.markAsFinished()
        let finishedURL = segmentFileURL
        if writer.status == .writing {
            writer.finishWriting { [weak self] in
                guard let self else { return }
                if let finishedURL {
                    self.storage.pruneIfNeeded()
                    let total = self.storage.totalSize()
                    DispatchQueue.main.async { self.storedBytes = total }
                }
            }
        }
        self.writer = nil
        self.videoInput = nil
        self.audioInput = nil
        self.segmentFileURL = nil
    }

    private func startSegmentTimer() {
        segmentTimer?.invalidate()
        currentSegmentDuration = 0
        let timer = Timer(timeInterval: 1.0, repeats: true) { [weak self] _ in
            guard let self else { return }
            if self.state == .recording {
                self.currentSegmentDuration += 1
                if self.currentSegmentDuration >= Config.segmentDuration {
                    self.currentSegmentDuration = 0
                    self.beginNewSegment()
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        segmentTimer = timer
    }

    // MARK: - 中断处理（来电 / 控制中心等）

    private func observeInterruptions() {
        NotificationCenter.default.addObserver(self, selector: #selector(sessionInterrupted(_:)),
                                               name: .AVCaptureSessionWasInterrupted, object: session)
        NotificationCenter.default.addObserver(self, selector: #selector(sessionInterruptionEnded(_:)),
                                               name: .AVCaptureSessionInterruptionEnded, object: session)
    }

    @objc private func sessionInterrupted(_ notification: Notification) {
        writerQueue.sync { isWriting = false }
        DispatchQueue.main.async {
            if self.state == .recording {
                self.state = .paused
            }
        }
    }

    @objc private func sessionInterruptionEnded(_ notification: Notification) {
        DispatchQueue.main.async {
            if self.state == .paused {
                self.state = .recording
                self.beginNewSegment()
            }
        }
    }
}

enum RecorderError: LocalizedError {
    case noCamera

    var errorDescription: String? {
        switch self {
        case .noCamera:
            return "未找到可用摄像头"
        }
    }
}

// MARK: - Sample Buffer 输出

extension CameraRecorder: AVCaptureVideoDataOutputSampleBufferDelegate,
                          AVCaptureAudioDataOutputSampleBufferDelegate {
    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard isWriting, writer != nil else { return }
        if output === videoOutput {
            latestSampleBuffer = sampleBuffer
            append(sampleBuffer, to: videoInput)
        } else if output === audioOutput {
            append(sampleBuffer, to: audioInput)
        }
    }

    private func append(_ sampleBuffer: CMSampleBuffer, to input: AVAssetWriterInput?) {
        guard let input, let writer, input.isReadyForMoreMediaData else { return }
        writerQueue.sync {
            guard isWriting, writer.status == .writing || writer.status == .unknown else { return }
            if !sessionStarted {
                writer.startWriting()
                writer.startSession(atSourceTime: sampleBuffer.presentationTimeStamp)
                sessionStarted = true
            }
            if sessionStarted {
                input.append(sampleBuffer)
            }
        }
    }
}
