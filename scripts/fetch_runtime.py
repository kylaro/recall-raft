#!/usr/bin/env python3
"""Get the Wine + DXMT runtime Recall Raft runs on: Recall's own, byte for byte.

Recall (github.com/AsherJN/recall) builds its runtime from CodeWeavers' Wine sources and
DXMT with its patches, and ships it inside its notarized app as runtime.tar.gz. Recall Raft
uses that exact archive, pinned in app/Resources/release.json by version and SHA-256. It is
taken from either
  - the Recall release disk image named in release.json (downloaded, checked against its
    SHA-256, mounted read-only), the default; or
  - a Recall.app already on this Mac (--from-app /Applications/Recall.app).
Either way the archive must match the pinned hash, so both give the same file.
"""
import argparse
import hashlib
import json
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
RELEASE = json.loads((ROOT / 'app/Resources/release.json').read_text())


def sha(path):
    digest = hashlib.sha256()
    with open(path, 'rb') as f:
        for block in iter(lambda: f.read(1 << 20), b''):
            digest.update(block)
    return digest.hexdigest()


def take(app, output):
    archive = Path(app) / 'Contents/Resources' / RELEASE['runtimeArchive']
    if not archive.exists():
        raise ValueError(f'{app} has no runtime archive')
    if sha(archive) != RELEASE['runtimeSHA256']:
        raise ValueError(f'{archive} is not the pinned runtime {RELEASE["runtimeVersion"]}; '
                         'it comes from a different Recall release')
    output.parent.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(archive, output)
    return output


def from_disk_image(output):
    source = RELEASE['runtimeSource']
    with tempfile.TemporaryDirectory() as scratch:
        image = Path(scratch) / Path(source['url']).name
        print(f'Downloading {image.name}')
        with urllib.request.urlopen(source['url'], timeout=60) as response, open(image, 'wb') as out:
            shutil.copyfileobj(response, out)
        if sha(image) != source['sha256']:
            raise ValueError('Recall disk image hash mismatch')
        mount = Path(scratch) / 'mount'
        mount.mkdir()
        subprocess.run(['/usr/bin/hdiutil', 'attach', '-readonly', '-nobrowse', '-noautoopen', '-mountpoint', str(mount), str(image)],
                       check=True, stdout=subprocess.DEVNULL)
        try:
            apps = [p for p in mount.glob('*.app') if plistlib.loads((p / 'Contents/Info.plist').read_bytes()).get('CFBundleIdentifier') == source['bundleIdentifier']]
            if len(apps) != 1:
                raise ValueError('The disk image does not hold exactly one Recall app')
            return take(apps[0], output)
        finally:
            subprocess.run(['/usr/bin/hdiutil', 'detach', str(mount)], check=True, stdout=subprocess.DEVNULL)


def fetch(output=ROOT / 'build/runtime' / RELEASE['runtimeArchive'], app=None):
    if output.exists() and sha(output) == RELEASE['runtimeSHA256']:
        return output
    return take(app, output) if app else from_disk_image(output)


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument('--from-app', type=Path, help='take the archive from this Recall.app instead of downloading')
    parser.add_argument('--output', type=Path, default=ROOT / 'build/runtime' / RELEASE['runtimeArchive'])
    args = parser.parse_args()
    print(fetch(args.output.resolve(), args.from_app))
