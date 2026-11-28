//! The three-tree rule for two-way file sync between two replicas (a Mac and a VM, or a laptop and a
//! personal box): **local**, **remote**, and **synced**, the revision both sides last agreed on.
//! Every decision is made from those three, never from timestamps or from which side spoke last, so
//! the same edits reach the same result in either order (cmuxterm-hq RFD 0140 section 5, RFD 0155
//! goal 5; the check a file-sync service runs over its three trees).
//!
//! | Local vs synced | Remote vs synced | Result |
//! | --- | --- | --- |
//! | same | same | nothing |
//! | changed | same | push to remote |
//! | same | changed | apply on local |
//! | changed | changed, same content | record as synced |
//! | changed | changed, different content | conflict: text merges three-way, else a conflict file |
//! | deleted | changed | conflict, not a delete |
//! | changed | deleted | conflict, not a delete |
//! | deleted | deleted | record as synced |
//!
//! "Changed" includes created (absent in synced, present on the side) and "deleted" is present in
//! synced and absent on the side. A file's state is its content hash, or `None` when absent. The
//! module is pure: the caller hashes files, moves bytes, and writes the new synced revision.

use std::collections::{BTreeMap, BTreeSet};

/// What to do with one path.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Decision<H> {
    /// Both sides still match synced.
    Nothing,
    /// Local changed alone: write `Some(hash)` to remote, or delete it there when `None`.
    Push(Option<H>),
    /// Remote changed alone: write `Some(hash)` locally, or delete it locally when `None`.
    Apply(Option<H>),
    /// Both sides reached the same state on their own: only synced moves.
    RecordSynced(Option<H>),
    /// Both sides changed it differently. Synced stays where it was until the conflict resolves.
    Conflict(Conflict<H>),
}

/// The kinds of conflict. A delete never wins against an edit: the edit survives and the delete
/// is reported, so no one loses work because another device cleaned up.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Conflict<H> {
    /// Both sides wrote different content (including both creating the same path).
    Content { local: H, remote: H },
    /// Local deleted, remote edited: keep the remote edit on both sides.
    LocalDeleted { remote: H },
    /// Remote deleted, local edited: keep the local edit on both sides.
    RemoteDeleted { local: H },
}

/// How a conflict is settled once the caller knows whether the file is text.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Resolution<H> {
    /// Merge local and remote against synced (`base`, `None` when both created it); if the merge
    /// itself conflicts, fall back to [`Resolution::ConflictFile`].
    ThreeWay { base: Option<H>, local: H, remote: H },
    /// Remote's content stays at the path on both sides; local's is kept beside it as
    /// `NAME.cmux-sync-conflict` (RFD 0007's name), on both sides.
    ConflictFile { keep: H, aside: H },
    /// The edited side's content is restored on the side that deleted it.
    KeepEdit(H),
}

/// The decision for one path from its three states.
pub fn decide<H: Clone + Eq>(
    synced: Option<&H>,
    local: Option<&H>,
    remote: Option<&H>,
) -> Decision<H> {
    let local_changed = local != synced;
    let remote_changed = remote != synced;
    match (local_changed, remote_changed) {
        (false, false) => Decision::Nothing,
        (true, false) => Decision::Push(local.cloned()),
        (false, true) => Decision::Apply(remote.cloned()),
        (true, true) => match (local, remote) {
            (Some(l), Some(r)) if l != r => {
                Decision::Conflict(Conflict::Content { local: l.clone(), remote: r.clone() })
            }
            (None, Some(r)) => Decision::Conflict(Conflict::LocalDeleted { remote: r.clone() }),
            (Some(l), None) => Decision::Conflict(Conflict::RemoteDeleted { local: l.clone() }),
            // Both sides made the same change (the same content, or both deleted it).
            (l, _) => Decision::RecordSynced(l.cloned()),
        },
    }
}

/// Settles a conflict: three-way for text, a conflict file otherwise; an edit always beats a delete.
pub fn resolve<H: Clone>(
    synced: Option<&H>,
    conflict: &Conflict<H>,
    is_text: bool,
) -> Resolution<H> {
    match conflict {
        Conflict::Content { local, remote } if is_text => Resolution::ThreeWay {
            base: synced.cloned(),
            local: local.clone(),
            remote: remote.clone(),
        },
        Conflict::Content { local, remote } => {
            Resolution::ConflictFile { keep: remote.clone(), aside: local.clone() }
        }
        Conflict::LocalDeleted { remote } => Resolution::KeepEdit(remote.clone()),
        Conflict::RemoteDeleted { local } => Resolution::KeepEdit(local.clone()),
    }
}

/// The decision for every path in any of the three trees, in path order. Paths that need nothing
/// are left out.
pub fn decide_tree<P: Ord + Clone, H: Clone + Eq>(
    synced: &BTreeMap<P, H>,
    local: &BTreeMap<P, H>,
    remote: &BTreeMap<P, H>,
) -> BTreeMap<P, Decision<H>> {
    let paths: BTreeSet<&P> = synced.keys().chain(local.keys()).chain(remote.keys()).collect();
    paths
        .into_iter()
        .filter_map(|p| {
            let d = decide(synced.get(p), local.get(p), remote.get(p));
            (d != Decision::Nothing).then(|| (p.clone(), d))
        })
        .collect()
}

impl<H: Clone> Decision<H> {
    /// The same decision seen from the other side (local and remote swapped), so a VM and a Mac
    /// running the rule on the same three trees agree on who does what.
    pub fn mirrored(&self) -> Decision<H> {
        match self {
            Decision::Nothing => Decision::Nothing,
            Decision::Push(h) => Decision::Apply(h.clone()),
            Decision::Apply(h) => Decision::Push(h.clone()),
            Decision::RecordSynced(h) => Decision::RecordSynced(h.clone()),
            Decision::Conflict(c) => Decision::Conflict(match c {
                Conflict::Content { local, remote } => {
                    Conflict::Content { local: remote.clone(), remote: local.clone() }
                }
                Conflict::LocalDeleted { remote } => {
                    Conflict::RemoteDeleted { local: remote.clone() }
                }
                Conflict::RemoteDeleted { local } => {
                    Conflict::LocalDeleted { remote: local.clone() }
                }
            }),
        }
    }
}

#[cfg(test)]
#[path = "three_tree_tests.rs"]
mod tests;
