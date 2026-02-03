import subprocess


def test_cmuxd_requires_transport():
    proc = subprocess.run([
        "/opt/cmuxterm/cmuxd/zig-out/bin/cmuxd",
    ], capture_output=True, text=True)
    assert proc.returncode != 0
    assert "must enable" in proc.stderr
