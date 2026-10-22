import Foundation

/// app/Resources/release.json: the reviewed inputs this build installs.
struct Release: Decodable {
    struct Source: Decodable { let name: String }
    let appVersion: String
    let runtimeVersion: String
    let runtimeArchive: String
    let runtimeSHA256: String
    let runtimeSource: Source
    let steamInstallerURL: String
    let steamInstallerSHA256: String
}

struct SetupFailure: Error {
    let code: String
    var message: String {
        switch code {
        case "cancelled": return "Setup is paused. Continue when you’re ready; completed steps are kept."
        case "apple_silicon_required": return "\(Brand.name) needs a Mac with Apple Silicon (M1 or later)."
        case "rosetta_required": return "Steam and Raft are Intel programs, so they need Rosetta. Choose Install Rosetta and follow Apple’s instructions, then try again."
        case "unsupported_volume_format": return "This drive’s format isn’t supported. Use a drive formatted as APFS or Mac OS Extended."
        case "case_sensitive_volume": return "This drive is case-sensitive, which Windows games don’t support."
        case "read_only_volume": return "The install location is read-only."
        case "insufficient_disk_space": return "There isn’t enough free storage to finish this step. Free some space, then try again."
        case "close_steam_before_maintenance", "close_steam_before_setup", "environment_initialization_busy": return "Close Steam and Raft, then try again."
        case "close_raft_before_maintenance", "close_raft_before_uninstall": return "Raft is running. Quit the game, then try again."
        case "setup_already_running": return "Another setup step is finishing. Wait a moment, then try again."
        case "download_failed": return "The download didn’t finish. Check your internet connection, then try again."
        case "download_hash_mismatch", "steam_installer_hash_mismatch": return "Valve’s Steam installer differs from the one this version of \(Brand.name) was checked against, so it wasn’t run. A newer \(Brand.name) will expect the new installer."
        case "archive_hash_mismatch", "runtime_file_hash_mismatch", "runtime_missing", "runtime_unlisted_file", "release_unavailable": return "A component of \(Brand.name) is missing or damaged. Rebuild or reinstall the app; your games and sign-in are kept."
        case "steam_update_failed": return "Steam couldn’t finish updating itself. Check your internet connection, then try again."
        case "steam_install_failed": return "Steam’s installer didn’t finish. Try again; if it keeps failing, save a report from the Help menu."
        case "webhelper_fix_missing", "webhelper_fix_install_failed": return "\(Brand.name) couldn’t put its Steam display fix in place, so Steam’s windows would be black. Rebuild the app, then try again."
        case "directory_not_owned_by_app", "invalid_ownership_marker", "existing_environment_not_owned": return "The data folder holds files \(Brand.name) didn’t create. Nothing was changed."
        case "session_check_failed", "session_membership_unknown": return "\(Brand.name) couldn’t check what’s running. Quit Steam normally, then try again."
        case "steam_close_failed": return "Steam couldn’t be closed. Use Force Quit in Settings, then try again."
        case "uninstall_move_failed": return "The data folder couldn’t be moved to the Trash. Nothing was deleted."
        default: return "This step couldn’t finish. Try again, or save a report from the Help menu. Your games and sign-in are kept."
        }
    }
}

/// Runs the native worker (scripts/raft_setup.m) off the main thread. Each invocation owns the
/// installation lock; its output is bounded JSON events, never raw Wine logs.
@MainActor
final class SetupService {
    let root: URL
    let helper: URL
    private var process: Process?
    private var cancelRequested=false
    init(root: URL, helper: URL) { self.root=root; self.helper=helper }
    func cancel() { cancelRequested=true; if process?.isRunning == true { process?.terminate() } }
    func run(_ command: String, _ args: [String] = [], event: @escaping @MainActor ([String:Any])->Void = { _ in }) async throws -> [[String:Any]] {
        // One worker at a time: a session check in flight finishes before the next command.
        while process != nil { try await Task.sleep(for:.milliseconds(100)) }
        let p=Process(), pipe=Pipe()
        p.executableURL=helper; p.arguments=[command,"--root",root.path]+args
        p.standardOutput=pipe; p.standardError=FileHandle.nullDevice
        p.environment=["PATH":"/usr/bin:/bin:/usr/sbin:/sbin","HOME":NSHomeDirectory()]
        process=p; cancelRequested=false
        defer { process=nil }
        return try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos:.userInitiated).async {
                do { try p.run() }
                catch { continuation.resume(throwing:SetupFailure(code:"process_launch_failed")); return }
                Task { @MainActor in if self.cancelRequested && self.process === p { self.cancel() } }
                var pending=Data(), events=[[String:Any]](), oversized=false
                while true {
                    let data=pipe.fileHandleForReading.availableData
                    if data.isEmpty { break }
                    pending.append(data)
                    if pending.count > 65536 { oversized=true; p.terminate(); break }
                    while let end=pending.firstIndex(of:10) {
                        let line=pending[..<end]; pending.removeSubrange(...end)
                        if let value=(try? JSONSerialization.jsonObject(with:Data(line))) as? [String:Any] {
                            events.append(value)
                            if events.count>256 { events.removeFirst() }
                            Task { @MainActor in event(value) }
                        }
                    }
                }
                p.waitUntilExit()
                try? pipe.fileHandleForReading.close()
                if let error=events.last(where:{ $0["stage"] as? String == "error" })?["code"] as? String {
                    continuation.resume(throwing:SetupFailure(code:error))
                } else if p.terminationStatus != 0 || oversized {
                    continuation.resume(throwing:SetupFailure(code:p.terminationReason == .uncaughtSignal ? "cancelled" : "process_failed"))
                } else { continuation.resume(returning:events) }
            }
        }
    }
}
