<h1 align="center">Recall Raft</h1>

<h3 align="center">Play Raft on your Mac.</h3>

<p align="center">A free, open-source app for playing <a href="https://store.steampowered.com/app/648800/Raft/">Raft</a> on Apple Silicon, built on <a href="https://github.com/AsherJN/recall">Recall</a>.</p>

Raft has no Mac version. Recall Raft installs the Windows version of Steam in its own
Windows environment on your Mac. You sign in, install Raft from your Library and press
Play, the same as on a PC. The game runs locally through Wine, Rosetta and DXMT (Direct3D
11 on Metal), with no Windows installation, CrossOver license or Terminal commands.

It uses the same Wine + DXMT runtime as [Recall](https://github.com/AsherJN/recall), the
Overwatch app, byte for byte. Raft gets Recall's performance work with it: its DXMT
changes, its Wine stutter fixes, and raw mouse input for first-person looking around.

## Get started

1. **Build the app** (see below) and open `build/Recall Raft.app`.
2. **Choose Set Up.** Recall Raft installs Wine and Steam (about a minute) and opens Steam.
3. **Sign in to Steam**, install Raft from your Library, then press **Play Raft**.

| You need | |
|---|---|
| Mac | Apple Silicon: M1 or newer |
| macOS | Tested on macOS 26; built for macOS 15 or later |
| Storage | About 15 GB free for Steam and Raft |
| Also | A Steam account that owns Raft, an internet connection, and Rosetta (checked during setup) |

```sh
git clone https://github.com/kylaro/recall-raft.git && cd recall-raft
python3 scripts/build_app.py          # or: --from-recall /Applications/Recall.app
open "build/Recall Raft.app"
```

The [build guide](docs/BUILDING.md) covers what the build downloads and how each piece is
pinned.

## What made Steam work

Recall's runtime ran Steam, but every Steam window was black. Steam's interface is
Chromium, which draws from a separate GPU process into windows owned by another process,
and Wine on macOS can't show that. Chromium's fix, `--in-process-gpu`, is one Steam won't
pass. Recall Raft adds a 14 KB `version.dll` beside Steam's web helper. It loads before
Chromium starts and adds the switch, without changing any Steam file.
[How Recall Raft works](docs/HOW-IT-WORKS.md) has the details.

## Questions

<details>
<summary><b>Is it free?</b></summary>

Yes. There's no price, account or telemetry, and the code is open source. You need a
Steam account that owns Raft.
</details>

<details>
<summary><b>Does it touch my Mac Steam library?</b></summary>

No. Recall Raft's Steam is a separate Windows Steam in
`~/Library/Application Support/RecallRaft`, with its own sign-in and downloads. Your Mac
Steam app and its games are unaffected. Cloud saves follow your Steam account as usual.
</details>

<details>
<summary><b>Is it safe for my Steam account?</b></summary>

You sign in to Steam itself; Recall Raft never sees your password. It doesn't modify
Steam's or Raft's files or read the game's memory. Raft has no anti-cheat. Valve and
Redbeet don't officially support playing on a Mac through Wine.
</details>

<details>
<summary><b>Can I play multiplayer?</b></summary>

Raft's co-op runs through Steam, which works as on Windows: invite friends from the
Steam overlay or friends list.
</details>

<details>
<summary><b>How do I uninstall it?</b></summary>

Settings › Uninstall Recall Raft moves the app and its folder (Steam, Raft, saves that
aren't in Steam Cloud) to the Trash.
</details>

## Credits and licenses

Recall Raft is built on [Recall](https://github.com/AsherJN/recall) by Josh Nelson: its
runtime, its native worker and its launcher design. Recall uses Wine from CodeWeavers'
published CrossOver sources, DXMT by Feifan He through NerRobDog's fork, and Soju's
runtime build recipe.

Recall Raft's own code is licensed under [Apache 2.0](LICENSE) (see [NOTICE](NOTICE));
everything it ships keeps its own license ([third-party notices](THIRD_PARTY_NOTICES.md)).

Recall Raft is an independent community project, not affiliated with or endorsed by
Redbeet Interactive, Axolot Games, Valve, Apple, CodeWeavers or Recall's author. Raft,
Steam, Mac and other product names are trademarks of their respective owners.
