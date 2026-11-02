import Foundation

/// 环形存储：录像段写入 Documents/Recordings，超过配额自动删除最老的段。
final class LoopStorage {
    let rootURL: URL
    private let fm = FileManager.default

    init(rootURL: URL? = nil) {
        let base = rootURL ?? fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let url = base.appendingPathComponent("Recordings", isDirectory: true)
        try? fm.createDirectory(at: url, withIntermediateDirectories: true)
        self.rootURL = url
    }

    func nextSegmentURL() -> URL {
        let name = "seg-\(Self.dateFormatter.string(from: Date())).mp4"
        return rootURL.appendingPathComponent(name)
    }

    func segmentURLs() -> [URL] {
        let urls = (try? fm.contentsOfDirectory(at: rootURL,
                                                includingPropertiesForKeys: [.contentModificationDateKey],
                                                options: [.skipsHiddenFiles])) ?? []
        return urls.filter { $0.pathExtension.lowercased() == "mp4" }
    }

    func fileSize(at url: URL) -> Int64 {
        let attrs = try? fm.attributesOfItem(atPath: url.path)
        return (attrs?[.size] as? NSNumber)?.int64Value ?? 0
    }

    func totalSize() -> Int64 {
        segmentURLs().reduce(0) { $0 + fileSize(at: $1) }
    }

    /// 从最老的段开始删除，直到总容量不超过 maxBytes。
    func pruneIfNeeded(maxBytes: Int64 = Config.maxStorageBytes) {
        var urls = segmentURLs().sorted { $0.modDate < $1.modDate }
        var total = urls.reduce(0) { $0 + fileSize(at: $1) }
        while total > maxBytes, let oldest = urls.first {
            total -= fileSize(at: oldest)
            try? fm.removeItem(at: oldest)
            urls.removeFirst()
        }
    }

    private static let dateFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
}

private extension URL {
    var modDate: Date {
        let values = try? resourceValues(forKeys: [.contentModificationDateKey])
        return values?.contentModificationDate ?? .distantPast
    }
}
