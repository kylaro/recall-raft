#!/usr/bin/env python3
"""Build Recall Raft.app with command-line tools; no Xcode project.

  python3 scripts/build_app.py [--from-recall /Applications/Recall.app] [--identity "Developer ID Application: ..."]

The bundle holds:
  Contents/MacOS/Recall Raft                      the SwiftUI launcher (app/Sources)
  Contents/Helpers/raft-setup                     the native worker (scripts/raft_setup.m)
  Contents/Helpers/Rosetta Check.app              an Intel no-op: opening it makes macOS offer Rosetta
  Contents/Resources/runtime.tar.gz               Recall's Wine + DXMT runtime, pinned (fetch_runtime.py)
  Contents/Resources/webhelper/version.dll        the fix for Steam's black windows (build_webhelper_fix.py)
  Contents/Resources/release.json, Licenses/      reviewed inputs and every license that ships

Without --identity the app is signed ad hoc, which runs on the Mac that built it.
"""
import argparse
import hashlib
import json
from pathlib import Path
import plistlib
import shutil
import subprocess
import tarfile
import tempfile

import build_webhelper_fix
import build_worker
import fetch_runtime

ROOT = Path(__file__).resolve().parents[1]
APP_NAME = 'Recall Raft'
BUNDLE_ID = 'io.github.recall-raft'
APP_BUILD = '1'


def run(*args):
    subprocess.run([str(a) for a in args], check=True)


def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def build(output, recall_app=None, identity=None):
    release = json.loads((ROOT / 'app/Resources/release.json').read_text())
    runtime = fetch_runtime.fetch(app=recall_app)
    if sha(runtime) != release['runtimeSHA256']:
        raise ValueError('Runtime archive differs from release.json')
    if output.exists():
        shutil.rmtree(output)
    contents = output / 'Contents'
    helpers, resources, macos = contents / 'Helpers', contents / 'Resources', contents / 'MacOS'
    for folder in (helpers, resources / 'webhelper', macos):
        folder.mkdir(parents=True)

    build_worker.build(helpers / 'raft-setup')
    build_webhelper_fix.build(resources / 'webhelper/version.dll')
    run('/usr/bin/swiftc', '-O', '-target', f'arm64-apple-macos{build_worker.MINIMUM_MACOS}', '-parse-as-library',
        '-file-prefix-map', f'{ROOT}=/recall-raft', *sorted((ROOT / 'app/Sources').glob('*.swift')), '-o', macos / APP_NAME)

    rosetta = helpers / 'Rosetta Check.app/Contents'
    (rosetta / 'MacOS').mkdir(parents=True)
    with tempfile.TemporaryDirectory() as scratch:
        source = Path(scratch) / 'rosetta-check.c'
        source.write_text('int main(void) { return 0; }\n')
        run('/usr/bin/clang', '-arch', 'x86_64', f'-mmacosx-version-min={build_worker.MINIMUM_MACOS}', source, '-o', rosetta / 'MacOS/RosettaCheck')
        iconset = Path(scratch) / 'AppIcon.iconset'
        run('/usr/bin/swift', ROOT / 'scripts/app_icon.swift', iconset)
        run('/usr/bin/iconutil', '-c', 'icns', iconset, '-o', resources / 'AppIcon.icns')
    (rosetta / 'Info.plist').write_bytes(plistlib.dumps({
        'CFBundleIdentifier': BUNDLE_ID + '.rosetta-check', 'CFBundleExecutable': 'RosettaCheck', 'CFBundleName': 'Rosetta Check',
        'CFBundlePackageType': 'APPL', 'LSUIElement': True, 'LSMinimumSystemVersion': build_worker.MINIMUM_MACOS}))

    shutil.copyfile(runtime, resources / release['runtimeArchive'])
    shutil.copy2(ROOT / 'app/Resources/release.json', resources / 'release.json')
    # The runtime's own license texts (Wine, DXMT, FreeType, MoltenVK, Apple's...) plus this project's.
    licenses = resources / 'Licenses'
    licenses.mkdir()
    with tempfile.TemporaryDirectory() as scratch, tarfile.open(runtime) as tar:
        members = [m for m in tar.getmembers() if m.name.startswith('licenses/') and (m.isfile() or m.isdir())]
        build_webhelper_fix.safe_extract(tar, scratch, members)
        shutil.move(Path(scratch) / 'licenses', licenses / 'Runtime')
    shutil.copy2(ROOT / 'LICENSE', licenses / 'RECALL-RAFT-LICENSE.txt')
    shutil.copy2(ROOT / 'NOTICE', licenses / 'RECALL-RAFT-NOTICE.txt')
    shutil.copy2(ROOT / 'THIRD_PARTY_NOTICES.md', licenses / 'THIRD_PARTY_NOTICES.md')
    shutil.copy2(build_webhelper_fix.toolchain().parents[1] / 'LICENSE.TXT', licenses / 'LLVM-MinGW-LICENSE.txt')

    (contents / 'Info.plist').write_bytes(plistlib.dumps({
        'CFBundleIdentifier': BUNDLE_ID, 'CFBundleExecutable': APP_NAME, 'CFBundleName': APP_NAME, 'CFBundleDisplayName': APP_NAME,
        'CFBundlePackageType': 'APPL', 'CFBundleShortVersionString': release['appVersion'], 'CFBundleVersion': APP_BUILD,
        'CFBundleIconFile': 'AppIcon', 'LSMinimumSystemVersion': build_worker.MINIMUM_MACOS, 'NSHighResolutionCapable': True,
        'LSMultipleInstancesProhibited': True, 'NSPrincipalClass': 'NSApplication',
        'LSApplicationCategoryType': 'public.app-category.games',
        'NSHumanReadableCopyright': 'Independent community project, built on Recall. Not affiliated with Redbeet Interactive, Valve or Apple.'}))

    sign = ['--sign', identity, '--options', 'runtime', '--timestamp'] if identity else ['--sign', '-']
    for item in (helpers / 'raft-setup', rosetta.parent):
        run('/usr/bin/codesign', '--force', *sign, item)
    run('/usr/bin/codesign', '--force', *sign, output)
    run('/usr/bin/codesign', '--verify', '--deep', '--strict', output)
    return output


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--output', type=Path, default=ROOT / f'build/{APP_NAME}.app')
    parser.add_argument('--from-recall', type=Path, help='take the runtime from this Recall.app instead of downloading Recall 1.3.1')
    parser.add_argument('--identity', help='a Developer ID Application identity; ad hoc without it')
    args = parser.parse_args()
    print(build(args.output.resolve(), args.from_recall, args.identity))
