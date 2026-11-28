# Stable identity in catalog projections

`cmux surface ls --json` (`surface.catalog`) and `cmux vm tree --json` expose
two nullable read fields on each local projection:

```json
{
  "resource": "local/terminal/<current-panel-uuid>",
  "workspace_id": "<current-workspace-uuid>",
  "panel_id": "<current-panel-uuid>",
  "surface_id": "<current-panel-uuid>",
  "stable_surface_id": "<persisted-surface-uuid>",
  "stable_workspace_id": "<persisted-workspace-uuid>",
  "remote_workspace_id": null,
  "remote_tab_id": null
}
```

These fields join the current projection to the identities already owned by its
panel and workspace. They do not replace resource IDs or runtime selectors.
Callers can retain a stable surface ID across a non-colliding session restore,
read the catalog again, and discover its current runtime projection. Labels and
working directories are not identity selectors.

The query captures these values from exact live owners in the same main-actor
turn as the catalog export. The serializer only reads captured values. Missing
workspace/panel owners, or an owner whose current UUID does not match the
projection, produce null for both fields. Older servers may omit the fields;
consumers must treat omission as unknown rather than copying a runtime UUID.

| Operation | Stable surface | Stable workspace | Runtime selectors |
| --- | --- | --- | --- |
| Move pane into another workspace | Same owner identity | Destination workspace's identity | Existing owner behavior |
| Restore session without a live identity collision | Persisted identity | Persisted identity | May change; reacquire from the new read |
| Restore a duplicate while the original is live | Restore owner chooses fresh identity | Restore owner chooses fresh identity | New instance |
| Close/reopen a Cloud mirror | Describes this local mirror only | Describes local placement only | May change independently of daemon resource |

For Cloud resources, `resource` remains machine-namespaced daemon identity.
The new stable fields identify local projection owners; they do not promise
process survival, cross-machine identity or conversation resumability. Cloud
generation/revision cursors and mutation receipts retain their separate roles.
These read fields grant no mutation authority and are not accepted as new write
selectors. A consumer must still reconcile current state before acting.

Native behavioral coverage is in `SurfaceProjectionIdentityTests`: real owner
capture and JSON serialization, immutable exports, moves, session restore,
colliding restores, missing/mismatched owners, Cloud mirrors and identical
label/directory metadata.
