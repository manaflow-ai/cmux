# Custom pick: source contract and cmux alternative

Source: [official Custom UI, Asking for a Choice](https://www.superlogical.com/rex/docs/customize/custom-ui#asking-for-a-choice).

The source `ui.pick` API accepts a required title, filter placeholder/default
value, confirmation label and ordered items. It returns a selected item's ID.
Each ID is unique; title defaults to ID. Subtitle, icon, detail and preselection
are optional. Plain strings are shorthand. The limit is **2,000 items**.
Multiple selection returns IDs in source order, including an empty list when
nothing is checked. Cmd+Return confirms multiple selection. `allow_other`
returns a distinct `{text: ...}` object and cannot combine with multiple.
Timeout defaults to **300 seconds**, maximum **3,600 seconds**.

This profile's Opt+Cmd+P opens cmux's existing `tab.search` picker. Choose a tab
to focus it, or dismiss without navigation. There is no script waiting for a
returned ID. It lists real tabs rather than a hard-coded mock project list.

For an extension-owned collection, cmux has `contributes.paletteScopes` with a
snapshot/query export and typed ActionRefs. The worked implementation is
`samples/apps/palette-notes/`. Its runtime bounds differ: **10,000 snapshot
items; 200 per query batch; 1,000 live query rows; 2,048 bytes per item; 65,536
bytes per detail** (`cmux-app-host/js/src/palette.ts`). Those are engine bounds,
not a claim that this example supplies a generic pick API. Source ordering,
multi-select, `allow_other`, a waiting caller and source timeout/error behavior
are not implemented by this profile.
