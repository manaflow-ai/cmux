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
    assert_eq!(resolve(None, &c, true), Resolution::ThreeWay { base: None, local: 2, remote: 3 });
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
