#!/usr/bin/env python3
"""structural-rebuild.py's log reading and edit, with no build: the timing summary and the driver's receipt come
out of a reload log (not an earlier build's receipt), the edit adds one stored property inside HomeHostView, and a
run refuses a source file with local edits."""
import importlib.util, json, os, subprocess, tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
spec = importlib.util.spec_from_file_location("structural_rebuild", ROOT / "scripts/measure/structural-rebuild.py")
sr = importlib.util.module_from_spec(spec)
spec.loader.exec_module(sr)

with tempfile.TemporaryDirectory(prefix="structural-rebuild-") as tmp:
    log = Path(tmp) / "cmux-reload-srebuild.log"
    log.write_text("CompileSwiftSources (9 tasks) | 1.0 seconds\n"  # an earlier summary: only the last one counts
                   "Build Timing Summary\n\n"
                   "CompileSwiftSources (17 tasks) | 41.250 seconds\n"
                   "Ld (1 task) | 3.5 seconds\n"
                   "PhaseScriptExecution (13 tasks) | 22.1 seconds\n\n** BUILD SUCCEEDED **\n")
    Path(str(log) + ".incremental.json").write_text(json.dumps(
        {"counts": {"initial_files": 1, "dependency_cascade_files": 16, "scheduled_invalidated_files": 17,
                    "incremental_disabled_reasons": 0, "dependency_read_failures": 0, "diagnostic_evidence_lines": 40}}))
    facts = sr.build_facts(str(log))
    assert facts["timing"] == {"CompileSwiftSources": {"tasks": 17, "seconds": 41.25},
                               "Ld": {"tasks": 1, "seconds": 3.5},
                               "PhaseScriptExecution": {"tasks": 13, "seconds": 22.1}}, facts
    assert facts["incremental"] == {"initial_files": 1, "dependency_cascade_files": 16,
                                    "scheduled_invalidated_files": 17, "incremental_disabled_reasons": 0,
                                    "dependency_read_failures": 0}, facts
    assert sr.build_facts(os.path.join(tmp, "missing.log")) == {"timing": {}, "incremental": None}
    # A receipt written before this reload started is an earlier build's: the reload's own diagnostics failed.
    receipt = str(log) + ".incremental.json"
    os.utime(receipt, (1000, 1000))
    assert sr.build_facts(str(log), since=2000)["incremental"] is None
    assert sr.build_facts(str(log), since=1000)["incremental"]["initial_files"] == 1

    source = Path(tmp) / sr.EDIT_FILE
    source.parent.mkdir(parents=True)
    source.write_text("import AppKit\n\n@MainActor\nfinal class HomeHostView: NSView {\n    let transcript: Int\n}\n")
    sr.ROOT = tmp
    sr.add_property(1)
    sr.add_property(2)
    assert source.read_text() == ("import AppKit\n\n@MainActor\nfinal class HomeHostView: NSView {\n"
                                  "    var structuralRebuildProbe2 = 2\n    var structuralRebuildProbe1 = 1\n"
                                  "    let transcript: Int\n}\n"), source.read_text()

    # The run takes its edits back with git checkout, so it refuses a file that already has local edits.
    git = lambda *a: subprocess.run(["git", "-C", tmp, *a], check=True, capture_output=True)
    git("init", "-q")
    git("add", sr.EDIT_FILE)
    git("-c", "user.name=t", "-c", "user.email=t@t", "commit", "-qm", "base")
    sr.refuse_local_edits()
    source.write_text(source.read_text() + "// mine\n")
    try:
        sr.refuse_local_edits()
        raise AssertionError("a file with local edits was accepted")
    except SystemExit as refusal:
        assert "has local changes" in str(refusal), refusal
print("structural-rebuild.test.py: ok")
