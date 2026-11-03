#!/usr/bin/env python3
"""Reproduce the historical cache install deleting tracked placeholder docs; no build."""
from pathlib import Path
import os
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[3]
WRAPPER = ROOT / "scripts/measure/pane-overflow-bundle-setup.py"
FOLDERS = ("CmuxNextAgentPane/Resources/agent-pane", "CmuxNextPages/Resources/pages",
           "CmuxNextAgentActivity/Resources/agent-activity")
with tempfile.TemporaryDirectory(prefix="pane-fade-bundles-") as tmp:
    repo = Path(tmp)
    def git(*args):
        return subprocess.check_output(["git", "-C", str(repo), *args], text=True).strip()
    git("init", "-q")
    docs = [repo / "Packages/macOS/CmuxNext/Sources" / folder / "GENERATED.md" for folder in FOLDERS]
    for doc in docs:
        doc.parent.mkdir(parents=True)
        doc.write_bytes(b"Tracked placeholder.\n")
    (repo / "product.swift").write_text("original product\n")
    git("add", ".")
    git("-c", "user.name=fixture", "-c", "user.email=fixture@example.test",
        "-c", "core.hooksPath=/dev/null", "commit", "-qm", "source")
    builder = repo / "scripts/cmux-next/build-web-bundles.sh"
    builder.parent.mkdir(parents=True)
    builder.write_text("#!/bin/sh\nset -eu\n" + "\n".join(
        'rm "' + str(doc.relative_to(repo)) + '"' for doc in docs) + "\n" +
        'if [ "${MUTATE:-}" = doc ]; then echo changed > "' + str(docs[0].relative_to(repo)) + '"; fi\n' +
        'if [ "${MUTATE:-}" = product ]; then echo changed > product.swift; fi\n' +
        'exit "${BUILDER_EXIT:-0}"\n')
    builder.chmod(0o755)
    command = [str(WRAPPER)] if WRAPPER.exists() else [str(builder)]
    def run(**extra):
        return subprocess.run(command + ["--from", "cache"], cwd=repo,
                              env=os.environ | extra, capture_output=True, text=True)
    result = run()
    assert result.returncode == 0, result.stderr
    assert all(doc.exists() and doc.read_bytes() == b"Tracked placeholder.\n" for doc in docs), "cache install deleted tracked GENERATED.md"
    assert git("diff", "--name-only") == "", "setup changed tracked source"
    result = run(MUTATE="doc")
    assert result.returncode != 0 and docs[0].read_text() == "changed\n", "modified document was silently overwritten"
    git("restore", ".")
    result = run(MUTATE="product")
    assert result.returncode == 0 and git("diff", "--name-only") == "product.swift", "product mutation was hidden"
    git("restore", ".")
    result = run(BUILDER_EXIT="17")
    assert result.returncode == 17, "builder failure was accepted"
    assert 'CMUX_WEB_BUNDLES_BUILD="$ROOT/scripts/measure/pane-overflow-bundle-setup.py"' in (ROOT / "scripts/measure/pane-overflow-fade.sh").read_text(), "historical checkout does not use the setup repair"
print("PASS historical cache setup: exact placeholders retained; doc/source mutations and failures remain visible")
