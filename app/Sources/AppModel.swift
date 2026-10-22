import AppKit
import SwiftUI
import Observation

@MainActor @Observable
final class AppModel {
    enum Screen: String { case welcome, checking, preparing, launching, ready, running, failure }
    enum Sheet: String, Identifiable { case settings, about; var id: String { rawValue } }
    var screen: Screen = .welcome
    var sheet: Sheet?
    /// Settings' Uninstall confirmation is showing.
    var confirmUninstall=false
    var busy=false
    var stage=""
    var notice=""
    var failure=SetupFailure(code:"")
    var steamInstalled=false
    var gameInstalled=false
    var webhelperFix=false
    var state=[String:Any]()
    /// What runs now, as the last session check found it.
    enum Running: Equatable { case steam, game }
    var running: Running?
    let release: Release?
    let root: URL
    let service: SetupService
    private var started=false
    private var watch: Task<Void,Never>?
    /// Opening the app opens Steam too, once setup is done. Off, the player uses Open Steam.
    var openSteamAtLaunch=UserDefaults.standard.object(forKey:"openSteamAtLaunch") as? Bool ?? true {
        didSet { UserDefaults.standard.set(openSteamAtLaunch,forKey:"openSteamAtLaunch") }
    }
    /// Apple's Metal Performance HUD over Raft (worker: launch --metal-hud 1). Steam starts the
    /// game with its own environment, so it changes the next time Steam opens.
    var metalHUD=UserDefaults.standard.bool(forKey:"metalHUD") {
        didSet { UserDefaults.standard.set(metalHUD,forKey:"metalHUD") }
    }
    var resources: URL { Bundle.main.resourceURL! }
    var setUp: Bool { steamInstalled && webhelperFix && state["prepared_runtime"] as? String == release?.runtimeVersion }

    init() {
        release=(try? Data(contentsOf:Bundle.main.url(forResource:"release",withExtension:"json") ?? URL(fileURLWithPath:"/missing")))
            .flatMap { try? JSONDecoder().decode(Release.self,from:$0) }
        // Development: `open -n <app> --args --data-root <folder>` sets up in another folder.
        let args=CommandLine.arguments
        if let i=args.firstIndex(of:"--data-root"),args.indices.contains(i+1) { root=URL(fileURLWithPath:args[i+1]).standardizedFileURL }
        else { root=FileManager.default.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0].appendingPathComponent("RecallRaft") }
        service=SetupService(root:root,helper:Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/raft-setup"))
    }

    var title: String {
        switch screen {
        case .welcome: return state["active_runtime"] == nil ? Brand.tagline : "Finish setting up"
        case .checking: return "Checking your Mac"
        case .preparing: return "Setting up Steam"
        case .launching: return "Opening Steam"
        case .ready: return gameInstalled ? "Play Raft" : "Install Raft"
        case .running: return running == .game ? "Raft is running" : "Steam is open"
        case .failure: return failure.code == "rosetta_required" ? "Install Rosetta" : failure.code == "cancelled" ? "Setup paused" : "Setup needs attention"
        }
    }
    var subtitle: String {
        switch screen {
        case .welcome: return state["active_runtime"] == nil ? "Recall Raft installs Steam in its own Windows environment and runs Raft through Wine and Metal. Sign in to Steam, install Raft and play." : "Pick up where setup left off. Completed steps are kept."
        case .checking: return "Checking your installation."
        case .preparing: return stage.isEmpty ? "Preparing your game environment." : stage
        case .launching: return "Waiting for Steam’s window."
        case .ready: return gameInstalled ? "Steam opens and starts Raft for you." : "Sign in to Steam, then install Raft from your Library. It downloads into Recall Raft’s own folder."
        case .running: return running == .game ? "Can’t see the game? Check your other desktops, or use Force Quit in Settings if it stopped responding." : "Play from the Steam window, or choose Play Raft here."
        case .failure: return failure.message
        }
    }

    func receive(_ value:[String:Any]) {
        guard let name=value["stage"] as? String else { return }
        let labels=["downloading":"Downloading Steam’s installer","download_verified":"Download verified",
                    "installing_runtime":"Installing Wine and DXMT","runtime_ready":"Game components ready",
                    "preparing_environment":"Preparing the Windows environment","environment_ready":"Windows environment ready",
                    "installing_steam":"Installing Steam","updating_steam":"Steam is updating itself. This takes a minute or two.",
                    "closing_steam":"Closing Steam","webhelper_fix_installed":"Applying Steam’s display fix",
                    "steam_ready":"Steam is ready","steam_started":"Opening Steam"]
        if let label=labels[name] { stage=label }
    }

