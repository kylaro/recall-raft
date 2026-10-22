import AppKit
import SwiftUI
import Darwin

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuItemValidation {
    let model=AppModel()
    var window:NSWindow!
    var lockFD:Int32 = -1
    func applicationDidFinishLaunching(_ notification:Notification) {
        // One app at a time, also across `open -n` and copies of the bundle.
        let lockDirectory=FileManager.default.urls(for:.cachesDirectory,in:.userDomainMask)[0].appendingPathComponent(Bundle.main.bundleIdentifier ?? "recall-raft")
        try? FileManager.default.createDirectory(at:lockDirectory,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        lockFD=open(lockDirectory.appendingPathComponent("app.lock").path,O_CREAT|O_RDWR|O_NOFOLLOW,0o600)
        if lockFD<0 || flock(lockFD,LOCK_EX|LOCK_NB) != 0 {
            for app in NSRunningApplication.runningApplications(withBundleIdentifier:Bundle.main.bundleIdentifier ?? "") where app.processIdentifier != ProcessInfo.processInfo.processIdentifier { app.activate() }
            NSApp.terminate(nil); return
        }
        window=NSWindow(contentRect:NSRect(x:0,y:0,width:560,height:720),styleMask:[.titled,.closable,.miniaturizable,.resizable],backing:.buffered,defer:false)
        window.title=Brand.name; window.isReleasedWhenClosed=false
        window.titlebarAppearsTransparent=true; window.minSize=NSSize(width:520,height:620)
        window.contentView=NSHostingView(rootView:SetupView(model:model)); window.center(); window.makeKeyAndOrderFront(nil)
        NSApp.mainMenu=menu(); NSApp.activate()
    }
    func menu() -> NSMenu {
        let main=NSMenu(),app=NSMenu(),top=NSMenuItem(); main.addItem(top); top.submenu=app
        func add(_ title:String,_ action:Selector,_ key:String="",to menu:NSMenu?=nil) {
            let item=NSMenuItem(title:title,action:action,keyEquivalent:key); item.target=self; (menu ?? app).addItem(item)
        }
        add("About \(Brand.name)",#selector(about))
        app.addItem(.separator())
        add("Settings…",#selector(settings),",")
        app.addItem(.separator())
        add("Play Raft",#selector(play),"p")
        add("Open Steam",#selector(launch),"o")
        app.addItem(.separator())
        app.addItem(NSMenuItem(title:"Hide \(Brand.name)",action:#selector(NSApplication.hide(_:)),keyEquivalent:"h"))
        app.addItem(NSMenuItem(title:"Quit \(Brand.name)",action:#selector(NSApplication.terminate(_:)),keyEquivalent:"q"))
        let editItem=NSMenuItem(); main.addItem(editItem); let edit=NSMenu(title:"Edit"); editItem.submenu=edit
        for (title,selector,key) in [("Copy",#selector(NSText.copy(_:)),"c"),("Select All",#selector(NSText.selectAll(_:)),"a")] {
            edit.addItem(NSMenuItem(title:title,action:selector,keyEquivalent:key))
        }
        let windowItem=NSMenuItem(); main.addItem(windowItem); let windows=NSMenu(title:"Window"); windowItem.submenu=windows
        windows.addItem(NSMenuItem(title:"Minimize",action:#selector(NSWindow.performMiniaturize(_:)),keyEquivalent:"m"))
        windows.addItem(NSMenuItem(title:"Close",action:#selector(NSWindow.performClose(_:)),keyEquivalent:"w"))
        NSApp.windowsMenu=windows
        let helpItem=NSMenuItem(); main.addItem(helpItem); let help=NSMenu(title:"Help"); helpItem.submenu=help
        add("Show Logs in Finder",#selector(logs),to:help)
        add("Recall on GitHub",#selector(recall),to:help)
        NSApp.helpMenu=help
        return main
    }
    func validateMenuItem(_ item:NSMenuItem) -> Bool {
        if item.action == #selector(play) { return model.setUp && model.gameInstalled && !model.busy && model.running != .game }
        if item.action == #selector(launch) { return model.setUp && !model.busy }
        return true
    }
    // Right-clicking the Dock icon.
    func applicationDockMenu(_ sender:NSApplication) -> NSMenu? {
        let menu=NSMenu()
        for (title,action) in [("Play Raft",#selector(play)),("Open Steam",#selector(launch))] {
            let item=NSMenuItem(title:title,action:action,keyEquivalent:""); item.target=self; menu.addItem(item)
        }
        return menu
    }
    @objc func play() { show(); model.play() }
    @objc func launch() { show(); model.launch() }
    @objc func settings() { show(); model.sheet = .settings }
    @objc func about() { show(); model.sheet = .about }
    @objc func logs() { model.showLogs() }
    @objc func recall() { NSWorkspace.shared.open(Brand.recall) }
    func show() { window?.makeKeyAndOrderFront(nil); NSApp.activate() }
    func applicationDidBecomeActive(_ notification:Notification) { model.sessionChanged() }
    func applicationShouldHandleReopen(_ sender:NSApplication,hasVisibleWindows:Bool) -> Bool { show(); return false }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender:NSApplication) -> Bool { false }
    func applicationShouldTerminate(_ sender:NSApplication) -> NSApplication.TerminateReply {
        // Steam and Raft keep running on their own; only a setup step in progress is stopped.
        guard model.busy else { return .terminateNow }
        model.service.cancel()
        Task { while model.busy { try? await Task.sleep(for:.milliseconds(100)) }; sender.reply(toApplicationShouldTerminate:true) }
        return .terminateLater
    }
}

@main struct RecallRaftMain {
    @MainActor static func main() {
        let app=NSApplication.shared,delegate=AppDelegate()
        app.setActivationPolicy(.regular); app.delegate=delegate
        withExtendedLifetime(delegate) { app.run() }
    }
}
