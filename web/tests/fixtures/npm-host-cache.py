"""Exercise the image profile with a local tarball and isolated guest homes."""
import io
import os
from pathlib import Path
import subprocess
import tarfile
import tempfile
import threading
from concurrent.futures import ThreadPoolExecutor
from functools import partial
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer

PROFILE = Path(__file__).resolve().parents[3] / "images/cmux-vm/guest/npm-host-cache.sh"


class PackageHandler(SimpleHTTPRequestHandler):
    def log_message(self, *args):
        pass


def check(root):
    home = root / "guest"
    mount = root / "tenant-a"
    binaries = root / "bin"
    for path in (home, mount, binaries):
        path.mkdir()
    # Only guest identity and the hypervisor's mountpoint answer are simulated.
    for name, body in {
        "id": 'case "$1" in -un) echo cmux;; -u) echo "${FIXTURE_UID:-1000}";; *) exit 1;; esac',
        "mountpoint": 'test "$PWD" = "$FIXTURE_MOUNT"',
    }.items():
        stub = binaries / name
        stub.write_text("#!/bin/sh\n" + body + "\n")
        stub.chmod(0o755)
    env = dict(PATH=f"{binaries}:{os.environ['PATH']}", HOME=str(home), FIXTURE_MOUNT=str(mount))
    seed = home / ".npm/_cacache"

    def run(args, **kwargs):
        result = subprocess.run(args, env=env, cwd=home, capture_output=True, text=True, timeout=20, **kwargs)
        if result.returncode:
            raise RuntimeError(result.stderr or result.stdout or f"{args[0]} exited {result.returncode}")
        return result.stdout.strip()

    def profile(script, *args):
        return run(["sh", "-ec", 'npm_config_cache=disabled; . "$1"; unset npm_config_cache; shift; ' + script,
                    "profile-test", PROFILE, mount, seed, *args])

    tarball = root / "sample.tgz"
    with tarfile.open(tarball, "w:gz") as package:
        manifest = b'{"name":"seed-fixture","version":"1.0.0"}'
        entry = tarfile.TarInfo("package/package.json")
        entry.size = len(manifest)
        package.addfile(entry, io.BytesIO(manifest))
    with ThreadingHTTPServer(("127.0.0.1", 0), partial(PackageHandler, directory=str(root))) as registry:
        url = f"http://127.0.0.1:{registry.server_port}/sample.tgz"
        thread = threading.Thread(target=registry.serve_forever)
        thread.start()
        try:
            run(["npm", "cache", "add", url, "--cache", seed.parent, "--fetch-retries=0"])
        finally:
            registry.shutdown()
            thread.join()

    assert profile('! cmux_npm_host_cache "$3" "$2"; test -z "${npm_config_cache+x}"', home) == ""
    assert profile('export FIXTURE_UID=0; ! cmux_npm_host_cache "$1" "$2"; test -z "${npm_config_cache+x}"') == ""
    assert profile('export NPM_CONFIG_CACHE=custom; ! cmux_npm_host_cache "$1" "$2"; test -z "${npm_config_cache+x}"') == ""
    assert list(mount.iterdir()) == []

    activate = 'cmux_npm_host_cache "$1" "$2"; printf "%s" "$npm_config_cache"'
    with ThreadPoolExecutor(max_workers=4) as pool:
        caches = list(pool.map(lambda _: profile(activate), range(4)))
    assert caches == [str(mount / "npm")] * 4, caches
    second = root / "second-guest"
    second.mkdir()
    # A fresh guest with no local seed installs after the only registry has closed.
    profile('export HOME="$3"; cd "$HOME"; cmux_npm_host_cache "$1" "$HOME/.npm/_cacache"; '
            'npm install --offline --ignore-scripts --no-audit --no-fund "$4"', second, url)
    assert (second / "node_modules/seed-fixture/package.json").read_bytes() == manifest


if __name__ == "__main__":
    with tempfile.TemporaryDirectory() as directory:
        check(Path(directory))
