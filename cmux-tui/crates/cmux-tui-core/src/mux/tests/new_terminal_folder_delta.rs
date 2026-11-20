//! A new terminal's first record names its folder (RESIZE VIDEOS T1).
//!
//! A split, New Column, New Row and New Tab send the folder the terminal
//! opens in, and the app's stand-in tab shows it as its title from the key's
//! frame. The daemon's `pane-added` / `tab-added` record replaces the
//! stand-in under the same tab id. That record read the tree decorations
//! before the new surface had a pane, and the directory scan keeps only
//! surfaces with a pane, so the record had no `cwd`: the title fell back to
//! "Terminal" until the next `tab-changed` brought the folder back, and the
//! strip drew "/tmp" -> "Terminal" -> "/tmp" with a rename crossfade each
//! time (4 of 4 films on feat e34fecc1312).

use super::*;

/// A create that returns the new terminal's surface.
type Create<'a> = Box<dyn Fn() -> Arc<Surface> + 'a>;

/// A folder that exists on every test host, as the daemon presents it.
fn folder() -> String {
    std::env::temp_dir().canonicalize().unwrap().to_string_lossy().into_owned()
}

/// The `cwd` of the first tab in a `pane-added` entity, or of a `tab-added` entity.
fn entity_cwd(delta: &TreeDelta) -> Option<String> {
    let tab = match delta.kind {
        TreeDeltaKind::PaneAdded => delta.entity.get("tabs")?.as_array()?.first()?,
        _ => &delta.entity,
    };
    tab.get("cwd")?.as_str().map(str::to_owned)
}

/// The first `kind` delta about `id` (the pane for `pane-added`, the surface
/// for `tab-added`) among the events already sent: the create returned after
/// it emitted them, so nothing waits.
fn added_delta(events: &MuxEventReceiver, kind: TreeDeltaKind, id: u64) -> TreeDelta {
    events
        .try_iter()
        .find_map(|event| match event {
            MuxEvent::TreeDelta(delta)
                if delta.kind == kind
                    && match kind {
                        TreeDeltaKind::PaneAdded => delta.pane == Some(id),
                        _ => delta.surface == Some(id),
                    } =>
            {
                Some(delta)
            }
            _ => None,
        })
        .unwrap_or_else(|| panic!("no {kind:?} delta for {id}"))
}

#[test]
fn a_split_new_column_and_new_row_pane_added_names_the_new_terminal_folder() {
    let mux = test_mux();
    let first = mux.new_workspace(None, None).unwrap();
    let target = mux.with_state(|state| state.pane_of(first.id).unwrap());
    let folder = folder();
    let spawn = || TerminalSpawnOptions::new(Some(folder.clone()), Vec::new());

    let creates: [(&str, Create<'_>); 3] = [
        (
            "split",
            Box::new(|| mux.split_with_options(target, SplitDir::Right, spawn(), None).unwrap()),
        ),
        (
            "new column",
            Box::new(|| {
                mux.new_column_with_options_as(&Actor::Daemon, target, 0.4, false, spawn(), None)
                    .unwrap()
                    .surface
            }),
        ),
        (
            "new row",
            Box::new(|| mux.new_row_with_options(target, 300, spawn(), None, None).unwrap()),
        ),
    ];
    for (name, create) in creates {
        let events = mux.subscribe();
        let surface = create();
        let pane = mux.with_state(|state| state.pane_of(surface.id).unwrap());
        let delta = added_delta(&events, TreeDeltaKind::PaneAdded, pane);
        assert_eq!(
            entity_cwd(&delta).as_deref(),
            Some(folder.as_str()),
            "{name}: the pane-added record has no folder, so the new tab's title reads \"Terminal\" until the next tab-changed"
        );
    }
}

#[test]
fn a_new_tab_tab_added_names_the_new_terminal_folder() {
    let mux = test_mux();
    let first = mux.new_workspace(None, None).unwrap();
    let pane = mux.with_state(|state| state.pane_of(first.id).unwrap());
    let folder = folder();
    let events = mux.subscribe();

    let surface = mux
        .new_tab_with_options(
            Some(pane),
            TerminalSpawnOptions::new(Some(folder.clone()), Vec::new()),
            None,
        )
        .unwrap();

    let delta = added_delta(&events, TreeDeltaKind::TabAdded, surface.id);
    assert_eq!(
        entity_cwd(&delta).as_deref(),
        Some(folder.as_str()),
        "the tab-added record has no folder, so the new tab's title reads \"Terminal\" until the next tab-changed"
    );
}