    func perform(_ action: @escaping @MainActor () async throws -> Void) {
        guard !busy else { return }
        busy=true; notice=""
        Task {
            defer { busy=false }
            do { try await action() }
            catch {
                failure=error as? SetupFailure ?? SetupFailure(code:"unexpected_setup_error")
                screen = .failure
            }
        }
    }
    func startup() {
        guard !started else { return }; started=true
        screen = .checking
        perform {
            guard self.release != nil else { throw SetupFailure(code:"release_unavailable") }
            try await self.refresh()
            if self.setUp {
                try await self.syncSession()
                if self.running == nil && self.openSteamAtLaunch { try await self.openSteam(play:false) }
            } else { self.screen = .welcome }
        }
    }
    func refresh() async throws {
        guard let status=try await service.run("status").last else { throw SetupFailure(code:"status_unavailable") }
        state=status["state"] as? [String:Any] ?? [:]
        steamInstalled=status["steam_installed"] as? Bool ?? false
        gameInstalled=status["game_installed"] as? Bool ?? false
        webhelperFix=status["webhelper_fix"] as? Bool ?? false
    }
    /// Install the runtime, prepare Wine and install Steam. Each step the worker has finished
    /// before is quick, so setup and repair are the same sequence.
    func setUpSteam(repair:Bool=false) {
        guard let release else { return }
        screen = .preparing; stage=""
        perform {
            if repair { _ = try await self.service.run("close-steam",event:self.receive) }
            try await self.runSteps(release,repair:repair)
            try await self.openSteam(play:false)
        }
    }
    private func runSteps(_ release:Release, repair:Bool) async throws {
        _ = try await service.run("preflight",event:receive)
        try await refresh()
        if repair || state["active_runtime"] as? String != release.runtimeVersion {
            _ = try await service.run("install-runtime",["--archive",resources.appendingPathComponent(release.runtimeArchive).path,
                "--sha256",release.runtimeSHA256,"--version",release.runtimeVersion]+(repair ? ["--repair","1"] : []),event:receive)
        }
        try await refresh()
        if repair || state["prepared_runtime"] as? String != release.runtimeVersion { _ = try await service.run("prepare",event:receive) }
        _ = try await service.run("install-steam",["--url",release.steamInstallerURL,"--sha256",release.steamInstallerSHA256,
            "--webhelper-dll",webhelperDLL.path],event:receive)
        try await refresh()
    }
    private var webhelperDLL: URL { resources.appendingPathComponent("webhelper/version.dll") }
    func play() { perform { try await self.openSteam(play:true) } }
    func launch() { perform { try await self.openSteam(play:false) } }
    private func openSteam(play:Bool) async throws {
        screen = .launching; stage=""
        let events=try await service.run("launch",["--play",play ? "1":"0","--metal-hud",metalHUD ? "1":"0",
            "--webhelper-dll",webhelperDLL.path],event:receive)
        if events.contains(where:{ $0["stage"] as? String == "webhelper_fix_pending" }) {
            notice="Steam’s display fix couldn’t be applied, so its windows may be black. Choose Repair in Settings."
        }
        running = play ? .game : .steam
        screen = .running
        watchSession()
    }
    /// What's running, from the worker's session check (exact runtime/environment membership).
    func syncSession() async throws {
        let processes=try await service.run("session").last?["processes"] as? [[String:Any]] ?? []
        let kinds=Set(processes.compactMap { $0["kind"] as? String })
        running = kinds.contains("game") ? .game : (kinds.contains("steam") ? .steam : nil)
        if running != nil { screen = .running; watchSession() }
        else if screen == .running || screen == .checking { try await refresh(); screen = .ready }
    }
    /// While Steam is open, checks every few seconds so the window follows it closing.
    private func watchSession() {
        guard watch == nil else { return }
        watch=Task {
            defer { watch=nil }
            var quiet=0
            while !Task.isCancelled {
                try? await Task.sleep(for:.seconds(4))
                guard !busy else { continue }
                let found=try? await service.run("session").last?["processes"] as? [[String:Any]]
                let kinds=Set((found ?? []).compactMap { $0["kind"] as? String })
                let now:Running? = kinds.contains("game") ? .game : (kinds.contains("steam") ? .steam : nil)
                // Steam restarts itself after an update: allow a few quiet checks first.
                if now == nil { quiet+=1; if quiet<3 { continue } } else { quiet=0 }
                running=now
                if now == nil {
                    if screen == .running { try? await refresh(); screen = .ready }
                    return
                }
                if screen == .ready { screen = .running }
            }
        }
    }
    func sessionChanged() { if !busy && setUp { perform { try await self.syncSession() } } }
    func forceQuit() {
        perform {
            _ = try await self.service.run("stop")
            self.running=nil; try await self.refresh(); self.screen = .ready
        }
    }
    func retry() {
        if failure.code == "rosetta_required" { installRosetta() }
        if setUp { screen = .checking; perform { try await self.syncSession(); if self.running == nil { self.screen = .ready } } }
        else { setUpSteam() }
    }
    /// Opening an Intel app is how macOS offers to install Rosetta.
    func installRosetta() {
        NSWorkspace.shared.openApplication(at:Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/Rosetta Check.app"),configuration:NSWorkspace.OpenConfiguration())
    }
    func showLogs() { NSWorkspace.shared.activateFileViewerSelecting([root.appendingPathComponent("logs")]) }
    /// Moves the data folder (Steam, Raft, sign-in, runtime) and then this app to the Trash.
    func uninstall() {
        perform {
            _ = try await self.service.run("uninstall")
            NSWorkspace.shared.recycle([Bundle.main.bundleURL]) { _,_ in NSApp.terminate(nil) }
        }
    }
}
