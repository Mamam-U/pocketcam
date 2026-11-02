import AVFoundation

/// 后台保活：播放一段静音音频（配合 Info.plist 的 UIBackgroundModes=audio），
/// 让 App 锁屏 / 切后台后不被挂起，摄像头采集得以继续。
/// 这是 iPhone 行车记录 / 监控类 App 的标准做法。
final class BackgroundAudioKeepAlive {
    private var player: AVAudioPlayer?

    func start() {
        guard player == nil else { return }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playAndRecord, mode: .default,
                                    options: [.mixWithOthers, .defaultToSpeaker])
            try session.setActive(true)
            let url = try makeSilentWAV()
            let p = try AVAudioPlayer(contentsOf: url)
            p.volume = 0.01
            p.numberOfLoops = -1
            p.play()
            player = p
        } catch {
            print("[KeepAlive] 启动失败: \(error.localizedDescription)")
        }
    }

    func stop() {
        player?.stop()
        player = nil
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    /// 生成 1 秒 8kHz 单声道 16bit 静音 WAV（写入 tmp，仅生成一次）。
    private func makeSilentWAV() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("pocketcam-silence.wav")
        if FileManager.default.fileExists(atPath: url.path) { return url }

        let sampleRate: UInt32 = 8000
        let seconds: UInt32 = 1
        let dataSize = sampleRate * seconds * 2 // 16bit 单声道

        var h = Data()
        func u16(_ v: UInt16) { var x = v.littleEndian; withUnsafeBytes(of: &x) { h.append(contentsOf: $0) } }
        func u32(_ v: UInt32) { var x = v.littleEndian; withUnsafeBytes(of: &x) { h.append(contentsOf: $0) } }

        h.append(contentsOf: Array("RIFF".utf8))
        u32(36 + dataSize)
        h.append(contentsOf: Array("WAVE".utf8))
        h.append(contentsOf: Array("fmt ".utf8))
        u32(16)
        u16(1)          // PCM
        u16(1)          // mono
        u32(sampleRate)
        u32(sampleRate * 2) // byte rate
        u16(2)          // block align
        u16(16)         // bits per sample
        h.append(contentsOf: Array("data".utf8))
        u32(dataSize)

        var full = h
        full.append(Data(repeating: 0, count: Int(dataSize)))
        try full.write(to: url)
        return url
    }
}
