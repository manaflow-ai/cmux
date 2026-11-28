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

    assert profile('! cmux_npm_host_cache "$3" "$2"; test -z "${npm_config_cache+x}"', home) == ""
    assert profile('export FIXTURE_UID=0; ! cmux_npm_host_cache "$1" "$2"; test -z "${npm_config_cache+x}"') == ""
    assert profile('export NPM_CONFIG_CACHE=custom; ! cmux_npm_host_cache "$1" "$2"; test -z "${npm_config_cache+x}"') == ""
    assert list(mount.iterdir()) == []

    def package(name):
        payload = f'{{"name":"{name}","version":"1.0.0"}}'.encode()
        with tarfile.open(root / f"{name}.tgz", "w:gz") as tar:
            entry = tarfile.TarInfo("package/package.json")
            entry.size = len(payload)
            tar.addfile(entry, io.BytesIO(payload))
        return payload

    manifests = {name: package(name) for name in ("seed-fixture", "guest-fixture")}
    with ThreadingHTTPServer(("127.0.0.1", 0), partial(PackageHandler, directory=str(root))) as registry:
        urls = {name: f"http://127.0.0.1:{registry.server_port}/{name}.tgz" for name in manifests}
        thread = threading.Thread(target=registry.serve_forever)
        thread.start()
        try:
            run(["npm", "cache", "add", urls["seed-fixture"], "--cache", seed.parent, "--fetch-retries=0"])
            activate = 'cmux_npm_host_cache "$1" "$2"; printf "%s" "$npm_config_cache"'
            with ThreadPoolExecutor(max_workers=4) as pool:
                caches = list(pool.map(lambda _: profile(activate), range(4)))
            assert caches == [str(mount / "npm")] * 4, caches
            # This package arrives after the bake and must only enter tenant A's cache.
            profile('cmux_npm_host_cache "$1" "$2"; npm install --ignore-scripts --no-audit --no-fund "$3"',
                    urls["guest-fixture"])
        finally:
            registry.shutdown()
            thread.join()

    second = root / "second-guest"
    second.mkdir()
    profile('export HOME="$3"; cd "$HOME"; cmux_npm_host_cache "$1" "$HOME/.npm/_cacache"; '
            'npm install --offline --ignore-scripts --no-audit --no-fund "$4" "$5"', second, *urls.values())
    for name, manifest in manifests.items():
        assert (second / "node_modules" / name / "package.json").read_bytes() == manifest

    # A separate simulated mount given the same image seed must miss the guest-only tarball.
    other = root / "tenant-b"
    other.mkdir()
    miss = profile('export FIXTURE_MOUNT="$3"; cmux_npm_host_cache "$3" "$2"; '
                   'npm cache add --offline "$4" 2>&1 && exit 1; exit 0', other, urls["guest-fixture"])
    assert "ENOTCACHED" in miss, miss
    print("Simulated mounts: fresh home installed baked and guest-added packages offline; separate mount returned ENOTCACHED.")


if __name__ == "__main__":
    with tempfile.TemporaryDirectory() as directory:
        check(Path(directory))
