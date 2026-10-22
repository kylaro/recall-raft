# Building Recall Raft

You need an Apple Silicon Mac with the Apple Command Line Tools (`xcode-select --install`)
and Python 3.10 or later. No Xcode project is involved.

```sh
python3 scripts/build_app.py
open "build/Recall Raft.app"
```

The first build downloads three pinned inputs into `build/` (git-ignored) and checks each
against its SHA-256:

| Input | From | Pinned in |
|---|---|---|
| Wine + DXMT runtime (`runtime.tar.gz`, 240 MB) | The notarized [Recall 1.3.1 disk image](https://github.com/AsherJN/recall/releases/tag/v1.3.1), mounted read-only | `app/Resources/release.json` (disk image and archive) |
| llvm-mingw 20251216 (120 MB) | [mstorsjo/llvm-mingw](https://github.com/mstorsjo/llvm-mingw/releases/tag/20251216) | `scripts/build_webhelper_fix.py` |
| libarchive 3.7.7 headers | libarchive's GitHub tag | `scripts/build_worker.py` |

If Recall 1.3.1 is already installed, `--from-recall /Applications/Recall.app` takes the
runtime from it instead of downloading the disk image. The archive must match the same
hash either way. A different Recall version ships a different runtime and is refused.

Valve's `SteamSetup.exe` isn't part of the build. The app downloads it during setup and
checks it against `steamInstallerSHA256` in `release.json`. When Valve publishes a new
installer, update that hash.

## The pieces

| Script | Builds |
|---|---|
| `scripts/build_worker.py` | `raft-setup`, the native worker, from `scripts/raft_setup.m` |
| `scripts/build_webhelper_fix.py` | `version.dll`, Steam's display fix, from `windows/webhelper-gpu/` |
| `scripts/fetch_runtime.py` | `build/runtime/runtime.tar.gz` |
| `scripts/app_icon.swift` | The app icon, drawn in code |
| `scripts/build_app.py` | All of the above, plus the Swift app, assembled and signed |

Without `--identity` the app is signed ad hoc, which is fine on the Mac that built it. To
share builds, sign with a Developer ID (`--identity "Developer ID Application: …"`) and
notarize with `xcrun notarytool`.

## Running the worker by hand

The worker works on its own, which is handy for debugging. Each command prints JSON
events; `--root` picks the data folder (default
`~/Library/Application Support/RecallRaft`).

```sh
W="build/Recall Raft.app/Contents/Helpers/raft-setup"
"$W" status
"$W" session                 # what's running: steam, webhelper, game
"$W" launch --play 1         # start Raft through Steam
"$W" close-steam             # ask Steam to quit
"$W" stop                    # end the Wine session (force quit)
```

Wine's output for each step goes to `logs/` in the data folder. Steam's own logs are in
`environment/drive_c/Program Files (x86)/Steam/logs`. Raft's Unity log is at
`environment/drive_c/users/crossover/AppData/LocalLow/Redbeet Interactive/Raft/Player.log`.

## Tests

```sh
python3 tests/test_worker.py
```

The tests build the worker and check its safety rules against scratch folders and fake
runtimes: ownership, archive paths, hashes and the manifest. They also build `version.dll`
and check its exports. They need neither Wine nor Steam nor the game.
