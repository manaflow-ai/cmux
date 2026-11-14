use std::time::{Duration, Instant};

use serde_json::{Value, json};

use super::plan::{Planned, SeedParams};
use super::{
    Command, Ended, LocalBundle, Record, SeedError, asks_head_first, barrier_marker, barrier_ready,
    parse, pull, seed_job, seed_record, seeded, settle_fill,
};

/// The ops a scripted machine was asked, in order.
type Asked = std::rc::Rc<std::cell::RefCell<Vec<String>>>;

/// A machine that answers each op from `answers` in turn, keeping the ops it was asked.
fn machine(
    answers: Vec<Result<Value, &'static str>>,
) -> (impl FnMut(&str, Value) -> Result<Value, SeedError>, Asked) {
    let asked = std::rc::Rc::new(std::cell::RefCell::new(Vec::new()));
    let seen = asked.clone();
    let mut answers = answers.into_iter();
    let call = move |op: &str, _: Value| {
        seen.borrow_mut().push(op.to_owned());
        answers
            .next()
            .unwrap_or_else(|| panic!("asked {op} past the script"))
            .map_err(|code| SeedError::new(code, "refused"))
    };
    (call, asked)
}

fn later() -> Instant {
    Instant::now() + Duration::from_secs(600)
}

fn planned() -> Planned {
    let sha = "a".repeat(40);
    Planned {
        params: SeedParams {
            url: "https://github.com/o/n.git".into(),
            repo: "o/n".into(),
            base: sha.clone(),
            head_ref: Some("refs/heads/main".into()),
            head: sha.clone(),
            index: sha.clone(),
            work: "w".repeat(40),
            stash: None,
            sparse: None,
            lfs: false,
            since: None,
        },
        skipped: Vec::new(),
        submodules: Vec::new(),
        bases: vec![sha],
        bundle_bytes: 10,
        unchanged: false,
    }
}

#[test]
fn a_head_first_seed_answers_at_head_ready_with_filling() {
    let (mut call, asked) = machine(vec![
        Ok(json!({"job": "j"})),
        Ok(json!({"state": "running", "phase": "clone"})),
        Ok(json!({"state": "running", "phase": "checkout", "head_ready": true})),
    ]);
    let mut pauses = 0;
    let ended = seed_job(&mut call, &mut || pauses += 1, json!({}), true, later()).unwrap();
    assert!(matches!(&ended, Ended::HeadReady { job } if job == "j"), "{ended:?}");
    assert_eq!(*asked.borrow(), ["git.seed.start", "git.seed.status", "git.seed.status"]);
    assert_eq!(pauses, 1);
    let line = seeded("seed", &planned(), &ended).json();
    assert_eq!((line["ok"].clone(), line["mode"].clone()), (json!(true), json!("seed")));
    assert_eq!(line["filling"], json!(true), "{line}");
}

#[test]
fn a_status_without_head_ready_is_waited_for_until_done() {
    // An older machine never says head_ready: the push waits for done as before.
    let (mut call, asked) = machine(vec![
        Ok(json!({"job": "j"})),
        Ok(json!({"state": "running"})),
        Ok(json!({"state": "running"})),
        Ok(json!({"state": "done", "head": "h"})),
    ]);
    let ended = seed_job(&mut call, &mut || {}, json!({}), true, later()).unwrap();
    assert!(matches!(&ended, Ended::Done(status) if status["head"] == "h"), "{ended:?}");
    assert_eq!(asked.borrow().len(), 4);
    let line = seeded("seed", &planned(), &ended).json();
    assert_eq!(line["head"], json!("h"));
    assert!(line.get("filling").is_none(), "{line}");
    // A seed that did not ask for its head (a delta, a clone) waits for done even when
    // the machine marks one.
    let (mut call, _) = machine(vec![
        Ok(json!({"job": "j"})),
        Ok(json!({"state": "running", "head_ready": true})),
        Ok(json!({"state": "done"})),
    ]);
    let ended = seed_job(&mut call, &mut || {}, json!({}), false, later()).unwrap();
    assert!(matches!(ended, Ended::Done(_)));
}

#[test]
fn only_a_whole_seed_without_sparse_patterns_asks_for_its_head() {
    let whole = planned().params;
    assert!(asks_head_first(&whole));
    assert!(!asks_head_first(&SeedParams { since: Some("w".into()), ..whole.clone() }));
    assert!(!asks_head_first(&SeedParams { sparse: Some("/a\n".into()), ..whole.clone() }));
    assert!(!asks_head_first(&SeedParams { lfs: true, ..whole }), "LFS lands after the head");
}

