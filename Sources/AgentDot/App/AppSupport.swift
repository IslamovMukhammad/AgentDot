import Foundation

/// `~/Library/Application Support/AgentDot/` (0700): the socket, the hook token, the hook
/// scripts and the small caches live here, readable by you only.
enum AppSupport {
    static let name = "AgentDot"

    static let directory: URL = {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: dir.path)
        return dir
    }()

    /// Small JSON caches (plan limits, the usage index). Written atomically, off the main thread.
    nonisolated static func write(_ data: Data, to url: URL) {
        DispatchQueue.global(qos: .utility).async {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: url, options: .atomic)
        }
    }
}
