# path_route: id: checkout

Where: the `path_route` job in `.github/workflows/cmux-next.yml`, above `- id: checkout`.

Why: note-469
A checkout that GitHub's slowness broke (2026-11-25 from 12Z: 702 path routing failures, "Operation too
slow. Less than 1 bytes/sec transferred the last 60 seconds" on the lazy blob fetch, vs 8 the day before) is
tried twice more after a pause: every job routed here waits on it (docs/handbook
transient-transport-failure-as-hard-error.md).
