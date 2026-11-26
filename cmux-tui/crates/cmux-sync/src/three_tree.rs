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
mod tests {
    use super::*;

    type S = Option<u8>;

    /// Every combination of three states over a small alphabet (absent, A, B, C): 64 cases, which
    /// covers every row of the table, created and deleted included.
    fn all() -> Vec<(S, S, S)> {
        let v = [None, Some(1), Some(2), Some(3)];
        let mut out = vec![];
        for s in v {
            for l in v {
                for r in v {
                    out.push((s, l, r));
                }
            }
        }
        out
    }

    fn d(s: S, l: S, r: S) -> Decision<u8> {
        decide(s.as_ref(), l.as_ref(), r.as_ref())
    }

    #[test]
    fn each_row_of_the_table() {
        let a = Some(1);
        let b = Some(2);
        let c = Some(3);
        assert_eq!(d(a, a, a), Decision::Nothing, "same, same");
        assert_eq!(d(a, b, a), Decision::Push(b), "changed, same");
        assert_eq!(d(a, a, b), Decision::Apply(b), "same, changed");
        assert_eq!(d(a, b, b), Decision::RecordSynced(b), "both changed alike");
        assert_eq!(
            d(a, b, c),
            Decision::Conflict(Conflict::Content { local: 2, remote: 3 }),
            "both changed, different"
        );
        assert_eq!(
            d(a, None, b),
            Decision::Conflict(Conflict::LocalDeleted { remote: 2 }),
            "deleted vs changed"
        );
        assert_eq!(
            d(a, b, None),
            Decision::Conflict(Conflict::RemoteDeleted { local: 2 }),
            "changed vs deleted"
        );
        assert_eq!(d(a, None, None), Decision::RecordSynced(None), "deleted, deleted");
        // Created and deleted alone.
        assert_eq!(d(None, a, None), Decision::Push(a));
        assert_eq!(d(None, None, a), Decision::Apply(a));
        assert_eq!(d(a, None, a), Decision::Push(None));
        assert_eq!(d(a, a, None), Decision::Apply(None));
        assert_eq!(d(None, a, a), Decision::RecordSynced(a));
        assert_eq!(d(None, a, b), Decision::Conflict(Conflict::Content { local: 1, remote: 2 }));
    }

    /// Both orders of events: running the rule from the other side gives the mirrored decision, so
    /// the two replicas never disagree on who pushes and who applies.
    #[test]
    fn both_sides_agree_for_every_case() {
        for (s, l, r) in all() {
            assert_eq!(d(s, r, l), d(s, l, r).mirrored(), "synced {s:?} local {l:?} remote {r:?}");
        }
    }

    /// Carrying out every non-conflict decision leaves both sides equal to the new synced state,
    /// whichever side applies first; a conflict never moves synced and never deletes an edit.
    #[test]
    fn every_case_converges_or_keeps_the_edit() {
        for (s, l, r) in all() {
            match d(s, l, r) {
                Decision::Nothing => assert!(l == s && r == s),
                Decision::Push(h) => assert_eq!((h, r), (l, s)),
                Decision::Apply(h) => assert_eq!((h, l), (r, s)),
                Decision::RecordSynced(h) => assert!(h == l && h == r),
                Decision::Conflict(c) => {
                    assert!(l != r && l != s && r != s, "{s:?} {l:?} {r:?}");
                    match resolve(s.as_ref(), &c, false) {
                        Resolution::ConflictFile { keep, aside } => {
                            assert_eq!((Some(aside), Some(keep)), (l, r));
                        }
                        Resolution::KeepEdit(h) => assert!(Some(h) == l || Some(h) == r),
                        Resolution::ThreeWay { .. } => panic!("binary never merges"),
                    }
                }
            }
        }
    }

    #[test]
    fn text_merges_three_way_against_synced() {
        let c = Conflict::Content { local: 2u8, remote: 3 };
        assert_eq!(
            resolve(Some(&1), &c, true),
            Resolution::ThreeWay { base: Some(1), local: 2, remote: 3 }
        );
        assert_eq!(
            resolve(None, &c, true),
            Resolution::ThreeWay { base: None, local: 2, remote: 3 }
        );
        // A delete against an edit keeps the edit even for text.
        assert_eq!(
            resolve(Some(&1), &Conflict::LocalDeleted { remote: 3u8 }, true),
            Resolution::KeepEdit(3)
        );
    }

    #[test]
    fn a_tree_reports_only_paths_that_need_work() {
        let synced = BTreeMap::from([("a", 1u8), ("b", 1), ("c", 1)]);
        let local = BTreeMap::from([("a", 1u8), ("b", 2), ("d", 4)]);
        let remote = BTreeMap::from([("a", 1u8), ("b", 1), ("c", 1)]);
        let out = decide_tree(&synced, &local, &remote);
        assert_eq!(
            out,
            BTreeMap::from([
                ("b", Decision::Push(Some(2))),
                ("c", Decision::Push(None)),
                ("d", Decision::Push(Some(4)))
            ])
        );
    }
}
