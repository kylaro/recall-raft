# Third-party notices and license scope

Recall Raft's original code, tests and documentation are offered under the Apache
License 2.0 in [LICENSE](LICENSE), with the attribution notices in [NOTICE](NOTICE).
Parts are adapted from [Recall](https://github.com/AsherJN/recall), which is also
Apache 2.0. That grant covers only this project's own contributions; it does not
relicense anything below.

| Component | Source | Licensing / distribution status |
|---|---|---|
| Wine + DXMT runtime | Recall 1.3.1's `runtime.tar.gz` (`phase2-20261009.1`), unmodified, pinned by SHA-256 in `app/Resources/release.json` | Wine (CodeWeavers' published CrossOver 26.3 sources) and DXMT are LGPL-2.1-or-later. Recall's [patches](https://github.com/AsherJN/recall/tree/main/patches) and [build instructions](https://github.com/AsherJN/recall/blob/main/docs/BUILDING.md) are the corresponding source. Every license text the runtime ships with (Wine, DXMT, FreeType, MoltenVK, Wine Mono, GnuTLS and its dependencies, Apple's support component) is copied into the app at `Contents/Resources/Licenses/Runtime` |
| Apple support component | Inside the runtime | Proprietary; bundled under Apple's accompanying license (`Licenses/Runtime/apple`), not covered by Apache 2.0 or the Wine/DXMT licenses |
| llvm-mingw 20251216 | [mstorsjo/llvm-mingw](https://github.com/mstorsjo/llvm-mingw), a build tool, downloaded at build time and pinned by SHA-256 | Apache 2.0 with LLVM exceptions, and MinGW-w64's licenses. `version.dll` links nothing from it beyond the MinGW-w64 runtime startup code; its license ships as `Licenses/LLVM-MinGW-LICENSE.txt` |
| libarchive headers | libarchive v3.7.7, downloaded at build time and pinned by SHA-256 | BSD-2-Clause; the library itself is part of macOS |
| Steam | Valve, downloaded by the app from Valve's CDN and checked against a pinned SHA-256 | Proprietary; never in this repository or the app |
| Raft | Redbeet Interactive, installed by Steam from the player's own library | Proprietary; never in this repository or the app |

No third-party trademark or game asset is licensed by this repository.
