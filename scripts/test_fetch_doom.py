#!/usr/bin/env python3
import importlib.util
import io
from pathlib import Path
import subprocess
import tarfile
import tempfile
import unittest
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("fetch_doom", Path(__file__).with_name("fetch-doom-engine.py"))
fetch = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fetch)


class SourceCacheTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.output = self.root / "output"
        self.component = self.root / "component"
        (self.component / "patches").mkdir(parents=True)
        (self.component / "sources.txt").write_text("engine.c\n")
        self.patch_path = self.component / "patches/esp32.patch"
        self.patch_path.write_bytes(b"--- a/engine.c\n+++ b/engine.c\n@@ -1 +1 @@\n-old\n+new\n")
        self.archive = self.root / "upstream.tar.gz"
        with tarfile.open(self.archive, "w:gz") as tar:
            for name, data in {"LICENSE": b"fixture", "doomgeneric/engine.c": b"old\n",
                               "doomgeneric/engine.h": b"header", "doomgeneric/w_file_stdc.c": b"file"}.items():
                member = tarfile.TarInfo("doomgeneric-fixture/" + name)
                member.size = len(data)
                tar.addfile(member, io.BytesIO(data))
        data = self.archive.read_bytes()
        self.pin = {"commit": "fixture", "archive": {"url": self.archive.as_uri(),
                    "bytes": len(data), "sha256": fetch.sha256(data)}}

    def prepare(self):
        fetch.prepare(self.output, self.pin, self.component, self.root / "cache")

    def test_cache_is_offline_idempotent_and_repairs_missing_or_modified_sources(self):
        response = fetch.urllib.request.urlopen(self.archive.as_uri())
        with patch.object(fetch.urllib.request, "urlopen", side_effect=[fetch.urllib.error.URLError("transient"), response]) as request, patch.object(fetch.time, "sleep"):
            self.prepare()
            self.assertEqual(request.call_count, 2)
        mtime = (self.output / "engine.c").stat().st_mtime_ns
        with patch.object(fetch.urllib.request, "urlopen", side_effect=AssertionError("Unexpected network")):
            self.prepare()
            self.assertEqual((self.output / "engine.c").stat().st_mtime_ns, mtime)
            (self.output / "engine.c").write_text("corrupted")
            (self.output / "engine.h").unlink()
            self.prepare()
        self.assertEqual((self.output / "engine.c").read_bytes(), b"new\n")
        self.assertEqual((self.output / "engine.h").read_bytes(), b"header")

    def test_bad_download_is_rejected_without_installing_sources(self):
        self.archive.write_bytes(self.archive.read_bytes() + b"corrupt")
        with self.assertRaisesRegex(ValueError, "does not match"):
            self.prepare()
        self.assertFalse(self.output.exists())

    def test_patch_change_rebuilds_and_failed_patch_preserves_previous_cache(self):
        self.prepare()
        self.patch_path.write_bytes(self.patch_path.read_bytes().replace(b"+new", b"+updated"))
        self.prepare()
        before = (self.output / fetch.STAMP).read_bytes()
        self.patch_path.write_bytes(b"invalid patch\n")
        with self.assertRaises(subprocess.CalledProcessError):
            self.prepare()
        self.assertEqual((self.output / fetch.STAMP).read_bytes(), before)
        self.assertEqual((self.output / "engine.c").read_bytes(), b"updated\n")

    def test_unrecognized_destination_and_nonflat_archive_paths_are_rejected(self):
        self.output.mkdir()
        (self.output / "keep").write_bytes(b"user data")
        with self.assertRaisesRegex(ValueError, "unrecognized"):
            self.prepare()
        self.assertEqual((self.output / "keep").read_bytes(), b"user data")
        with self.assertRaisesRegex(ValueError, "Invalid Doom source name"):
            fetch.unpack(self.archive, self.output, "fixture", ["../escape.c"])


if __name__ == "__main__":
    unittest.main()
