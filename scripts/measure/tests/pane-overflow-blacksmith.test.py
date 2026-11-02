#!/usr/bin/env python3
"""Execute the manual Blacksmith workflow with stubbed native tools; no build."""
import os
from pathlib import Path
import subprocess
import tempfile
import textwrap

root = Path(__file__).resolve().parents[3]
workflow = (root / ".github/workflows/cmux-next-perf-budgets.yml").read_text()
start = workflow.index("      - name: Run the exact tip's GUI parts")
command = workflow[start:].split("        run: |\n", 1)[1].split("\n      - name:", 1)[0]
command = textwrap.dedent(command)
with tempfile.TemporaryDirectory(prefix="fade-blacksmith-") as directory:
    repo = Path(directory)
    scripts = repo / "scripts/measure"
    scripts.mkdir(parents=True)
    (repo / "bin").mkdir()
    git = repo / "bin/git"
    git.write_text("""#!/bin/bash
case "$1" in
  rev-parse) printf '%s\n' "$TIP_SHA" ;;
  fetch|merge-base) exit 0 ;;
  *) exit 90 ;;
esac
""")
    git.chmod(0o755)
    build = scripts / "split-spring.sh"
    build.write_text("#!/bin/bash\nexit 99\n")
    build.chmod(0o755)
    measure = scripts / "pane-overflow-fade.sh"
    measure.write_text("""#!/bin/bash
set -eu
[ "$1" = "$PRODUCT_SHA" ]
mkdir -p artifacts
printf 'archive fixture' > artifacts/pane-overflow-fade.tar.gz
printf 'MEASURED=%s\n' "$1"
""")
    measure.chmod(0o755)
    tip, product = "a" * 40, "b" * 40
    env = os.environ | {"TIP_SHA": tip, "PRODUCT_SHA": product,
        "PARTS": "pane-overflow-fade", "RUNNER_CLASS": "blacksmith-6vcpu-macos-26",
        "RUNNER_TEMP": str(repo / "runner"), "GITHUB_STEP_SUMMARY": str(repo / "summary"),
        "PATH": str(repo / "bin") + os.pathsep + os.environ["PATH"]}
    result = subprocess.run(["bash", "-c", command], cwd=repo, env=env,
                            capture_output=True, text=True)
    assert result.returncode == 0, result.stdout + result.stderr
    out = repo / "runner/tipguard-blacksmith"
    assert (out / "pane-overflow-fade.tar.gz").read_bytes() == b"archive fixture"
    assert f"MEASURED={product}" in (out / "pane-fade.log").read_text()
    assert tip in (out / "receipt.json").read_text()
    assert product in (out / "receipt.json").read_text()
    # A source-fence failure must keep the failed attempt's own frame archive.
    (out / "pane-overflow-fade.tar.gz").unlink()
    measure.write_text(measure.read_text() + "exit 17\n")
    result = subprocess.run(["bash", "-c", command], cwd=repo, env=env,
                            capture_output=True, text=True)
    assert result.returncode != 0, "failed measurement was accepted"
    assert (out / "pane-overflow-fade.tar.gz").read_bytes() == b"archive fixture"
print("PASS Blacksmith fade part: exact product forwarded, no full app build, proof archive retained")
