#!/usr/bin/env python3
"""Rows of the restore journey (restore-journey.py) that read the app's view report
(`debug.surfaces`): pure functions of what the report holds, so they are tested without an app
(tests/test_rj_rows.py). restore-journey-slot.sh copies this file next to the journey."""


def report_error(report):
    """Why a `debug.surfaces` report cannot be read (its error, or "no report"), or None when it can."""
    if not isinstance(report, dict):
        return "no report"
    if "error" in report:
        return str(report.get("error"))
    return None


def grid_fits_view(label, pp, view, report=None):
    """A row: the terminal renders the grid its view fits (`fit_grid`), so the shell has no rows
    past the pane's edge. Read after the settle wait, so a grid that never follows its view fails
    here even when it is equally wrong before and after the relaunch (cx-yt7rt).

    `report` is the whole `debug.surfaces` answer `view` came from. A report the app did not answer
    (a timeout on a loaded host) or a pane missing from it fails as what it is, never as a terminal
    that drew no grid (rj-v4: the shot showed all seven drawn)."""
    row = f"{label}: {pp}.view.grid_fits_view"
    if report is not None:
        error = report_error(report)
        if error is not None:
            return (row, False, f"debug.surfaces unreadable: {error}", "harness")
    if not view:
        return (row, False, "pane not in the app's view report", "layout")
    if "surface" not in view:
        return (row, False, f"no terminal surface (kind {view.get('kind')!r}, presence {view.get('presence')!r})", "layout")
    surface = view.get("surface") or {}
    grid, fit = surface.get("grid"), surface.get("fit_grid")
    if not grid:
        return (row, False, "no terminal grid drawn", "layout")
    if "fit_grid" not in surface:
        return (row, True, f"grid {grid}; this build reports no fit_grid", "layout")
    return (row, fit is not None and fit == grid, f"grid {grid}, view fits {fit}", "layout")
