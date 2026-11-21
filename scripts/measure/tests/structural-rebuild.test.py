#!/usr/bin/env python3
"""structural-rebuild.py's log reading and edit, with no build: the timing summary and the driver's receipt come
out of a reload log (not an earlier build's receipt), the edit adds one stored property inside HomeHostView, and a
run refuses a source file with local edits; a SIGTERM during a reload unwinds and ends the reload's process
group, SIGKILLing a member that ignores SIGTERM."""
# tests/git_fixture_env.py, loaded by path (`python3 -I` puts no script folder on sys.path): it drops inherited
# GIT_DIR / GIT_INDEX_FILE / GIT_CONFIG redirects and turns off git's background maintenance in temp repos.
import importlib.util as _git_fixture_importlib  # noqa: E402
from os import path as _git_fixture_path  # noqa: E402
_git_fixture_spec = _git_fixture_importlib.spec_from_file_location(
    "git_fixture_env", _git_fixture_path.join(_git_fixture_path.dirname(_git_fixture_path.abspath(__file__)), '..', '..', '..', 'tests', "git_fixture_env.py"))
git_fixture_env = _git_fixture_importlib.module_from_spec(_git_fixture_spec)
_git_fixture_spec.loader.exec_module(git_fixture_env)
import importlib.util, json, os, signal, subprocess, sys, tempfile, time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]
spec = importlib.util.spec_from_file_location("structural_rebuild", ROOT / "scripts/measure/structural-rebuild.py")
sr = importlib.util.module_from_spec(spec)
spec.loader.exec_module(sr)
# tests/process_gone.py by path: `python3 -I` puts no script folder on sys.path.
spec = importlib.util.spec_from_file_location("process_gone", ROOT / "tests/process_gone.py")
process_gone = importlib.util.module_from_spec(spec)
spec.loader.exec_module(process_gone)

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
# A SIGTERM during a reload (the step's timeout) unwinds as SystemExit, and the reload's whole process group
# (reload.sh and the xcodebuild it started) is ended, not left running into the next measurement.
with tempfile.TemporaryDirectory(prefix="structural-rebuild-") as tmp:
    (Path(tmp) / "scripts").mkdir()
    reload_sh = Path(tmp) / "scripts/reload.sh"
    reload_sh.write_text("#!/bin/sh\nsleep 300 &\necho $! > child.pid\necho started\nwait\n")
    reload_sh.chmod(0o755)
    driver = (f"import importlib.util, signal, sys\n"
              f"spec = importlib.util.spec_from_file_location('sr', {str(ROOT / 'scripts/measure/structural-rebuild.py')!r})\n"
              f"sr = importlib.util.module_from_spec(spec); spec.loader.exec_module(sr)\n"
              f"sr.ROOT = {tmp!r}\n"
              f"signal.signal(signal.SIGTERM, sr.exit_on_signal)\n"
              f"try:\n    sr.reload('', {tmp!r}, 0)\n"
              f"finally:\n    open({str(Path(tmp) / 'unwound')!r}, 'w').write('yes')\n")
    run = subprocess.Popen([sys.executable, "-c", driver], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    assert "started" in run.stdout.readline()
    child = int((Path(tmp) / "child.pid").read_text())
    sent = time.monotonic()
    run.send_signal(signal.SIGTERM)
    _, err = run.communicate(timeout=60)
    assert run.returncode == 1 and "ended by signal" in err, (run.returncode, err)
    # reload.sh takes the cleanup's SIGTERM at once: the run does not sit out the grace and SIGKILL it.
    assert time.monotonic() - sent < 10, f"cleanup took {time.monotonic() - sent:.1f} s"
    assert (Path(tmp) / "unwound").read_text() == "yes"
    # The child, reparented once reload.sh ended, is gone once it has exited: a zombie not reaped yet counts.
    assert process_gone.died(child), f"the reload's child {child} outlived the run"
# A process in the reload's group that ignores SIGTERM is SIGKILLed after the grace, even once reload.sh is gone.
with tempfile.TemporaryDirectory(prefix="structural-rebuild-") as tmp:
    (Path(tmp) / "scripts").mkdir()
    reload_sh = Path(tmp) / "scripts/reload.sh"
    reload_sh.write_text("#!/bin/sh\n(trap '' TERM; exec sleep 300) &\necho $! > child.pid\necho started\nwait\n")
    reload_sh.chmod(0o755)
    driver = (f"import importlib.util, signal, sys\n"
              f"spec = importlib.util.spec_from_file_location('sr', {str(ROOT / 'scripts/measure/structural-rebuild.py')!r})\n"
              f"sr = importlib.util.module_from_spec(spec); spec.loader.exec_module(sr)\n"
              f"sr.ROOT = {tmp!r}\nsr.GROUP_GRACE_S = 1\n"
              f"signal.signal(signal.SIGTERM, sr.exit_on_signal)\n"
              f"sr.reload('', {tmp!r}, 0)\n")
    run = subprocess.Popen([sys.executable, "-c", driver], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    assert "started" in run.stdout.readline()
    child = int((Path(tmp) / "child.pid").read_text())
    run.send_signal(signal.SIGTERM)
    _, err = run.communicate(timeout=60)
    assert "ended by signal" in err, (run.returncode, err)
    if not process_gone.died(child):
        try:
            os.kill(child, signal.SIGKILL)
        except ProcessLookupError:
            pass
        raise AssertionError(f"the reload's child {child}, which ignores SIGTERM, outlived the run")
# macOS answers killpg with EPERM once the group holds only zombies: the cleanup takes that as gone, not an error
# that would cut it short and replace the stop that started it.
class Gone:
    pid = 4242
    def poll(self):
        return 0
real_killpg, sr.os.killpg = sr.os.killpg, lambda pgid, sig: (_ for _ in ()).throw(PermissionError(1, "EPERM"))
try:
    sr.end_group(Gone())
finally:
    sr.os.killpg = real_killpg
print("structural-rebuild.test.py: ok")
