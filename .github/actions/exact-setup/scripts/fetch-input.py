"""Download one digest-pinned public release input, in parallel for large files."""
import concurrent.futures
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import urllib.request

base, manifest, name, dest = sys.argv[1:]
if Path(name).name != name or not name:
    raise ValueError("Invalid release asset name")
details = json.loads(Path(manifest).read_text())[name]
size, expected = details["size"], details["sha256"]
if type(size) is not int or not 0 < size < 2_000_000_000 or not re.fullmatch("[a-f0-9]{64}", expected):
    raise ValueError("Invalid release asset metadata")
dest = Path(dest)
dest.parent.mkdir(parents=True, exist_ok=True)
url = f"{base}/{name}"

def digest(path):
    with path.open("rb") as stream:
        checksum = hashlib.sha256()
        for chunk in iter(lambda: stream.read(1024 * 1024), b""):
            checksum.update(chunk)
        return checksum.hexdigest()

if dest.is_file() and dest.stat().st_size == size and digest(dest) == expected:
    sys.exit(0)
with tempfile.TemporaryDirectory(dir=dest.parent) as work:
    partial = Path(work) / "asset"
    ranged = False
    if size >= 128 * 1024**2:
        # Resolve the public GitHub release redirect once for all ranges.
        head = urllib.request.Request(url, method="HEAD", headers={"Accept-Encoding": "identity"})
        try:
            with urllib.request.urlopen(head, timeout=20) as response:
                location = response.geturl()
            with partial.open("wb") as output:
                output.truncate(size)
                def fetch(start):
                    end = min(size, start + 32 * 1024**2) - 1
                    request = urllib.request.Request(location, headers={"Range": f"bytes={start}-{end}", "Accept-Encoding":"identity"})
                    with urllib.request.urlopen(request, timeout=30) as response:
                        if response.status != 206 or response.headers.get("Content-Range") != f"bytes {start}-{end}/{size}":
                            raise ValueError("Server does not support the requested range")
                        position = start
                        while data := response.read(1024**2):
                            if position + len(data) > end + 1:
                                raise ValueError("Oversized range")
                            if os.pwrite(output.fileno(), data, position) != len(data):
                                raise OSError("Short write")
                            position += len(data)
                        if position != end + 1:
                            raise ValueError("Incomplete range")
                with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:
                    list(pool.map(fetch, range(0, size, 32 * 1024**2)))
            ranged = True
        except (ValueError, OSError) as error:
            print(f"{name}: retrying with a single transfer ({type(error).__name__})", flush=True)
    if not ranged:
        subprocess.run(["curl", "-fsSL", "--retry", "3", "--output", str(partial), url], check=True)
    if partial.stat().st_size != size or digest(partial) != expected:
        raise ValueError(f"{name}: size or SHA-256 mismatch")
    os.replace(partial, dest)
    print(f"{name}: verified", flush=True)
