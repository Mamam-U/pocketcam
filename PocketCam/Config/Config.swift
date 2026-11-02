import Foundation

/// 全局可调参数。Phase 0 先用固定值，后续做成设置页。
enum Config {
    /// 每段录制时长（秒）。循环录制按段切文件，方便覆盖删除。
    static let segmentDuration: TimeInterval = 300
    /// 环形存储总容量（字节）。超出后自动删除最老的段。
    static let maxStorageBytes: Int64 = 8 * 1024 * 1024 * 1024
    /// 录像分辨率
    static let videoWidth: Int32 = 1920
    static let videoHeight: Int32 = 1080
    /// 录像帧率
    static let videoFPS: Int32 = 30
    /// H.264 码率（bps）。1080p 5Mbps 约 2.2GB/小时，8GB 约可存 3.5 小时。
    static let videoBitrate: Int = 5_000_000
    /// 音频码率与采样率
    static let audioBitrate: Int = 128_000
    static let audioSampleRate: Double = 44_100
    /// 局域网监看 HTTP 端口
    static let httpPort: UInt16 = 8080
    /// MJPEG 推送间隔（秒）。越小越流畅、越耗电。
    static let jpegInterval: TimeInterval = 0.4
}
