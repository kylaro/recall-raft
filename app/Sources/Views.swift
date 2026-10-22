import SwiftUI
import AppKit

// Recall's launcher vocabulary (its LauncherStyle.swift), in the sea's colors.
enum Style {
    static let accent=Color(red:0.05,green:0.47,blue:0.71)   // #0D78B5, white text 4.9:1
    static let contentWidth:CGFloat=440
    static let radius:CGFloat=22
    static func font(_ size:CGFloat,_ weight:Font.Weight = .regular) -> Font { .system(size:size,weight:weight) }
    static func ground(_ scheme:ColorScheme) -> Color { scheme == .dark ? Color(red:0.07,green:0.09,blue:0.11) : Color(red:0.96,green:0.975,blue:0.98) }
    static func surface(_ scheme:ColorScheme) -> Color { scheme == .dark ? Color(red:0.12,green:0.145,blue:0.17) : .white }
}

struct Background: View {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    var body:some View {
        Style.ground(scheme)
            .overlay(alignment:.top) {
                if !reduceTransparency {
                    RadialGradient(colors:[Style.accent.opacity(scheme == .dark ? 0.16 : 0.12),.clear],center:.center,startRadius:10,endRadius:260)
                        .frame(width:560,height:440).offset(y:-100)
                }
            }
            .ignoresSafeArea().allowsHitTesting(false).accessibilityHidden(true)
    }
}

struct AppArtwork: View {
    var size:CGFloat=112
    var badge:String?
    var body:some View {
        Image(nsImage:NSImage(named:NSImage.applicationIconName) ?? NSImage()).resizable().interpolation(.high)
            .frame(width:size,height:size)
            .overlay(alignment:.bottomTrailing) {
                if let badge {
                    Image(systemName:badge).font(.system(size:20,weight:.semibold)).foregroundStyle(.white)
                        .frame(width:40,height:40).background(Style.accent,in:Circle()).offset(x:6,y:4)
                }
            }.accessibilityHidden(true)
    }
}

struct Panel<Content:View>: View {
    @Environment(\.colorScheme) private var scheme
    @ViewBuilder let content:Content
    var body:some View {
        content.padding(20).frame(maxWidth:.infinity,alignment:.leading)
            .background(Style.surface(scheme),in:RoundedRectangle(cornerRadius:Style.radius,style:.continuous))
            .overlay { RoundedRectangle(cornerRadius:Style.radius,style:.continuous).strokeBorder(.primary.opacity(0.06),lineWidth:1) }
    }
}

struct ActionStyle: ButtonStyle {
    var fill=Style.accent
    var text=Color.white
    @Environment(\.isEnabled) private var enabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func makeBody(configuration:Configuration) -> some View {
        configuration.label.font(Style.font(15,.semibold)).frame(minWidth:200,minHeight:46).padding(.horizontal,16)
            .foregroundStyle(enabled ? text : Color.secondary)
            .background(enabled ? fill : Color.secondary.opacity(0.12),in:Capsule())
            .contentShape(Capsule())
            .opacity(configuration.isPressed ? 0.82 : 1)
            .scaleEffect(configuration.isPressed && !reduceMotion ? 0.98 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration:0.16),value:configuration.isPressed)
    }
}

struct Notice: View {
    let text:String
    var symbol="info.circle"
    var body:some View {
        Label { Text(text).lineSpacing(3).fixedSize(horizontal:false,vertical:true) } icon: { Image(systemName:symbol) }
            .font(Style.font(13)).foregroundStyle(.secondary)
            .padding(16).frame(maxWidth:.infinity,alignment:.leading)
            .background(Style.accent.opacity(0.09),in:RoundedRectangle(cornerRadius:16,style:.continuous))
    }
}

struct FooterTile: View {
    let title:String
    let symbol:String
    let action:()->Void
    var body:some View {
        Button(action:action) {
            Label(title,systemImage:symbol).font(Style.font(13,.medium)).frame(maxWidth:.infinity,minHeight:36)
        }.buttonStyle(.bordered).buttonBorderShape(.capsule)
    }
}