#[test]
fn the_record_kept_at_head_ready_is_not_a_finished_seed() {
    let at_head = Ended::HeadReady { job: "j".into() };
    let record = seed_record(Some("m".into()), &planned(), at_head.filling());
    assert_eq!(record.filling.as_deref(), Some("j"), "a delta must wait for this job");
    let saved: Record = serde_json::from_value(serde_json::to_value(&record).unwrap()).unwrap();
    assert_eq!(saved, record);
    let done = seed_record(Some("m".into()), &planned(), Ended::Done(json!({})).filling());
    assert_eq!(done.filling, None);
    assert!(serde_json::to_value(&done).unwrap().get("filling").is_none());
    // A record from before heads reads as a finished seed.
    let mut older = serde_json::to_value(&done).unwrap();
    older.as_object_mut().unwrap().remove("filling");
    assert_eq!(serde_json::from_value::<Record>(older).unwrap(), done);
}

#[test]
fn a_delta_after_an_unfinished_fill_waits_for_it_before_it_runs() {
    let mut record = seed_record(Some("m".into()), &planned(), Some("j"));
    let (mut call, asked) = machine(vec![
        Ok(json!({"state": "running", "head_ready": true})),
        Ok(json!({"state": "running", "head_ready": true})),
        Ok(json!({"state": "done"})),
    ]);
    let mut pauses = 0;
    let mut no_marker = || -> Result<bool, SeedError> { panic!("a known job is not read") };
    settle_fill(&mut call, &mut || pauses += 1, &mut no_marker, &mut record, later()).unwrap();
    assert_eq!(record.filling, None);
    // Only the fill's status was read: no delta started while it filled.
    assert_eq!(*asked.borrow(), ["git.seed.status"; 3]);
    assert_eq!(pauses, 2);

    // A fill that failed keeps the record unsettled, and the delta does not run.
    let mut whole = || Ok::<_, SeedError>(true);
    let mut record = seed_record(Some("m".into()), &planned(), Some("j"));
    let (mut call, _) = machine(vec![Ok(json!({
        "state": "failed", "error_code": "seed.clone_failed", "error": "no"
    }))]);
    let error = settle_fill(&mut call, &mut || {}, &mut whole, &mut record, later());
    let error = error.unwrap_err();
    assert_eq!(error.code, "seed.clone_failed");
    assert_eq!(record.filling.as_deref(), Some("j"));

    // A job the machine forgot after a finished fill (pruned): the checkout is whole.
    let mut record = seed_record(Some("m".into()), &planned(), Some("j"));
    let (mut call, _) = machine(vec![Err("seed.unknown_job")]);
    settle_fill(&mut call, &mut || {}, &mut whole, &mut record, later()).unwrap();
    assert_eq!(record.filling, None);
}

/// The daemon restarted mid-fill (or past its marker, in its submodules) and nothing
/// changed on this Mac: the unchanged delta would answer without asking the machine,
/// so the machine's barrier decides first.
#[test]
fn a_fill_cut_off_by_a_restart_is_not_settled_even_with_no_new_edits() {
    let mut record = seed_record(Some("m".into()), &planned(), Some("j"));
    let (mut call, _) = machine(vec![Err("seed.unknown_job")]);
    let mut read = 0;
    let mut short = || {
        read += 1;
        Ok::<_, SeedError>(false)
    };
    let error = settle_fill(&mut call, &mut || {}, &mut short, &mut record, later()).unwrap_err();
    assert_eq!(error.code, "seed.filling");
    assert_eq!(read, 1);
    assert_eq!(record.filling.as_deref(), Some("j"), "the next delta checks again");
    // A marker that cannot be read is no proof the tree is whole.
    let (mut call, _) = machine(vec![Err("seed.unknown_job")]);
    let mut unreadable = || Err::<bool, _>(SeedError::new("sync_failed", "no answer"));
    let error =
        settle_fill(&mut call, &mut || {}, &mut unreadable, &mut record, later()).unwrap_err();
    assert_eq!(error.code, "sync_failed");
    assert_eq!(record.filling.as_deref(), Some("j"));
}

/// No fill marker is no proof: the machine removes it before its submodules and LFS,
/// and only the barrier's `1` says the whole checkout is there.
#[test]
fn only_a_ready_barrier_says_a_forgotten_fill_is_whole() {
    assert!(barrier_ready(Some(b"1")));
    for short in [None, Some(&b"0"[..]), Some(b""), Some(b"10"), Some(b"x")] {
        assert!(!barrier_ready(short), "{short:?}");
    }
    // The same name cmux-git gives the barrier of a folder: its name's sha256 beside it.
    let name = "paint-33f597";
    let marker = barrier_marker(&format!("/home/cmux/work/chats/ab/{name}/")).unwrap();
    let (parent, file) = marker.rsplit_once('/').unwrap();
    assert_eq!(parent, "/home/cmux/work/chats/ab");
    let digest = {
        use sha2::Digest as _;
        sha2::Sha256::digest(name.as_bytes())
    };
    assert_eq!(file, format!(".cmux-sync-{digest:x}"));
    assert_eq!(barrier_marker("/"), None);
}

