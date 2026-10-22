#!/usr/bin/env python3
"""Build version.dll, the fix for Steam's black windows (windows/webhelper-gpu/version.c).

It is a Windows DLL, so it needs a Windows toolchain: llvm-mingw 20251216, the release
Recall's runtime build names, downloaded once into build/toolchains and checked against
the SHA-256 GitHub publishes for it.
"""
import argparse
import hashlib
from pathlib import Path
import shutil
import subprocess
import tarfile
import tempfile
import urllib.request

ROOT = Path(__file__).resolve().parents[1]
TOOLCHAIN = 'llvm-mingw-20251216-ucrt-macos-universal'
TOOLCHAIN_URL = f'https://github.com/mstorsjo/llvm-mingw/releases/download/20251216/{TOOLCHAIN}.tar.xz'
TOOLCHAIN_SHA256 = '38bb5e48ec3e0ce95fb901f4efff0bd6ffa966d1b32539a6510af816a959d160'
SOURCE = ROOT / 'windows/webhelper-gpu'


def sha(path):
    digest = hashlib.sha256()
    with open(path, 'rb') as f:
        for block in iter(lambda: f.read(1 << 20), b''):
            digest.update(block)
    return digest.hexdigest()


def safe_extract(tar, destination, members=None):
    """tarfile's 'tar' filter (Python 3.12, and later 3.8-3.11 patch releases); the Python
    in Apple's Command Line Tools (3.9.6) predates it, so there the same rules are checked
    here: no absolute or parent paths, no links leaving DESTINATION, no device files."""
    if hasattr(tarfile, 'tar_filter'):
        tar.extractall(destination, members=members, filter='tar')
        return
    base = Path(destination).resolve()
    members = members if members is not None else tar.getmembers()
    for member in members:
        target = (base / member.name).resolve()
        if Path(member.name).is_absolute() or (target != base and base not in target.parents):
            raise ValueError(f'Unsafe path in archive: {member.name}')
        if member.issym() or member.islnk():
            link = (target.parent / member.linkname if member.issym() else base / member.linkname).resolve()
            if Path(member.linkname).is_absolute() or (link != base and base not in link.parents):
                raise ValueError(f'Unsafe link in archive: {member.name}')
        elif not (member.isfile() or member.isdir()):
            raise ValueError(f'Special file in archive: {member.name}')
    tar.extractall(destination, members=members)


def toolchain(folder=ROOT / 'build/toolchains'):
    compiler = folder / TOOLCHAIN / 'bin/x86_64-w64-mingw32-clang'
    if compiler.exists():
        return compiler
    folder.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(dir=folder) as scratch:
        archive = Path(scratch) / f'{TOOLCHAIN}.tar.xz'
        print(f'Downloading {TOOLCHAIN} (about 120 MB)')
        with urllib.request.urlopen(TOOLCHAIN_URL, timeout=60) as response, open(archive, 'wb') as out:
            shutil.copyfileobj(response, out)
        if sha(archive) != TOOLCHAIN_SHA256:
            raise ValueError('llvm-mingw archive hash mismatch')
        with tarfile.open(archive) as tar:
            safe_extract(tar, scratch)
        (Path(scratch) / TOOLCHAIN).rename(folder / TOOLCHAIN)
    return compiler


def build(output=ROOT / 'build/webhelper/version.dll'):
    output.parent.mkdir(parents=True, exist_ok=True)
    subprocess.run([str(toolchain()), '-O2', '-Wall', '-Wextra', '-Werror', '-shared', '-s',
                    '-Wl,--no-insert-timestamp', f'-ffile-prefix-map={SOURCE}=.',
                    str(SOURCE / 'version.c'), str(SOURCE / 'version.def'), '-o', str(output)], check=True)
    if '--in-process-gpu'.encode('utf-16-le') not in output.read_bytes():
        raise ValueError('version.dll lacks its marker; the worker would not recognize it')
    return output


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, default=ROOT / 'build/webhelper/version.dll')
    args = parser.parse_args()
    print(build(args.output.resolve()))
