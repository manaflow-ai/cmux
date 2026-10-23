"""Whether a STRESS session built by perf-stress-session.py has the standard shape (perf-lead brief):
the builder's WORKSPACES new workspaces on top of the launch's own first one, 12 or more measured
panes, and no real refusal. One check for every bench that builds STRESS (bench-page-cadence.py,
bench-palette-fling.py); load it by path, as they load bench-stalls.py.

A refusal the builder answers with a stand-in does not make the shape non-standard: a build with no
agent chat refuses `palette.newAgentChat` and the builder opens the New Tab page instead.
"""

# Actions perf-stress-session.py follows with a stand-in when they are refused.
FALLBACK_ACTIONS = {"palette.newAgentChat"}

MEASURED_PANES = 12


def real_refusals(refusals):
    """The refusals (`"action: error"` strings) the builder had no stand-in for."""
    return [r for r in refusals or [] if r.split(":", 1)[0] not in FALLBACK_ACTIONS]


def check(stress_module, builder, summary):
    """(standard, real refusals) for the STRESS `summary` that `builder` (a `stress_module.Stress`)
    built. Reads the builder's full refusal list: the summary keeps only the first 10, which the
    agent chat stand-ins alone can fill."""
    refusals = real_refusals(getattr(builder, "refusals", None) or summary.get("refusals"))
    standard = ((summary.get("workspaces") or 0) >= stress_module.WORKSPACES + 1
                and (summary.get("measured_panes") or 0) >= MEASURED_PANES
                and not refusals)
    return standard, refusals
