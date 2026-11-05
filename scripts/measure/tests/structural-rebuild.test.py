#!/usr/bin/env python3
"""structural-rebuild.py's log reading and edit, with no build: the timing summary and the driver's receipt come
out of a reload log, and the edit adds one stored property inside HomeHostView."""
import importlib.util, json, os, tempfile
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

    source = Path(tmp) / sr.EDIT_FILE
    source.parent.mkdir(parents=True)
    source.write_text("import AppKit\n\n@MainActor\nfinal class HomeHostView: NSView {\n    let transcript: Int\n}\n")
    sr.ROOT = tmp
    sr.add_property(1)
    sr.add_property(2)
    assert source.read_text() == ("import AppKit\n\n@MainActor\nfinal class HomeHostView: NSView {\n"
                                  "    var structuralRebuildProbe2 = 2\n    var structuralRebuildProbe1 = 1\n"
                                  "    let transcript: Int\n}\n"), source.read_text()
print("structural-rebuild.test.py: ok")
