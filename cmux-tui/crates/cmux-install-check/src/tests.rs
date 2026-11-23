//! The decision over every combination of its inputs.

use super::*;

const RUNNING: &str = "200";

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum CanaryCase {
    Passed,
    Refused,
    Inconclusive,
}

/// Whether the running build is already in the record.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Recorded {
    No,
    Passed,
    Refused,
}

/// One kept build's state, as the decision sees it.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum KeptCase {
    /// No result recorded for it.
    Unchecked,
    /// Recorded refused.
    Refused,
    /// Recorded passed but pinned.
    PassedPinned,
    /// Recorded passed and reads the stores.
    PassedReads,
    /// Recorded passed, cannot read the stores.
    PassedUnreadable,
    /// The running build itself, kept and recorded passed (it must never be a target).
    Running,
}

const CANARIES: [CanaryCase; 3] =
    [CanaryCase::Passed, CanaryCase::Refused, CanaryCase::Inconclusive];
const RECORDED: [Recorded; 3] = [Recorded::No, Recorded::Passed, Recorded::Refused];
const KEPT: [KeptCase; 6] = [
    KeptCase::Unchecked,
    KeptCase::Refused,
    KeptCase::PassedPinned,
    KeptCase::PassedReads,
    KeptCase::PassedUnreadable,
    KeptCase::Running,
];

fn input(nightly: bool, canary: CanaryCase, recorded: Recorded, kept: &[KeptCase]) -> Input {
    let mut history = Vec::new();
    let mut pinned = Vec::new();
    let mut kept_builds = Vec::new();
    match recorded {
        Recorded::No => {}
        Recorded::Passed => history.push(Entry { build: RUNNING.into(), result: Outcome::Passed }),
        Recorded::Refused => {
            history.push(Entry { build: RUNNING.into(), result: Outcome::Refused });
        }
    }
    for (index, case) in kept.iter().enumerate() {
        // Newest first: 199, 198, ...
        let build = if *case == KeptCase::Running {
            RUNNING.to_string()
        } else {
            (199 - index).to_string()
        };
        let reads_store = !matches!(case, KeptCase::PassedUnreadable);
        match case {
            KeptCase::Unchecked => {}
            KeptCase::Refused => {
                history.push(Entry { build: build.clone(), result: Outcome::Refused });
            }
            KeptCase::PassedPinned => {
                history.push(Entry { build: build.clone(), result: Outcome::Passed });
                pinned.push(build.clone());
            }
            KeptCase::PassedReads | KeptCase::PassedUnreadable => {
                history.push(Entry { build: build.clone(), result: Outcome::Passed });
            }
            KeptCase::Running => {}
        }
        kept_builds.push(Kept { build, reads_store });
    }
    let canary = match canary {
        CanaryCase::Passed => Canary::Passed,
        CanaryCase::Refused => Canary::Refused { reason: "transport.intent_invalid".into() },
        CanaryCase::Inconclusive => Canary::Inconclusive,
    };
    Input { nightly, build: RUNNING.into(), canary, history, pinned, kept: kept_builds }
}

/// The expected decision, written as the rules read, independent of `decide`.
fn expected(nightly: bool, canary: CanaryCase, recorded: Recorded, kept: &[KeptCase]) -> Decision {
    let keep = Decision { action: Action::Keep, record: None, pin: None, notice: None };
    if !nightly || recorded != Recorded::No {
        return keep;
    }
    match canary {
        CanaryCase::Inconclusive => keep,
        CanaryCase::Passed => Decision {
            record: Some(Entry { build: RUNNING.into(), result: Outcome::Passed }),
            ..keep
        },
        CanaryCase::Refused => {
            let target = kept
                .iter()
                .enumerate()
                .find(|(_, case)| **case == KeptCase::PassedReads)
                .map(|(index, _)| (199 - index).to_string());
            let unreadable = kept.contains(&KeptCase::PassedUnreadable);
            let (action, why) = match (&target, unreadable) {
                (Some(to), _) => (Action::RollBack { to: to.clone() }, None),
                (None, true) => {
                    (Action::Report { why: Why::StoreUnreadable }, Some(Why::StoreUnreadable))
                }
                (None, false) => {
                    (Action::Report { why: Why::NoPassingBuild }, Some(Why::NoPassingBuild))
                }
            };
            Decision {
                action,
                record: Some(Entry { build: RUNNING.into(), result: Outcome::Refused }),
                pin: Some(RUNNING.into()),
                notice: Some(Notice {
                    build: RUNNING.into(),
                    target,
                    why,
                    reason: "transport.intent_invalid".into(),
                }),
            }
        }
    }
}

/// Every kept list of length 0, 1 and 2 over every kept state.
fn kept_lists() -> Vec<Vec<KeptCase>> {
    let mut lists = vec![Vec::new()];
    for first in KEPT {
        lists.push(vec![first]);
        for second in KEPT {
            lists.push(vec![first, second]);
        }
    }
    lists
}

