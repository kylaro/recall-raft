#!/usr/bin/env python3
"""The worker's safety checks, without Wine, Steam or the game.

Builds raft-setup (and a copy whose Rosetta probe always fails), then runs it against
scratch data folders: ownership, runtime archive verification and extraction, and the
manifest checks that keep a runtime exactly as shipped. The version.dll test needs the
pinned llvm-mingw (python3 scripts/build_webhelper_fix.py fetches it) and is skipped
without it.

  python3 tests/test_worker.py
"""
import hashlib
import io
import json
from pathlib import Path
import subprocess
import sys
import tarfile
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'scripts'))
import build_webhelper_fix  # noqa: E402
import build_worker  # noqa: E402

BUILD = Path(tempfile.mkdtemp(prefix='raft-worker-tests-'))
WORKER = build_worker.build(BUILD / 'raft-setup')
NO_ROSETTA = build_worker.build(BUILD / 'raft-setup-no-rosetta', defines=['ROSETTA_PROBE=@"/usr/bin/false"'])
REQUIRED = ['bin/wine', 'bin/wineserver', 'config/dxmt.conf', 'lib/external/libd3dshared.dylib',
            'lib/wine/x86_64-unix/winemetal.so', 'lib/wine/x86_64-unix/winemac.so',
            'lib/wine/x86_64-windows/d3d11.dll', 'lib/wine/x86_64-windows/dxgi.dll'] + [
            f'lib/wine/{arch}/{name}' for arch in ('x86_64-windows', 'i386-windows')
            for name in ('winemac.drv', 'kernel32.dll', 'ntdll.dll', 'wscript.exe')]


def run(root, *args, worker=WORKER):
    result = subprocess.run([str(worker), args[0], '--root', str(root), *args[1:]], capture_output=True, text=True, timeout=120)
    events = [json.loads(line) for line in result.stdout.splitlines() if line.startswith('{')]
    return result.returncode, events


def error(events):
    return next((e['code'] for e in events if e['stage'] == 'error'), None)


def runtime_archive(folder, version='test-runtime.1', extra=(), drop=(), manifest_extra=None):
    """A fake runtime: every file the worker requires, listed with its hash in runtime.json."""
    files = {name: f'contents of {name}'.encode() for name in REQUIRED if name not in drop}
    manifest = {'version': version, 'files': {name: {'sha256': hashlib.sha256(data).hexdigest()} for name, data in files.items()}}
    manifest['files'].update(manifest_extra or {})
    path = Path(folder) / f'{version}.tar.gz'
    with tarfile.open(path, 'w:gz') as tar:
        for name, data in [*files.items(), ('runtime.json', json.dumps(manifest).encode()), *extra]:
            info = tarfile.TarInfo(name)
            info.size = len(data)
            tar.addfile(info, io.BytesIO(data))
    return path, hashlib.sha256(path.read_bytes()).hexdigest()


class WorkerTests(unittest.TestCase):
    def setUp(self):
        self.scratch = tempfile.TemporaryDirectory()
        self.root = Path(self.scratch.name) / 'RecallRaft'

    def tearDown(self):
        self.scratch.cleanup()

    def install(self, archive, digest, version='test-runtime.1'):
        return run(self.root, 'install-runtime', '--archive', str(archive), '--sha256', digest, '--version', version)

    def test_status_creates_owned_folder(self):
        code, events = run(self.root, 'status')
        self.assertEqual(code, 0)
        self.assertEqual(events[-1]['stage'], 'status')
        self.assertFalse(events[-1]['steam_installed'])
        self.assertEqual((self.root / '.recall-raft-owner').read_text(), 'recall-raft-setup-v1\n')

    def test_refuses_folder_it_did_not_create(self):
        self.root.mkdir()
        (self.root / 'someone-elses-file').write_text('keep me')
        code, events = run(self.root, 'status')
        self.assertEqual((code, error(events)), (1, 'directory_not_owned_by_app'))
        self.assertEqual(sorted(p.name for p in self.root.iterdir()), ['someone-elses-file'])

    def test_refuses_missing_parent(self):
        code, events = run(self.root / 'not-there' / 'RecallRaft', 'status')
        self.assertEqual(error(events), 'install_location_unavailable')

    def test_installs_and_verifies_runtime(self):
        archive, digest = runtime_archive(self.scratch.name)
        code, events = self.install(archive, digest)
        self.assertEqual(code, 0, events)
        self.assertEqual(events[-1], {'stage': 'runtime_ready', 'version': 'test-runtime.1'})
        self.assertEqual(run(self.root, 'verify')[1][-1]['stage'], 'runtime_verified')
        (self.root / 'runtimes/test-runtime.1/bin/wine').write_text('changed')
        self.assertEqual(error(run(self.root, 'verify')[1]), 'runtime_file_hash_mismatch')

    def test_rejects_unlisted_file(self):
        archive, digest = runtime_archive(self.scratch.name)
        self.install(archive, digest)
        (self.root / 'runtimes/test-runtime.1/bin/extra').write_text('not shipped')
        self.assertEqual(error(run(self.root, 'verify')[1]), 'runtime_unlisted_file')

    def test_rejects_wrong_hash(self):
        archive, _ = runtime_archive(self.scratch.name)
        self.assertEqual(error(self.install(archive, '0' * 64)[1]), 'archive_hash_mismatch')

    def test_rejects_path_escape(self):
        archive, digest = runtime_archive(self.scratch.name, extra=[('../escaped', b'x')])
        self.assertEqual(error(self.install(archive, digest)[1]), 'unsafe_archive_path')
        self.assertFalse((self.root / 'escaped').exists())

    def test_rejects_runtime_without_required_component(self):
        archive, digest = runtime_archive(self.scratch.name, drop=['lib/wine/x86_64-windows/wscript.exe'])
        self.assertEqual(error(self.install(archive, digest)[1]), 'runtime_required_component_missing')

    def test_rejects_wrong_version(self):
        archive, digest = runtime_archive(self.scratch.name)
        self.assertEqual(error(self.install(archive, digest, version='other.1')[1]), 'runtime_identity_mismatch')

    def test_launch_checks_rosetta_first(self):
        archive, digest = runtime_archive(self.scratch.name)
        self.install(archive, digest)
        self.assertEqual(error(run(self.root, 'launch', worker=NO_ROSETTA)[1]), 'rosetta_required')

    def test_preflight_without_rosetta(self):
        self.assertEqual(error(run(self.root, 'preflight', worker=NO_ROSETTA)[1]), 'rosetta_required')

    def test_unknown_command(self):
        self.assertEqual(error(run(self.root, 'frobnicate')[1]), 'unknown_command')


@unittest.skipUnless((ROOT / 'build/toolchains' / build_webhelper_fix.TOOLCHAIN).exists(), 'llvm-mingw not fetched')
class WebhelperFixTests(unittest.TestCase):
    def test_builds_a_forwarding_version_dll(self):
        dll = build_webhelper_fix.build(BUILD / 'version.dll')
        headers = subprocess.run(['xcrun', 'llvm-objdump', '--private-headers', str(dll)], capture_output=True, text=True, check=True).stdout
        self.assertIn('DLL name: version.dll', headers)
        for name in ('GetFileVersionInfoW', 'GetFileVersionInfoSizeW', 'VerQueryValueW'):
            self.assertIn(f'{name} (forwarded to kernelbase.{name})', headers)
        self.assertIn('VerInstallFileW', headers)
        self.assertIn('--in-process-gpu'.encode('utf-16-le'), dll.read_bytes())


if __name__ == '__main__':
    unittest.main(verbosity=2)
