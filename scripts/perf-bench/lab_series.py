"""How an xbench row and browser become a perf-lab series (p12-perf-process-208).

One xbench run measures every browser on the same Mac against the same cmux build, so the lab series key's story,
engine, host and build are the same for all arms of a run: the browser goes into the metric, `<row>.<browser>`.
Chrome is the reference arm, as Telemetry measures a reference build beside the build under test. Its metrics end
in `_ref`, the suffix chromeperf gives a reference series and never alerts on (catapult
`dashboard/dashboard/find_anomalies.py`, `_IsRefBuild`). When cmux and Chrome move in the same window, the host
moved, not cmux.

`xbench.py story` writes result-v1 with these names; `scripts/perf-lab/import_xbench.py` imports the old
`baseline/*.json` files under the same names. Stdlib only and no imports, so both load it on any host.
"""

# The result-v1 engine of each browser xbench can measure in a lab story. cmux-budget is not one: its session opens
# Chromium and WebKit tabs and terminals in one app, so no single engine describes it.
BROWSER_ENGINES = {
    "cmux-chromium": "chromium",
    "cmux-webkit": "webkit",
    "cmux-terminal": "none",
    "chrome": "chromium",
    "helium": "chromium",
    "dia": "chromium",
    "ardia": "chromium",
    "safari": "webkit",
}
REFERENCE_BROWSERS = frozenset({"chrome"})
REFERENCE_SUFFIX = "_ref"

# xbench's row unit -> (result-v1 unit, factor from the row's value to it). procs.py counts MB as 2**20 bytes and
# KB as 1024 bytes; CPU % is of one core, as result-v1's `percent`.
RESULT_UNITS = {
    "ms": ("ms", 1.0),
    "mW": ("mW", 1.0),
    "/s": ("per_s", 1.0),
    "%": ("percent", 1.0),
    "MB": ("bytes", 1048576.0),
    "KB/s": ("bytes_per_s", 1024.0),
    "n": ("count", 1.0),
}


def metric_name(row: str, browser: str) -> str:
    """`<row>.<browser>`, with `_ref` after a reference arm's name."""
    return f"{row}.{browser}{REFERENCE_SUFFIX if browser in REFERENCE_BROWSERS else ''}"


def result_value(unit: str, value: float) -> tuple:
    """(result-v1 unit, value in it) for a value xbench recorded in `unit`; KeyError for a unit with no mapping."""
    result_unit, factor = RESULT_UNITS[unit]
    return result_unit, value * factor
