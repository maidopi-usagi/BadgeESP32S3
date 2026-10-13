#!/usr/bin/env python3
import argparse
import hashlib
import json
from pathlib import Path
import struct
import sys
import urllib.request

ROOT = Path(__file__).resolve().parent.parent
PIN = json.loads((ROOT / "dependencies.json").read_text())["doomgeneric"]["shareware_iwad"]
URL, SHA256, SIZE = PIN["url"], PIN["sha256"], PIN["bytes"]


def verify(data):
    if len(data) != SIZE or hashlib.sha256(data).hexdigest() != SHA256:
        raise ValueError("Expected the unmodified 4,196,020-byte Doom shareware 1.9 IWAD")
    magic, count, directory = struct.unpack_from("<4sII", data)
    if magic != b"IWAD" or directory + count * 16 > len(data):
        raise ValueError("Invalid IWAD directory")
    for index in range(count):
        offset, size, _ = struct.unpack_from("<II8s", data, directory + index * 16)
        if offset + size > len(data):
            raise ValueError("Invalid IWAD lump")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, default=ROOT / ".local/assets/doom1.wad")
    args = parser.parse_args()
    if args.output.exists():
        verify(args.output.read_bytes())
    else:
        print("Downloading Doom 1.9 shareware IWAD...", file=sys.stderr)
        with urllib.request.urlopen(URL, timeout=60) as response:
            data = response.read(SIZE + 1)
        verify(data)
        args.output.parent.mkdir(parents=True, exist_ok=True)
        temporary = args.output.with_suffix(".download")
        temporary.write_bytes(data)
        temporary.replace(args.output)
    print(f"Verified {args.output}: {SIZE} bytes, SHA256 {SHA256}", file=sys.stderr)


if __name__ == "__main__":
    main()
