#!/usr/bin/env python3
"""Rows of the restore journey (restore-journey.py) that read the app's view report
(`debug.surfaces`): pure functions of what the report holds, so they are tested without an app
(tests/test_rj_rows.py). restore-journey-slot.sh copies this file next to the journey."""


def grid_fits_view(label, pp, view):
    """A row: the terminal renders the grid its view fits (`fit_grid`), so the shell has no rows
    past the pane's edge. Read after the settle wait, so a grid that never follows its view fails
    here even when it is equally wrong before and after the relaunch (cx-yt7rt)."""
    surface = view.get("surface") or {}
    grid, fit = surface.get("grid"), surface.get("fit_grid")
    row = f"{label}: {pp}.view.grid_fits_view"
    if not grid:
        return (row, False, "no terminal grid drawn", "layout")
    if "fit_grid" not in surface:
        return (row, True, f"grid {grid}; this build reports no fit_grid", "layout")
    return (row, fit is not None and fit == grid, f"grid {grid}, view fits {fit}", "layout")
