use super::*;

fn dir(tag: &str) -> std::path::PathBuf {
    let dir =
        std::env::temp_dir().join(format!("cmux-rd-join-consent-{tag}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    identity::private_dir(&dir).unwrap();
    dir
}

fn args(extra: &[&str]) -> Args {
    let words: Vec<String> =
        ["enable", "--non-interactive"].iter().chain(extra).map(|w| (*w).to_owned()).collect();
    Args::parse(&words).unwrap()
}

fn mark(machine_id: &str) -> machine::Joined {
    machine::Joined {
        acpmux_home: "/acpmux-home".into(),
        machine_id: machine_id.into(),
        credential_generation: 1,
        consent_tracked: false,
    }
}

/// joined.json as this build's sign-in for `machine_id` writes it.
fn signed_in(machine_id: &str) -> machine::Joined {
    machine::Joined { consent_tracked: true, ..mark(machine_id) }
}

/// joined.json as a build from before consent-join.json wrote it for `machine_id` (empty:
/// from before joins were marked).
fn from_before(machine_id: &str) -> machine::Joined {
    machine::Joined { consent_tracked: false, ..mark(machine_id) }
}

/// `dir` as a run for the join m-a left it once it finished: signed in, and its consent
/// written (`consent`, or deleted afterwards by its person when None).
fn finished(tag: &str, consent: Option<LocalConsent>) -> std::path::PathBuf {
    let d = dir(tag);
    let mut asked = |_| {};
    join_consent(&d, Some(&mark("m-a")), &args(&[]), &mut asked).unwrap().unwrap();
    signed_in("m-a").save(&d).unwrap();
    match consent {
        Some(consent) => consent.save(&d).unwrap(),
        None => std::fs::remove_file(d.join("consent.json")).unwrap(),
    }
    d
}

/// Runs the enable's consent steps for `join` in `d`, as `set_up_for_join` does with
/// joined.json as it finds it: the consent left, and each grant asked.
fn rerun(d: &std::path::Path, join: &str, extra: &[&str]) -> (Res<LocalConsent>, Vec<bool>) {
    let mut grants = Vec::new();
    let before = machine::Joined::load(d).unwrap();
    mark_join_from_before_marker(d, before.as_ref(), Some(&mark(join))).unwrap();
    let got = join_consent(d, Some(&mark(join)), &args(extra), &mut |c| grants.push(c));
    (got.unwrap(), grants)
}

/// Review F1 of #45480: replacing cmux-rd reruns the enable for the same join, and its
/// person's view-only choice stays, with no portal dialog.
#[test]
fn a_rerun_for_the_same_join_keeps_view_only() {
    let d = finished("view-only", Some(LocalConsent { view: true, full: false }));
    let (kept, grants) = rerun(&d, "m-a", &[]);
    assert!(!kept.unwrap().full);
    assert!(!LocalConsent::load(&d).unwrap().full, "a view-only desktop stays view-only");
    assert!(grants.is_empty(), "no portal grant is asked again: {grants:?}");
}

/// Review F1 of #45480: a withdrawn grant (consent.json deleted) stays withdrawn when
/// cmux-rd is replaced, and the rerun asks for no portal grant.
#[test]
fn a_rerun_for_the_same_join_keeps_a_withdrawn_grant_withdrawn() {
    let d = finished("withdrawn", None);
    let (kept, grants) = rerun(&d, "m-a", &[]);
    assert!(kept.is_err(), "nothing is shared");
    assert!(LocalConsent::load(&d).is_err(), "no consent.json is written again");
    assert!(grants.is_empty(), "no portal grant is asked: {grants:?}");
}

/// Only a narrower choice is taken on a rerun: --view-only turns control off.
#[test]
fn a_rerun_may_narrow_but_never_widen() {
    let d = finished("narrowed", Some(LocalConsent { view: true, full: true }));
    let (now, grants) = rerun(&d, "m-a", &["--view-only"]);
    assert!(!now.unwrap().full && !LocalConsent::load(&d).unwrap().full);
    assert!(grants.is_empty());
}

/// The architect's case: a first run signed the join in (joined.json written) and stopped
/// before it wrote the consent. The next run writes it and asks for the grant, so the
/// machine is never left joined and silently unshared.
#[test]
fn a_join_whose_first_run_stopped_before_its_consent_writes_it_next_run() {
    let d = dir("stopped-first-run");
    signed_in("m-a").save(&d).unwrap();
    let (now, grants) = rerun(&d, "m-a", &[]);
    assert!(now.unwrap().full);
    assert!(LocalConsent::load(&d).unwrap().full, "the join's consent is written");
    assert_eq!(grants, [true], "the grant is asked once, with control");
}

/// A new join is the consent (hq docs/design/remote-screen-share-zero-touch.md, L3): it
/// writes its own, whatever an earlier join or its person left, and asks for the grant.
#[test]
fn a_new_join_writes_its_own_consent() {
    let d = finished("new-join", Some(LocalConsent { view: true, full: false }));
    signed_in("m-b").save(&d).unwrap();
    let (now, grants) = rerun(&d, "m-b", &[]);
    assert!(now.unwrap().full && LocalConsent::load(&d).unwrap().full);
    assert_eq!(grants, [true]);
    let d = finished("new-join-withdrawn", None);
    signed_in("m-b").save(&d).unwrap();
    let (_, grants) = rerun(&d, "m-b", &["--view-only"]);
    assert!(!LocalConsent::load(&d).unwrap().full);
    assert_eq!(grants, [false]);
}

/// Review F1 of #45480, (A): the hub may raise the credential generation of the same
/// machine (recovery.rs). That is no choice made at this screen: view-only and a withdrawn
/// grant stay, and no portal grant is asked.
#[test]
fn a_new_credential_generation_for_the_same_machine_keeps_the_consent() {
    let next = machine::Joined { credential_generation: 2, ..mark("m-a") };
    let d = finished("generation-view-only", Some(LocalConsent { view: true, full: false }));
    let mut grants = Vec::new();
    let kept = join_consent(&d, Some(&next), &args(&[]), &mut |c| grants.push(c)).unwrap();
    assert!(!kept.unwrap().full && !LocalConsent::load(&d).unwrap().full, "view-only stays");
    assert!(grants.is_empty(), "no portal grant is asked: {grants:?}");
    let d = finished("generation-withdrawn", None);
    let kept = join_consent(&d, Some(&next), &args(&[]), &mut |c| grants.push(c)).unwrap();
    assert!(kept.is_err() && LocalConsent::load(&d).is_err(), "a withdrawn grant stays");
    assert!(grants.is_empty(), "no portal grant is asked: {grants:?}");
}

/// Review F1 of #45480, (B): a machine joined before consent-join.json existed has
/// joined.json for this machine and its consent.json, and no marker. Its first run after
/// the update keeps that consent, writes the marker, and asks for no grant.
#[test]
fn a_join_from_before_the_marker_keeps_its_consent() {
    let d = dir("upgraded");
    from_before("m-a").save(&d).unwrap();
    LocalConsent { view: true, full: false }.save(&d).unwrap();
    let (kept, grants) = rerun(&d, "m-a", &[]);
    assert!(!kept.unwrap().full && !LocalConsent::load(&d).unwrap().full, "view-only stays");
    assert!(grants.is_empty(), "no portal grant is asked: {grants:?}");
    assert!(d.join(CONSENT_JOIN_FILE).exists(), "the marker is written");
    let (_, grants) = rerun(&d, "m-a", &[]);
    assert!(grants.is_empty() && !LocalConsent::load(&d).unwrap().full, "and stays kept");
}

/// Review F1 of #45480, upgrade (1): a machine joined before the marker whose person
/// withdrew the grant (no consent.json) stays withdrawn: on that build a stopped enable was
/// retried, so a lasting "joined, no consent" is a withdrawal, not a crash.
#[test]
fn a_join_from_before_the_marker_keeps_a_withdrawn_grant_withdrawn() {
    let d = dir("upgraded-withdrawn");
    from_before("m-a").save(&d).unwrap();
    let (kept, grants) = rerun(&d, "m-a", &[]);
    assert!(kept.is_err() && LocalConsent::load(&d).is_err(), "nothing is shared");
    assert!(grants.is_empty(), "no portal grant is asked: {grants:?}");
}

/// Review F1 of #45480, upgrade (2): an unreadable consent.json shares nothing
/// (shares_line), so the enable never widens it by writing over it.
#[test]
fn a_join_from_before_the_marker_never_rewrites_an_unreadable_consent() {
    let d = dir("upgraded-unreadable");
    from_before("m-a").save(&d).unwrap();
    identity::write_private(&d.join("consent.json"), b"not json").unwrap();
    let (kept, grants) = rerun(&d, "m-a", &[]);
    assert!(kept.is_err(), "nothing is shared");
    assert_eq!(std::fs::read(d.join("consent.json")).unwrap(), b"not json");
    assert!(grants.is_empty(), "no portal grant is asked: {grants:?}");
}

/// Review F1 of #45480, upgrade (3): a record from before joins were marked (no machine
/// id) from this home keeps its view-only consent.
#[test]
fn a_join_from_before_joins_were_marked_keeps_view_only() {
    let d = dir("upgraded-unmarked");
    from_before("").save(&d).unwrap();
    LocalConsent { view: true, full: false }.save(&d).unwrap();
    let (kept, grants) = rerun(&d, "m-a", &[]);
    assert!(!kept.unwrap().full && !LocalConsent::load(&d).unwrap().full, "view-only stays");
    assert!(grants.is_empty(), "no portal grant is asked: {grants:?}");
}

/// Review F1 of #45480: the marker is written before signing in, so an upgraded machine
/// whose run stopped after the marker, even after a sign-in that wrote this build's
/// joined.json, still keeps its (withdrawn) consent.
#[test]
fn an_upgraded_join_stopped_after_its_marker_keeps_its_consent() {
    let d = dir("upgraded-stopped");
    from_before("m-a").save(&d).unwrap();
    mark_join_from_before_marker(&d, Some(&from_before("m-a")), Some(&mark("m-a"))).unwrap();
    signed_in("m-a").save(&d).unwrap();
    let (kept, grants) = rerun(&d, "m-a", &[]);
    assert!(kept.is_err() && LocalConsent::load(&d).is_err(), "still withdrawn");
    assert!(grants.is_empty(), "no portal grant is asked: {grants:?}");
}

/// Signing the same join in again keeps its record's flag: a sign-in (the serving start
/// runs one before any enable) never makes an upgraded join read as a stopped first run.
#[test]
fn signing_the_same_join_in_again_keeps_whether_its_consent_was_tracked() {
    let credential: machine::MachineCredential = serde_json::from_str(
        r#"{"credential":"cmm_a","machine_id":"m-a","credential_generation":2}"#,
    )
    .unwrap();
    let home = std::path::Path::new("/acpmux-home");
    let again = |previous: machine::Joined| {
        machine::Joined::signed_in(Some(&previous), home, &credential).consent_tracked
    };
    assert!(!again(from_before("m-a")), "the same machine, a new generation");
    assert!(!again(from_before("")), "a record from before joins were marked");
    assert!(again(signed_in("m-a")));
    assert!(again(from_before("m-b")), "another machine is a new join");
    assert!(machine::Joined::signed_in(None, home, &credential).consent_tracked);
}
