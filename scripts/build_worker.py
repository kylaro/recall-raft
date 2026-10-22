#!/usr/bin/env python3
"""Build the native setup worker (raft-setup) with system libraries and pinned public headers.

macOS ships libarchive but not its headers, so the two headers come from libarchive's
v3.7.7 tag, checked against their SHA-256 (as Recall's build_portable_setup.py does).
"""
import argparse
import hashlib
from pathlib import Path
import subprocess
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
# The oldest macOS the app, this worker and the runtime's Wine (stamped 15.0) open on.
MINIMUM_MACOS = '15.0'
HEADERS = {'archive.h': '11c373fab05e8f017220aff1d89cec3cf32146b44d6cb56aeb12e968bc3b950b',
           'archive_entry.h': '510ae3e21a800403bb1c8d413d5ddabaee0b38facb8491b60bb6da55f84f4695'}


def fetch_headers(headers):
    headers.mkdir(parents=True, exist_ok=True)
    for name, expected in HEADERS.items():
        target = headers / name
        if not target.exists():
            data = urllib.request.urlopen('https://raw.githubusercontent.com/libarchive/libarchive/v3.7.7/libarchive/' + name, timeout=30).read()
            if hashlib.sha256(data).hexdigest() != expected:
                raise ValueError(f'{name}: hash mismatch')
            target.write_bytes(data)
        if hashlib.sha256(target.read_bytes()).hexdigest() != expected:
            raise ValueError(f'{name}: hash mismatch')


def build(output, headers=ROOT / 'build/toolchains/libarchive-3.7.7', defines=()):
    """DEFINES (tests only) are extra -D options, e.g. a Rosetta probe that fails."""
    fetch_headers(headers)
    output.parent.mkdir(parents=True, exist_ok=True)
    subprocess.run(['/usr/bin/clang', '-O2', '-fobjc-arc', '-Wall', '-Wextra', '-Werror', '-Wno-deprecated-declarations',
                    f'-ffile-prefix-map={ROOT}=/recall-raft', f'-mmacosx-version-min={MINIMUM_MACOS}', '-arch', 'arm64',
                    '-I', str(headers), *(f'-D{d}' for d in defines), str(ROOT / 'scripts/raft_setup.m'),
                    '-framework', 'Foundation', '-framework', 'AppKit', '-larchive', '-o', str(output)], check=True)
    return output


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, default=ROOT / 'build/raft-setup')
    args = parser.parse_args()
    print(build(args.output.resolve()))
