# Current work

`cmux current --json` and **Find Work** in the command palette read the same
bounded snapshot of work already known to CMUX. The default CLI output renders
that snapshot as text.

```sh
cmux current
cmux current --json
cmux current --json --limit 50
```

The read includes known surface resources, their local projections and durable
identity, placement, labels, working directories, agent state, attention, and PR
facts. Missing facts stay absent or unknown. It does not discover repositories
from transcripts, infer review findings from prose, or query a new database.

## Identity and freshness

A resource reference identifies a catalog resource. A durable local surface ID
survives supported session restoration. A projection identifies where that
resource is currently displayed; its workspace and panel IDs are runtime
selectors. These identifiers have different lifetimes and are not a universal
work-item ID. See [surface catalog identity](surface-catalog-identity.md).

The snapshot observation time describes when CMUX read its owners. It is not
proof that a remote agent or PR was refreshed at that instant. Owner freshness,
available cursor/receipt references, and evidence remain attached to their
facts. Possible human obligations describe owner-reported attention; they do
not grant an agent permission to act.

## Bounds and effects

The result defaults to 100 resources and accepts a limit from 1 through 200.
Truncation is explicit. Reads do not refresh Cloud machines, start agents,
reopen historical sessions, or mutate focus. Find Work uses the existing focus
path only after the user selects a displayed local projection. A Cloud resource
without a local projection can be listed without implicitly opening one.

This view is an observation, not an execution or mutation API. Existing owners
continue to control persistence, scheduling, lifecycle, security, and focus.
