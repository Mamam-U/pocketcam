import Foundation
import Network
import CoreImage
import CoreMedia
import Darwin

/// 局域网监看：零依赖 HTTP 服务器（Network.framework）。
/// /         → 网页（内嵌 <img src="/stream">）
/// /stream   → MJPEG 实时流（multipart/x-mixed-replace）
/// /status   → JSON 状态
final class MJpegHttpServer: ObservableObject {
    @Published private(set) var isRunning = false
    @Published private(set) var serverURL = ""

    private weak var recorder: CameraRecorder?
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "pocketcam.http")
    private let ciContext = CIContext()

    private var streamConnections: [NWConnection] = []
    private var ticker: DispatchSourceTimer?
    private let boundary = "pocketcam"

    init(recorder: CameraRecorder) {
        self.recorder = recorder
    }

    // MARK: - 生命周期

    func start() {
        guard listener == nil else { return }
        guard let port = NWEndpoint.Port(rawValue: Config.httpPort) else { return }
        do {
            let l = try NWListener(using: .tcp, on: port)
            l.newConnectionHandler = { [weak self] connection in
                self?.handle(connection)
            }
            l.stateUpdateHandler = { [weak self] state in
                DispatchQueue.main.async {
                    switch state {
                    case .ready:
                        self?.isRunning = true
                        if let ip = Self.localIPAddress() {
                            self?.serverURL = "http://\(ip):\(Config.httpPort)"
                        }
                    case .failed, .cancelled:
                        self?.isRunning = false
                    default:
                        break
                    }
                }
            }
            l.start(queue: queue)
            listener = l
        } catch {
            print("[Server] 启动失败: \(error.localizedDescription)")
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        ticker?.cancel()
        ticker = nil
        streamConnections.removeAll()
        DispatchQueue.main.async { self.isRunning = false }
    }

    // MARK: - 请求解析

    private struct Request {
        let method: String
        let path: String
    }

    private func handle(_ connection: NWConnection) {
        connection.start(queue: queue)
        receiveRequest(connection, data: Data())
    }

    private func receiveRequest(_ connection: NWConnection, data: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] content, _, isComplete, error in
            guard let self else { return }
            var acc = data
            if let content { acc.append(content) }
            if let error {
                connection.cancel()
                return
            }
            if let request = Self.parseRequest(acc) {
                self.respond(to: request, on: connection)
            } else if isComplete {
                connection.cancel()
            } else {
                self.receiveRequest(connection, data: acc)
            }
        }
    }

    private static func parseRequest(_ data: Data) -> Request? {
        guard let text = String(data: data, encoding: .utf8) else { return nil }
        guard let first = text.split(separator: "\r\n", omittingEmptySubsequences: false).first else { return nil }
        let parts = first.split(separator: " ")
        guard parts.count >= 2 else { return nil }
        let method = String(parts[0])
        let path = String(parts[1]).split(separator: "?").first.map(String.init) ?? ""
        return Request(method: method, path: path)
    }

    private func respond(to request: Request, on connection: NWConnection) {
        switch request.path {
        case "/":
            sendHTML(connection)
        case "/stream":
            startStream(connection)
        case "/status":
            sendStatus(connection)
        default:
            sendRaw(connection, status: "404 Not Found",
                    contentType: "text/plain; charset=utf-8", body: "not found")
        }
    }

    // MARK: - 响应

    private func sendHTML(_ connection: NWConnection) {
        let html = """
        <!DOCTYPE html>
        <html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
        <title>PocketCam</title></head>
        <body style="margin:0;background:#000;color:#fff;font-family:system-ui,-apple-system,sans-serif;text-align:center">
        <h3 style="margin:10px 0 6px;font-weight:600">PocketCam 实时画面</h3>
        <img src="/stream" style="width:100%;max-width:720px;display:block;margin:0 auto" alt="live">
        </body></html>
        """
        sendRaw(connection, status: "200 OK", contentType: "text/html; charset=utf-8", body: html)
    }

    private func sendStatus(_ connection: NWConnection) {
        let body = """
        {"recording":\(recorder?.state == .recording ? "true" : "false"),"storedBytes":\(recorder?.storedBytes ?? 0)}
        """
        sendRaw(connection, status: "200 OK", contentType: "application/json", body: body)
    }

    private func startStream(_ connection: NWConnection) {
        let head = "HTTP/1.1 200 OK\r\nContent-Type: multipart/x-mixed-replace; boundary=\(boundary)\r\nConnection: keep-alive\r\nCache-Control: no-cache\r\n\r\n"
        connection.send(content: Data(head.utf8), completion: .contentProcessed { [weak self] _ in
            guard let self else { return }
            self.queue.async {
                self.streamConnections.append(connection)
                connection.stateUpdateHandler = { [weak self] state in
                    switch state {
                    case .cancelled, .failed:
                        self?.removeStream(connection)
                    default: break
                    }
                }
                self.ensureTicker()
            }
        })
    }

    private func ensureTicker() {
        guard ticker == nil else { return }
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now(), repeating: Config.jpegInterval)
        t.setEventHandler { [weak self] in
            self?.pushFrameToAll()
        }
        t.resume()
        ticker = t
    }

    private func removeStream(_ connection: NWConnection) {
        streamConnections.removeAll { $0 === connection }
        if streamConnections.isEmpty {
            ticker?.cancel()
            ticker = nil
        }
    }

    private func pushFrameToAll() {
        guard let frame = currentJPEG() else { return }
        for connection in streamConnections {
            let part = "--\(boundary)\r\nContent-Type: image/jpeg\r\nContent-Length: \(frame.count)\r\n\r\n"
            var payload = Data(part.utf8)
            payload.append(frame)
            payload.append(Data("\r\n".utf8))
            connection.send(content: payload, completion: .contentProcessed { _ in })
        }
    }

    private func currentJPEG() -> Data? {
        guard let buffer = recorder?.latestSampleBuffer,
              let pixelBuffer = CMSampleBufferGetImageBuffer(buffer) else { return nil }
        let image = CIImage(cvPixelBuffer: pixelBuffer)
        return ciContext.jpegRepresentation(of: image,
                                            colorSpace: CGColorSpaceCreateDeviceRGB(),
                                            options: [:])
    }

    // MARK: - 工具

    private func sendRaw(_ connection: NWConnection, status: String,
                         contentType: String, body: String) {
        let response = "HTTP/1.1 \(status)\r\nContent-Type: \(contentType)\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
        connection.send(content: Data(response.utf8), completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private static func localIPAddress() -> String? {
        var result: String?
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let interface = ptr.pointee
            let family = interface.ifa_addr.pointee.sa_family
            if family == UInt8(AF_INET) {
                let name = String(cString: interface.ifa_name)
                if name == "en0" || name == "en1" {
                    var host = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
                    var addr = interface.ifa_addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                        $0.pointee.sin_addr
                    }
                    inet_ntop(AF_INET, &addr, &host, socklen_t(host.count))
                    result = String(cString: host)
                }
            }
        }
        return result
    }
}