struct SetupView: View {
    @Bindable var model:AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body:some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(spacing:0) {
                    VStack(spacing:24) {
                        AppArtwork(badge:badge)
                        VStack(spacing:12) {
                            Text(model.title).font(Style.font(32,.bold)).tracking(-0.6).accessibilityAddTraits(.isHeader)
                            Text(model.subtitle).font(Style.font(16)).lineSpacing(3).foregroundStyle(.secondary)
                        }.multilineTextAlignment(.center).fixedSize(horizontal:false,vertical:true)
                        details
                        VStack(spacing:12) { actions }
                        if !model.notice.isEmpty { Notice(text:model.notice) }
                    }.frame(maxWidth:Style.contentWidth).padding(.top,36)
                    Spacer(minLength:28)
                    HStack(spacing:12) {
                        FooterTile(title:"Settings",symbol:"gearshape") { model.sheet = .settings }
                        FooterTile(title:"About",symbol:"info.circle") { model.sheet = .about }
                    }.frame(maxWidth:Style.contentWidth).padding(.bottom,24)
                }.padding(.horizontal,36).frame(maxWidth:.infinity).frame(minHeight:geometry.size.height)
            }.scrollIndicators(.hidden)
        }
        .background { Background() }
        .font(Style.font(14))
        .animation(reduceMotion ? nil : .easeInOut(duration:0.2),value:model.screen)
        .sheet(item:$model.sheet) { sheet in
            switch sheet {
            case .settings: SettingsSheet(model:model)
            case .about: AboutSheet(model:model)
            }
        }
        .task { model.startup() }
    }
    private var badge:String? {
        switch model.screen {
        case .failure: return model.failure.code == "cancelled" ? "pause.fill" : "exclamationmark"
        case .running: return model.running == .game ? "gamecontroller.fill" : nil
        default: return nil
        }
    }
    @ViewBuilder private var details:some View {
        switch model.screen {
        case .welcome:
            Panel {
                VStack(alignment:.leading,spacing:10) {
                    Text("What you need").font(Style.font(14,.semibold))
                    requirement("Mac","Apple Silicon (M1 or newer)")
                    requirement("Storage","About 15 GB free for Steam and Raft")
                    requirement("Account","A Steam account that owns Raft")
                    requirement("Also","Internet and Rosetta (checked during setup)")
                }
            }
        case .checking, .preparing, .launching:
            ProgressView().controlSize(.small).accessibilityLabel(model.subtitle)
        case .ready where !model.gameInstalled:
            Panel {
                VStack(alignment:.leading,spacing:8) {
                    step(1,"Open Steam and sign in.")
                    step(2,"Find Raft in your Library and choose Install.")
                    step(3,"Come back here, or press Play in Steam.")
                }
            }
        default: EmptyView()
        }
    }
    @ViewBuilder private var actions:some View {
        switch model.screen {
        case .welcome:
            Button(model.state["active_runtime"] == nil ? "Set Up" : "Continue Setup") { model.setUpSteam() }.buttonStyle(ActionStyle())
        case .ready, .running:
            if model.gameInstalled && model.running != .game {
                Button("Play Raft") { model.play() }.buttonStyle(ActionStyle()).keyboardShortcut(.defaultAction)
            }
            Button(model.running == nil ? "Open Steam" : "Show Steam") { model.launch() }
                .buttonStyle(model.gameInstalled && model.running != .game ? ActionStyle(fill:Color.secondary.opacity(0.14),text:.primary) : ActionStyle())
        case .failure:
            if model.failure.code == "rosetta_required" {
                Button("Install Rosetta") { model.installRosetta() }.buttonStyle(ActionStyle())
            }
            Button(model.failure.code == "cancelled" ? "Continue" : "Try Again") { model.retry() }
                .buttonStyle(ActionStyle(fill:Color.secondary.opacity(0.14),text:.primary))
        case .checking, .preparing, .launching: EmptyView()
        }
    }
    private func requirement(_ title:String,_ value:String) -> some View {
        HStack(alignment:.firstTextBaseline) {
            Text(title).foregroundStyle(.secondary).frame(width:76,alignment:.leading)
            Text(value)
        }.font(Style.font(13))
    }
    private func step(_ number:Int,_ text:String) -> some View {
        HStack(alignment:.firstTextBaseline,spacing:10) {
            Text("\(number)").font(Style.font(12,.bold)).foregroundStyle(.white).frame(width:20,height:20).background(Style.accent,in:Circle())
            Text(text).font(Style.font(13))
        }
    }
}

struct SettingsSheet: View {
    @Bindable var model:AppModel
    @Environment(\.dismiss) private var dismiss
    var body:some View {
        VStack(alignment:.leading,spacing:18) {
            Text("Settings").font(Style.font(22,.bold))
            Toggle("Open Steam when \(Brand.name) opens",isOn:$model.openSteamAtLaunch)
            VStack(alignment:.leading,spacing:4) {
                Toggle("Show Apple’s Metal Performance HUD in Raft",isOn:$model.metalHUD)
                Text("Frame rate and GPU time over the game. It changes the next time Steam opens.")
                    .font(Style.font(12)).foregroundStyle(.secondary)
            }
            Divider()
            HStack {
                Button("Force Quit Steam & Raft") { model.forceQuit(); dismiss() }.disabled(model.busy || !model.setUp)
                Button("Repair") { model.setUpSteam(repair:true); dismiss() }.disabled(model.busy || model.running == .game)
                Button("Show Logs") { model.showLogs() }
            }
            Text("Repair reinstalls Wine and DXMT and reapplies Steam’s display fix. Your games and sign-in are kept.")
                .font(Style.font(12)).foregroundStyle(.secondary).fixedSize(horizontal:false,vertical:true)
            Divider()
            HStack {
                Button("Uninstall \(Brand.name)…",role:.destructive) { model.confirmUninstall=true }.disabled(model.busy)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(24).frame(width:480)
        .confirmationDialog("Uninstall \(Brand.name)?",isPresented:$model.confirmUninstall) {
            Button("Move to Trash",role:.destructive) { dismiss(); model.uninstall() }
        } message: {
            Text("\(Brand.name), Steam, Raft and the game data in its folder move to the Trash. Your Steam account and cloud saves are unaffected.")
        }
    }
}

struct AboutSheet: View {
    let model:AppModel
    @Environment(\.dismiss) private var dismiss
    var body:some View {
        VStack(spacing:16) {
            AppArtwork(size:84)
            Text(Brand.name).font(Style.font(22,.bold))
            Text("Version \(model.release?.appVersion ?? "?")").foregroundStyle(.secondary)
            Text("A free, open-source way to play Raft on Apple Silicon. Built on Recall by Josh Nelson: its Wine and DXMT runtime (\(model.release?.runtimeSource.name ?? "Recall")) and its launcher design.")
                .multilineTextAlignment(.center).fixedSize(horizontal:false,vertical:true)
            HStack {
                Button("Recall on GitHub") { NSWorkspace.shared.open(Brand.recall) }
                Button("Raft on Steam") { NSWorkspace.shared.open(Brand.gameStore) }
                Button("Licenses") { NSWorkspace.shared.open(model.resources.appendingPathComponent("Licenses")) }
            }
            Text(Brand.trademarks).font(Style.font(11)).foregroundStyle(.secondary).multilineTextAlignment(.center).fixedSize(horizontal:false,vertical:true)
            Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
        }.padding(24).frame(width:440)
    }
}