#[test]
fn every_combination() {
    let mut checked = 0;
    for nightly in [true, false] {
        for canary in CANARIES {
            for recorded in RECORDED {
                for kept in kept_lists() {
                    let got = decide(&input(nightly, canary, recorded, &kept));
                    let want = expected(nightly, canary, recorded, &kept);
                    assert_eq!(
                        got, want,
                        "nightly={nightly} canary={canary:?} recorded={recorded:?} kept={kept:?}"
                    );
                    checked += 1;
                }
            }
        }
    }
    // 2 channels x 3 canaries x 3 records x (1 + 6 + 36) kept lists.
    assert_eq!(checked, 2 * 3 * 3 * 43);
}

/// The incident: a refused NIGHTLY with the build before it recorded passing
/// rolls back to it, pins itself, and says why.
#[test]
fn refused_rolls_back_to_last_passing() {
    let decision =
        decide(&input(true, CanaryCase::Refused, Recorded::No, &[KeptCase::PassedReads]));
    assert_eq!(decision.action, Action::RollBack { to: "199".into() });
    assert_eq!(decision.pin.as_deref(), Some(RUNNING));
    assert_eq!(decision.notice.unwrap().reason, "transport.intent_invalid");
}

/// A newer passing build that cannot read the stores is passed over for an
/// older one that can.
#[test]
fn skips_unreadable_for_older_readable() {
    let decision = decide(&input(
        true,
        CanaryCase::Refused,
        Recorded::No,
        &[KeptCase::PassedUnreadable, KeptCase::PassedReads],
    ));
    assert_eq!(decision.action, Action::RollBack { to: "198".into() });
}

#[test]
fn record_apply_and_round_trip() {
    let directory = std::env::temp_dir().join(format!("cmux-install-check-{}", std::process::id()));
    let path = directory.join("install-check.json");
    let _ = std::fs::remove_file(&path);
    assert_eq!(Record::load(&path).unwrap(), Record::default());
    let mut record = Record::default();
    let decision = decide(&input(true, CanaryCase::Refused, Recorded::No, &[]));
    record.apply(&decision);
    record.apply(&decision);
    assert_eq!(record.history, vec![Entry { build: RUNNING.into(), result: Outcome::Refused }]);
    assert_eq!(record.pinned, vec![RUNNING.to_string()]);
    record.save(&path).unwrap();
    assert_eq!(Record::load(&path).unwrap(), record);
    std::fs::remove_dir_all(&directory).unwrap();
}

#[test]
fn history_is_bounded() {
    let mut record = Record::default();
    for build in 0..(HISTORY_LIMIT + 10) {
        record.apply(&Decision {
            action: Action::Keep,
            record: Some(Entry { build: build.to_string(), result: Outcome::Passed }),
            pin: Some(build.to_string()),
            notice: None,
        });
    }
    assert_eq!(record.history.len(), HISTORY_LIMIT);
    assert_eq!(record.pinned.len(), HISTORY_LIMIT);
    assert_eq!(record.history.last().unwrap().build, (HISTORY_LIMIT + 9).to_string());
}

#[test]
fn cli_due_then_decide() {
    let directory =
        std::env::temp_dir().join(format!("cmux-install-check-cli-{}", std::process::id()));
    let path = directory.join("install-check.json");
    let record = path.display().to_string();
    let args = |words: &[&str]| words.iter().map(|word| word.to_string()).collect::<Vec<_>>();
    let due_args = args(&["due", "--record", &record, "--build", "7", "--nightly"]);
    assert_eq!(run(&due_args, "").unwrap(), r#"{"due":true}"#);
    assert_eq!(
        run(&args(&["due", "--record", &record, "--build", "7"]), "").unwrap(),
        r#"{"due":false}"#
    );

    let request = r#"{"nightly":true,"build":"7","canary":{"result":"passed"},"kept":[]}"#;
    let decision: Decision =
        serde_json::from_str(&run(&args(&["decide", "--record", &record]), request).unwrap())
            .unwrap();
    assert_eq!(decision.record, Some(Entry { build: "7".into(), result: Outcome::Passed }));
    assert_eq!(run(&due_args, "").unwrap(), r#"{"due":false}"#);

    let request = r#"{"nightly":true,"build":"8","canary":{"result":"refused","reason":"no"},"kept":[{"build":"7","readsStore":true}]}"#;
    let output = run(&args(&["decide", "--record", &record]), request).unwrap();
    assert!(output.contains(r#""action":{"kind":"rollBack","to":"7"}"#), "{output}");
    assert!(output.contains(r#""notice":{"build":"8","target":"7","reason":"no"}"#), "{output}");
    assert_eq!(Record::load(&path).unwrap().pinned, vec!["8".to_string()]);

    assert!(run(&args(&["decide"]), request).is_err());
    assert!(run(&args(&["other", "--record", &record]), "").is_err());
    std::fs::remove_dir_all(&directory).unwrap();
}
