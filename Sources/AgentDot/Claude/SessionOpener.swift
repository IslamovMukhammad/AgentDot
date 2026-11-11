//  "Open ›" brings forward the app a session runs in. The session is matched to a `claude`
//  process by its working folder (cwd), then the parent processes are walked up to the first
//  app with windows (the Claude desktop app or a terminal).
//
//  Limit: a specific tab inside the Claude desktop app can't be picked; the app itself comes
//  forward.

import AppKit
import Darwin

enum SessionOpener {

    static func open(cwd: String?) {
        DispatchQueue.global(qos: .userInitiated).async {
            let pid = cwd.flatMap(ownerAppPID(forCwd:))
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    let app = pid.flatMap { NSRunningApplication(processIdentifier: $0) }
                        ?? NSRunningApplication.runningApplications(withBundleIdentifier: "com.anthropic.claudefordesktop").first
                    app?.activate()
                }
            }
        }
    }

    /// From the `claude` process with a matching cwd, up to the first regular (Dock) app.
    nonisolated private static func ownerAppPID(forCwd cwd: String) -> pid_t? {
        for pid in allPIDs() where name(of: pid) == "claude" && workingDirectory(of: pid) == cwd {
            var current = pid
            for _ in 0..<24 {
                guard let parent = parentPID(of: current), parent > 1 else { break }
                if let app = NSRunningApplication(processIdentifier: parent), app.activationPolicy == .regular {
                    return parent
                }
                current = parent
            }
        }
        return nil
    }

    nonisolated private static func allPIDs() -> [pid_t] {
        let count = proc_listallpids(nil, 0)
        guard count > 0 else { return [] }
        var pids = [pid_t](repeating: 0, count: Int(count) * 2)
        let filled = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        return Array(pids.prefix(Int(max(0, filled))))
    }

    nonisolated private static func name(of pid: pid_t) -> String {
        var buffer = [CChar](repeating: 0, count: 256)
        proc_name(pid, &buffer, UInt32(buffer.count))
        let bytes = buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self)
    }

    nonisolated private static func parentPID(of pid: pid_t) -> pid_t? {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return nil }
        return pid_t(info.pbi_ppid)
    }

    nonisolated private static func workingDirectory(of pid: pid_t) -> String? {
        var info = proc_vnodepathinfo()
        let size = Int32(MemoryLayout<proc_vnodepathinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDVNODEPATHINFO, 0, &info, size) == size else { return nil }
        return withUnsafePointer(to: info.pvi_cdir.vip_path) { pointer in
            pointer.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
        }
    }
}
