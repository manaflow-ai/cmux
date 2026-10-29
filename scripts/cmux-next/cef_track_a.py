"""Whether the shipping feature `cefLayerHosting` can host a page on the running fork at all.

The feature hosts a pane's page only where the app makes every Track A call (CEFLayerHosting.TrackA.required): the
resize fence from fork API 32 (`CEFLayerHosting.resizeFenceForkAPI`) and embedder visibility from fork API 34
(`CEFLayerHosting.embedderVisibilityForkAPI`). Below the later of the two no page hosts, so a "layer hosting on" check
or bench on such a pin measures nothing: it is skipped, not failed. cef-layer-verify.py --mode on then exits
SKIP_EXIT, and its callers (cef-layer-ab.py, cef-resize-sync-bench.py, cef-pin-staging.sh,
split-spring-terminal.py --suite=cef-resize-sync) report that exit as a skip, never as red.

From fork API 34 a page that still does not host is a real failure (`valid`: hosting_without_track_a), for example
with the feature `cefResizeFence` off.

Under the perf-lab runner a bench that skipped a mode adds NEED to the runner's probe file (``report_lab_skip``), so
run_story.py reads the run as not-measurable (the build lacks a need), never as a failed run.
"""
import json
import os

# A distinct exit code: 0 passed, 1 failed, SKIP_EXIT the check could not apply to this pin.
SKIP_EXIT = 3
RESIZE_FENCE_FORK_API = 32
EMBEDDER_VISIBILITY_FORK_API = 34
TRACK_A_FORK_API = max(RESIZE_FENCE_FORK_API, EMBEDDER_VISIBILITY_FORK_API)
# The need a skipped run lacks, in the perf-lab probe file's `missing` list.
NEED = f"cef-fork-api>={TRACK_A_FORK_API}"
# The perf-lab runner's probe file (bench_launch.LAB_PROBE_OUT, run_story.PROBE_FILE).
LAB_PROBE_OUT = "PERF_LAB_PROBE_OUT"


def skip_reason(mode, fork_api):
    """The skip line for a layer hosting `mode` on a fork of `fork_api`; None when the check applies. Mode off always
    applies, and so does a fork API of 0 (no Chromium came up: that is a failure, not a skip)."""
    if mode != "on" or not fork_api or fork_api >= TRACK_A_FORK_API:
        return None
    return f"skipped: needs CEF API >= {TRACK_A_FORK_API}, pin has {fork_api}"


def exit_code(rows, skipped):
    """The verify's exit: 1 when a row failed (or none ran without a skip), SKIP_EXIT when skipped, else 0."""
    if rows and not all(r.get("ok") for r in rows):
        return 1
    if skipped:
        return SKIP_EXIT
    return 0 if rows else 1


def report_lab_skip(environ=None):
    """Under the perf-lab runner (``LAB_PROBE_OUT`` set): adds NEED to the probe file's `missing`, keeping what the
    bench's launch wrote there. Returns the file's path, or None outside the runner."""
    path = (os.environ if environ is None else environ).get(LAB_PROBE_OUT)
    if not path:
        return None
    try:
        with open(path) as f:
            data = json.load(f)
    except (OSError, ValueError):
        data = {}
    if not isinstance(data, dict):
        data = {}
    missing = [n for n in data.get("missing") or [] if isinstance(n, str)]
    if NEED not in missing:
        missing.append(NEED)
    data["missing"] = missing
    os.makedirs(os.path.dirname(os.path.abspath(path)), exist_ok=True)
    with open(path, "w") as f:
        json.dump(data, f, indent=2, sort_keys=True)
    return path
