#!/usr/bin/env python3
import argparse
from contextlib import contextmanager
import hashlib
import http.client
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tarfile
import tempfile
import time
import urllib.error
import urllib.request

ROOT = Path(__file__).resolve().parent.parent
COMPONENT = ROOT / "components/doom_engine"
STAMP = ".badge-source.json"


@contextmanager
def source_lock(output):
    output.parent.mkdir(parents=True, exist_ok=True)
    with output.with_suffix(".lock").open("a+b") as stream:
        if os.name == "nt":
            import msvcrt
            if stream.tell() == 0:
                stream.write(b"\0")
                stream.flush()
            deadline = time.monotonic() + 90
            while True:
                stream.seek(0)
                try:
                    msvcrt.locking(stream.fileno(), msvcrt.LK_NBLCK, 1)
                    break
                except OSError:
                    if time.monotonic() >= deadline:
                        raise TimeoutError("Another build is preparing DoomGeneric")
                    time.sleep(0.1)
        else:
            import fcntl
            fcntl.flock(stream, fcntl.LOCK_EX)
        yield


def sha256(data):
    return hashlib.sha256(data).hexdigest()


def verify_archive(data, pin):
    if len(data) != pin["bytes"] or sha256(data) != pin["sha256"]:
        raise ValueError("DoomGeneric archive does not match dependencies.json")


def download(pin):
    for attempt in range(3):
        try:
            with urllib.request.urlopen(pin["url"], timeout=30) as response:
                return response.read(pin["bytes"] + 1)
        except (urllib.error.URLError, TimeoutError, ConnectionError, http.client.IncompleteRead) as error:
            if attempt == 2:
                raise
            print(f"DoomGeneric download interrupted; retrying ({attempt + 1}/2): {error}", file=sys.stderr)
            time.sleep(attempt + 1)


def cached(output, fingerprint):
    try:
        record = json.loads((output / STAMP).read_text())
        return record["fingerprint"] == fingerprint and bool(record["files"]) and all(
            sha256((output / name).read_bytes()) == digest
            for name, digest in record["files"].items()
        )
    except (OSError, ValueError, KeyError, TypeError, AttributeError):
        return False


def unpack(archive, target, commit, sources):
    prefix = f"doomgeneric-{commit}/"
    with tarfile.open(archive, "r:gz") as tar:
        # Copy only flat, regular source files; never extract archive paths.
        headers = {
            Path(member.name).name for member in tar.getmembers()
            if member.name.startswith(prefix + "doomgeneric/")
            and member.name.count("/") == 2 and member.name.endswith(".h")
        }
        names = set(sources) | headers | {"w_file_stdc.c", "LICENSE"}
        for name in sorted(names):
            if Path(name).name != name or name in (".", "..") or "\\" in name:
                raise ValueError(f"Invalid Doom source name: {name}")
            member = tar.getmember(prefix + (name if name == "LICENSE" else "doomgeneric/" + name))
            if not member.isfile():
                raise ValueError(f"Doom source must be a regular file: {name}")
            (target / name).write_bytes(tar.extractfile(member).read())


def prepare(output, pin, component=COMPONENT, cache=ROOT / ".cache"):
    with source_lock(output):
        prepare_locked(output, pin, component, cache)


def prepare_locked(output, pin, component, cache):
    patch = component / "patches/esp32.patch"
    source_list = component / "sources.txt"
    fingerprint = sha256(
        json.dumps(pin, sort_keys=True).encode() + patch.read_bytes()
        + source_list.read_bytes() + Path(__file__).read_bytes()
    )
    if cached(output, fingerprint):
        return
    if output.exists() and not (output / STAMP).is_file():
        raise ValueError(f"Refusing to replace an unrecognized source directory: {output}")
    cache.mkdir(parents=True, exist_ok=True)
    archive = cache / f"doomgeneric-{pin['archive']['sha256']}.tar.gz"
    if not archive.exists():
        print(f"Downloading DoomGeneric {pin['commit']}...", file=sys.stderr, flush=True)
        data = download(pin["archive"])
        verify_archive(data, pin["archive"])
        with tempfile.NamedTemporaryFile(dir=cache, delete=False) as stream:
            temporary = Path(stream.name)
            stream.write(data)
        temporary.replace(archive)
    verify_archive(archive.read_bytes(), pin["archive"])
    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="doomgeneric-", dir=output.parent) as temporary:
        stage = Path(temporary) / "source"
        stage.mkdir()
        unpack(archive, stage, pin["commit"], source_list.read_text().splitlines())
        subprocess.run(
            ["git", "apply", "--no-index", "--whitespace=nowarn", str(patch.resolve())],
            cwd=stage, check=True,
        )
        record = {"fingerprint": fingerprint, "files": {
            path.name: sha256(path.read_bytes()) for path in sorted(stage.iterdir())
        }}
        (stage / STAMP).write_text(json.dumps(record, indent=2) + "\n")
        if output.exists():
            shutil.rmtree(output)
        stage.replace(output)
    print(f"Prepared DoomGeneric: {output}", file=sys.stderr, flush=True)


def main():
    pin = json.loads((ROOT / "dependencies.json").read_text())["doomgeneric"]
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, default=ROOT / pin["path"])
    args = parser.parse_args()
    prepare(args.output.resolve(), pin)


if __name__ == "__main__":
    main()