#[test]
fn a_start_refused_while_the_folder_fills_starts_once_the_fill_is_done() {
    let (mut call, asked) = machine(vec![
        Err("seed.filling"),
        Err("seed.filling"),
        Ok(json!({"job": "k"})),
        Ok(json!({"state": "done"})),
    ]);
    let mut pauses = 0;
    let ended = seed_job(&mut call, &mut || pauses += 1, json!({}), false, later()).unwrap();
    assert!(matches!(ended, Ended::Done(_)));
    assert_eq!(asked.borrow()[..3], ["git.seed.start"; 3]);
    assert_eq!(pauses, 2);
    // Past the deadline the refusal is the answer.
    let (mut call, _) = machine(vec![Err("seed.filling")]);
    let past = Instant::now();
    let error = seed_job(&mut call, &mut || {}, json!({}), false, past).unwrap_err();
    assert_eq!(error.code, "seed.filling");
}

#[test]
fn the_bundle_lives_in_a_folder_only_this_user_opens_and_goes_with_it() {
    use std::os::unix::fs::PermissionsExt;
    let bundle = LocalBundle::new().unwrap();
    let folder = bundle.folder.clone();
    assert_eq!(std::fs::metadata(&folder).unwrap().permissions().mode() & 0o777, 0o700);
    assert_eq!(bundle.file.parent(), Some(folder.as_path()));
    std::fs::write(&bundle.file, b"x").unwrap();
    drop(bundle);
    assert!(!folder.exists());
}

fn args(list: &[&str]) -> Vec<String> {
    list.iter().map(|arg| (*arg).to_string()).collect()
}

const SHA: &str = "0123456789abcdef0123456789abcdef01234567";

#[test]
fn parses_pull_with_its_base_from_the_record_or_all_three_flags() {
    let Some(Command::Pull { local, remote, base, .. }) =
        parse(&args(&["pull", "--socket", "/s", "/a", "/home/w/a/"]))
    else {
        panic!("pull");
    };
    assert_eq!((local.to_str(), remote.as_str()), (Some("/a"), "/home/w/a"));
    assert!(matches!(base, pull::Base::Record), "the record's");
    let Some(Command::Pull { base: pull::Base::RecordOrCopy, .. }) =
        parse(&args(&["pull", "--socket", "/s", "/a", "/b", "--or-copy"]))
    else {
        panic!("Bring Back Local's pull");
    };
    let Some(Command::Pull { base: pull::Base::Given(base), .. }) = parse(&args(&[
        "pull",
        "--socket",
        "/s",
        "/a",
        "/b",
        "--base-head",
        SHA,
        "--base-index",
        SHA,
        "--base-work",
        SHA,
    ])) else {
        panic!("pull with a base");
    };
    assert_eq!(base.work, SHA);
}

#[test]
fn parses_push_and_clone() {
    let Some(Command::Push { local, remote, since_last, .. }) =
        parse(&args(&["push", "--socket", "/s", "/a", "/home/w/a/", "--since-last"]))
    else {
        panic!("push");
    };
    assert_eq!(local.to_str(), Some("/a"));
    assert_eq!(remote, "/home/w/a");
    assert!(since_last);
    let Some(Command::Clone { repo, git_ref, remote, .. }) =
        parse(&args(&["clone", "--socket", "/s", "--repo", "o/n", "--ref", "v1", "/home/w/n"]))
    else {
        panic!("clone");
    };
    assert_eq!(
        (repo.as_str(), git_ref.as_deref(), remote.as_str()),
        ("o/n", Some("v1"), "/home/w/n")
    );
    for bad in [
        &["push", "--socket", "/s", "/a"][..],
        &["push", "/a", "/home/w/a"],
        &["push", "--socket", "/s", "/a", "relative"],
        &["push", "--socket", "/s", "/a", "/"],
        &["push", "--socket", "/s", "--repo", "o/n", "/a", "/b"],
        &["clone", "--socket", "/s", "--repo", "o", "/b"],
        &["clone", "--socket", "/s", "--repo", "o/n", "/b", "--since-last"],
        &["clone", "--socket", "/s", "/b"],
        &["plan", "--socket", "/s", "/a", "/b"],
        &["push", "--socket", "/s", "/a", "/b", "--x"],
        &[
            "push",
            "--socket",
            "/s",
            "/a",
            "/b",
            "--base-head",
            SHA,
            "--base-index",
            SHA,
            "--base-work",
            SHA,
        ],
        &["pull", "--socket", "/s", "/a"],
        &["pull", "/a", "/b"],
        &["pull", "--socket", "/s", "/a", "b"],
        &["pull", "--socket", "/s", "/a", "/b", "--since-last"],
        &["pull", "--socket", "/s", "/a", "/b", "--base-head", SHA],
        &["push", "--socket", "/s", "/a", "/b", "--or-copy"],
        &[
            "pull",
            "--socket",
            "/s",
            "/a",
            "/b",
            "--or-copy",
            "--base-head",
            SHA,
            "--base-index",
            SHA,
            "--base-work",
            SHA,
        ],
        &[
            "pull",
            "--socket",
            "/s",
            "/a",
            "/b",
            "--base-head",
            "HEAD",
            "--base-index",
            SHA,
            "--base-work",
            SHA,
        ],
    ] {
        assert!(parse(&args(bad)).is_none(), "{bad:?}");
    }
}
