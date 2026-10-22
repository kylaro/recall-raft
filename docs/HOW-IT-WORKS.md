# How Recall Raft works

Raft is a Windows game sold on Steam, with no Mac version. Recall Raft runs the Windows
versions of Steam and Raft on Apple Silicon, using the same runtime
[Recall](https://github.com/AsherJN/recall) uses for Overwatch.

## The stack

- **Wine** runs the Windows programs: Steam, its Chromium-based web helper, and Raft.
  It is built from CodeWeavers' published CrossOver 26.3 sources with Recall's patches.
- **Rosetta** translates their Intel code for Apple Silicon.
- **DXMT** translates Raft's Direct3D 11 (Raft is a Unity 2021.3 game) into Metal.

Recall Raft doesn't build any of this itself. It ships Recall 1.3.1's runtime archive,
`phase2-20261009.1`, byte for byte, pinned by SHA-256 in
[`app/Resources/release.json`](../app/Resources/release.json), and installs it the way
Recall does: extract with path and symlink checks, verify every file against the
archive's own manifest, and refuse anything unlisted.

That means Raft gets Recall's work for free:

- Recall's DXMT performance changes: image compression kept on, prepared shaders, waits
  that wake on time, a third drawable.
- Recall's Wine fixes: no 150–400 ms freezes from the loader lock, no pause every 30
  seconds for the registry save, and no display re-read on every click.
- **Raw mouse input** (`WINEMAC_MOUSELOOK=Raft.exe`). While Raft hides and confines the
  cursor to look around, Wine reads the mouse directly at its full report rate instead of
  following macOS pointer updates at 120 Hz.
- Recall's per-program DPI (`WINE_APP_DPI`). Wine's Retina mode makes each Windows pixel
  half a point, so Steam's programs get Windows' 200% DPI and keep their normal size,
  while Raft sees 96 DPI and draws at your display's full pixel count.

## Steam's black windows

Steam would not work on this runtime out of the box: it opened, signed in and updated,
but every window was black. The cause:

1. Steam draws its interface with Chromium (`steamwebhelper.exe`). Chromium composites
   in a separate **GPU process**, which draws into windows owned by the **browser
   process**.
2. Wine on macOS can't show drawing that comes from another process. With GPU
   acceleration, DXMT refuses the swap chain (`CreateSwapChain: cross-process swapchain
   not supported yet`) and ANGLE fails with `EGL_BAD_ALLOC`. With acceleration off, the
   GPU process paints through `GetDC` hundreds of times, but Wine flushes the window to
   the Mac twice. Vulkan through MoltenVK (`-cef-use-vulkan`) is just as black.
3. Chromium's fix is `--in-process-gpu`, which Recall already passes to Battle.net. Steam
   has no option that passes it: its `-cef-in-process-gpu` is silently dropped, and Wine
   ignores both the Image File Execution Options debugger hook and `AppInit_DLLs`.

The fix is a 14 KB DLL, [`windows/webhelper-gpu/version.c`](../windows/webhelper-gpu/version.c).
`libcef.dll` imports `version.dll`, and Windows looks for it in the web helper's own
folder first. So Recall Raft puts its own `version.dll` there and tells Wine to prefer it
for `steamwebhelper.exe` (`AppDefaults\steamwebhelper.exe\DllOverrides`). When it loads
into the browser process (the one without `--type=`), it:

- appends `--in-process-gpu` to the process's command line;
- points every `GetCommandLineW` import already bound in the process (the helper's and
  `libcef.dll`'s) at the new command line. Wine's kernelbase keeps its own pointer to
  the command line it started with, so editing the process parameters alone isn't seen;
- forwards every `version.dll` function to Wine's kernelbase, as Wine's own `version.dll`
  does.

With that, Chromium composites in the browser process and draws through DXMT into its
own windows, and Steam looks and works as it does on Windows. No Steam file is changed.
Steam's updates leave the extra DLL alone, and the worker puts it back before every
launch if it goes missing. On a new installation Steam downloads its web helper on first
start, so setup starts Steam once (`-silent`), waits for the helper, closes Steam and
then installs the DLL.

## What the app does

The app follows Recall's design: a SwiftUI launcher drives a native worker
(`raft-setup`, Objective-C, no Python on the player's Mac) that does all the Wine work
and reports bounded JSON events.

| Step | Worker command | What happens |
|---|---|---|
| Check | `preflight` | Apple Silicon and Rosetta |
| Runtime | `install-runtime` | Recall's runtime from the app, verified file by file |
| Windows | `prepare` | `wineboot`, Retina mode, the web helper DLL override |
| Steam | `install-steam` | Valve's `SteamSetup.exe` (pinned SHA-256), silent install, first update, the fix |
| Play | `launch --play 1` | Steam with `steam://rungameid/648800` |

Everything lives in `~/Library/Application Support/RecallRaft`. That covers the Wine
environment (with Steam, your Steam sign-in and Raft inside), runtimes, logs and caches.
Uninstall moves that folder to the Trash; nothing is deleted outright.

## Not done yet

- **macOS Game Mode.** Recall turns it on by starting Overwatch from a game app bundle in
  its runtime (`lib/wine/game-mode/Overwatch.app`). Doing the same for Raft means
  deriving a runtime with a `Raft.app` in it, which is the natural next step.
- **Fullscreen canvas tuning.** Recall's `dxmt.conf` tunes the fullscreen canvas and
  frame pacing for `Overwatch.exe` only. Raft runs on DXMT's defaults plus the shared
  environment above.
- **Updates.** There's no update feed yet; rebuild to update.
