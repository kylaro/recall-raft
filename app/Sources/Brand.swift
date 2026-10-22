import Foundation

// The app's public identity in one place, as in Recall. Renaming the app changes only this
// file and build_app.py's APP_NAME; the bundle identifier and data folder stay put.
enum Brand {
    static let name="Recall Raft"
    static let tagline="Play Raft on your Mac."
    static let game="Raft"
    /// Raft on Steam; the worker starts it with steam://rungameid/648800.
    static let gameStore=URL(string:"https://store.steampowered.com/app/648800/Raft/")!
    static let recall=URL(string:"https://github.com/AsherJN/recall")!
    static let trademarks="Not affiliated with or endorsed by Redbeet Interactive, Axolot Games, Valve or Apple. Raft is a trademark of its owners; Steam is a trademark of Valve Corporation; Mac is a trademark of Apple Inc."
}
