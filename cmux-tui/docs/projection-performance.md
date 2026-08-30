# Projection rendering performance

The sidebar projection is an immediate-mode render. `App::projection_rows`
currently rebuilds `ProjectionRow` values on each draw, including owned names
and subtitles. The current state model exposes tree revisions, but it does not
expose a single revision covering view specifications, collapsed branches, and
agent metadata. A cache keyed only by `workspace_revision` or `pane_revision`
would therefore return stale rows. Adding a cache safely needs one composite
invalidating revision (or explicit mutation hooks) before it can reduce the
per-frame allocations.

Retired-surface cleanup is already set based: the refresh builds one
`live_surface_ids` set by walking the tree, then retains retired IDs with a
hash lookup. Its cost is O(tree + retired), not O(tree * retired). Replacing
this with a nested scan would regress large trees.

This follows Ratatui's rendering model and guidance:

- <https://ratatui.rs/concepts/rendering/under-the-hood/>
- <https://ratatui.rs/concepts/rendering/>
- <https://github.com/ratatui-org/ratatui/discussions/579>

No benchmark was run in this pass because the task permits formatting-only
verification. Measure allocation counts and frame time after introducing a
composite revision, then add a cache with tests for every invalidation source.
