use std::cell::Cell;
use std::fs;
use std::path::{Path, PathBuf};
use std::time::Duration;

use base64::Engine as _;
use serde_json::{Value, json};
use sha2::{Digest as _, Sha256};

use super::copy::{self, Action as CopyAction};
use super::live::{self, Daemon, Phases, Store};
use super::resolve::{self, Spec, Unresolved};
use super::{Command, Live, Plan, choose, parse, try_live, undo_live};

const COMMIT: &str = "0123456789abcdef0123456789abcdef01234567";
const APP_COMMIT: &str = "89abcde";
const APP_FULL_COMMIT: &str = "89abcdef0123456789abcdef0123456789abcdef";

fn words(list: &[&str]) -> Vec<String> {
    list.iter().map(|word| (*word).to_owned()).collect()
}

fn key() -> ring::signature::Ed25519KeyPair {
    ring::signature::Ed25519KeyPair::from_seed_unchecked(&[9u8; 32]).unwrap()
}

fn keys() -> Vec<(String, [u8; 32])> {
    use ring::signature::KeyPair as _;
    let raw: [u8; 32] = key().public_key().as_ref().try_into().unwrap();
    vec![("test".to_owned(), raw)]
}

fn sha(bytes: &[u8]) -> String {
    format!("{:x}", Sha256::digest(bytes))
}

fn binary(name: &str, bytes: &[u8]) -> Value {
    json!({
        "url": format!("https://files.cmux.com/cmux-tui/{COMMIT}/{name}-aarch64-apple-darwin"),
        "sha256": sha(bytes), "size": bytes.len(),
    })
}

fn payload(purpose: &str, commit: &str, targets: Value) -> Value {
    json!({
        "schema": 1, "purpose": purpose, "channel": "nightly-live", "commit": commit,
        "committed_at": 1_000, "published_at": 1_100, "expires_at": 2_000,
        "tree_key": "k", "live_from": [COMMIT, APP_FULL_COMMIT],
        "native_from": [COMMIT, APP_FULL_COMMIT],
        "targets": {"aarch64-apple-darwin": targets},
    })
}

fn envelope(payload: &Value) -> Vec<u8> {
    let b64 = base64::engine::general_purpose::STANDARD;
    let bytes = serde_json::to_vec(payload).unwrap();
    let sig = key().sign(&bytes);
    serde_json::to_vec(&json!({
        "schema": 1, "payload": b64.encode(&bytes),
        "signatures": [{"key_id": "test", "sig": b64.encode(sig.as_ref())}],
    }))
    .unwrap()
}

/// A fixture app (`App.app`, CMUXCommit APP_COMMIT, bin/cmux, bin/cmux-app-host, bin/cmux-tui
/// linked to cmux) and a published commit folder under `files/` with the new binaries.
struct Fixture {
    _dir: tempfile::TempDir,
    app: PathBuf,
    base: String,
    store: Store,
}

const OLD_CMUX: &[u8] = b"old cmux";
const OLD_HOST: &[u8] = b"old app host";
const OLD_HOLDER: &[u8] = b"old holder";
const NEW_CMUX: &[u8] = b"new cmux, a little longer";
const NEW_HOST: &[u8] = b"new app host";

fn fixture() -> Fixture {
    let dir = tempfile::tempdir().unwrap();
    let app = dir.path().join("App.app");
    let bin = app.join(live::BIN);
    fs::create_dir_all(&bin).unwrap();
    fs::write(
        app.join("Contents/Info.plist"),
        format!(
            "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<plist version=\"1.0\"><dict>\
             <key>CFBundleIdentifier</key><string>com.cmuxterm.app.nightly</string>\
             <key>CMUXCommit</key><string>{APP_COMMIT}</string></dict></plist>\n"
        ),
    )
    .unwrap();
    fs::write(bin.join("cmux"), OLD_CMUX).unwrap();
    fs::write(bin.join("cmux-app-host"), OLD_HOST).unwrap();
    // The new build has no holder: the try removes the app's, and undo puts it back.
    fs::write(bin.join("cmux-holder"), OLD_HOLDER).unwrap();
    std::os::unix::fs::symlink("cmux", bin.join("cmux-tui")).unwrap();
    let files = dir.path().join("files").join(COMMIT);
    fs::create_dir_all(&files).unwrap();
    fs::write(files.join("cmux-tui-aarch64-apple-darwin"), NEW_CMUX).unwrap();
    fs::write(files.join("cmux-tui-app-host-aarch64-apple-darwin"), NEW_HOST).unwrap();
    let base = format!("file://{}/", dir.path().join("files").display());
    let store = Store { root: dir.path().join("state") };
    Fixture { _dir: dir, app, base, store }
}

fn good_targets() -> Value {
    json!({"cmux-tui": binary("cmux-tui", NEW_CMUX), "cmux-tui-app-host": binary("cmux-tui-app-host", NEW_HOST)})
}

fn found(targets: Value) -> Live {
    Live::Found(
        live::verify(&envelope(&payload(live::PURPOSE, COMMIT, targets)), &keys(), COMMIT).unwrap(),
    )
}

/// `server status` of an app's daemon: it runs `exe`; SIGTERM makes the app start the next
/// owner from the same file (`respawn`), or none comes back.
struct FakeDaemon {
    pid: Cell<i32>,
    exe: PathBuf,
    respawn: bool,
    terminated: Cell<u32>,
    /// `server status` cannot tell (it timed out, or the daemon is wedged).
    probe_fails: Cell<bool>,
}

impl FakeDaemon {
    fn new(exe: PathBuf, respawn: bool) -> Self {
        Self {
            pid: Cell::new(100),
            exe,
            respawn,
            terminated: Cell::new(0),
            probe_fails: Cell::new(false),
        }
    }
}

impl Daemon for FakeDaemon {
    fn owner(&self) -> Result<Option<(i32, PathBuf)>, String> {
        if self.probe_fails.get() {
            return Err("server status gave no answer in 10 s".to_owned());
        }
        Ok((self.pid.get() > 0).then(|| (self.pid.get(), self.exe.clone())))
    }
    fn terminate(&self, pid: i32) {
        assert_eq!(pid, self.pid.get(), "only the current owner is signalled");
        self.terminated.set(self.terminated.get() + 1);
        self.pid.set(if self.respawn { pid + 1 } else { 0 });
    }
    fn owner_wait(&self) -> Duration {
        Duration::from_millis(200)
    }
}

fn read(app: &Path, file: &str) -> Option<Vec<u8>> {
    fs::read(app.join(live::BIN).join(file)).ok()
}

fn live_files(fixture: &Fixture, live: &Live) -> Vec<live::Wanted> {
    match choose(COMMIT, Some(APP_COMMIT), live, None, &fixture.base) {
        Plan::Live { files } => files,
        other => panic!("expected the live path, got {other:?}"),
    }
}

#[test]
fn app_try_parse_reads_try_undo_status_and_dry_run() {
    assert_eq!(
        parse(&words(&["43455"])).unwrap(),
        Command::Try { target: "43455".into(), dry_run: false, app: None }
    );
    assert_eq!(
        parse(&words(&["--dry-run", "lane/app-try", "--app", "/A.app"])).unwrap(),
        Command::Try { target: "lane/app-try".into(), dry_run: true, app: Some("/A.app".into()) }
    );
    assert_eq!(parse(&words(&["undo"])).unwrap(), Command::Undo { dry_run: false });
    assert_eq!(parse(&words(&["undo", "--dry-run"])).unwrap(), Command::Undo { dry_run: true });
    assert_eq!(parse(&words(&["status"])).unwrap(), Command::Status);
    assert_eq!(parse(&words(&["--help"])).unwrap(), Command::Help);
    assert!(parse(&words(&[])).is_err());
    assert!(parse(&words(&["a", "b"])).is_err());
    assert!(parse(&words(&["--bogus", "abc1234"])).is_err());
    assert!(parse(&words(&["a..b"])).is_err());
    assert!(parse(&words(&["status", "--dry-run"])).is_err());
}

fn copy_of(tree: &str, from: Option<&str>, action: CopyAction, dry_run: bool) -> Command {
    Command::Copy { tree: tree.into(), from: from.map(PathBuf::from), action, dry_run }
}

#[test]
fn app_try_dot_is_the_working_tree_in_a_copy() {
    assert_eq!(parse(&words(&["."])).unwrap(), copy_of(".", None, CopyAction::Run, false));
    assert_eq!(
        parse(&words(&["dir:/src/cmux", "--from", "/A.app", "--dry-run"])).unwrap(),
        copy_of("/src/cmux", Some("/A.app"), CopyAction::Run, true)
    );
    // --app names the golden copy too, as for a PR.
    assert_eq!(
        parse(&words(&["./cmux", "--app=/A.app"])).unwrap(),
        copy_of("./cmux", Some("/A.app"), CopyAction::Run, false)
    );
    assert_eq!(parse(&words(&["../x"])).unwrap(), copy_of("../x", None, CopyAction::Run, false));
    assert_eq!(
        parse(&words(&[".", "--extract"])).unwrap(),
        copy_of(".", None, CopyAction::Extract, false)
    );
    assert_eq!(
        parse(&words(&[".", "--stop"])).unwrap(),
        copy_of(".", None, CopyAction::Stop, false)
    );
    assert_eq!(
        parse(&words(&["--delete", "."])).unwrap(),
        copy_of(".", None, CopyAction::Stop, false)
    );
}

#[test]
fn app_try_copy_flags_are_refused_where_they_mean_nothing() {
    // A PR, branch or commit keeps its own behavior: the copy's flags are not its.
    assert!(parse(&words(&["43455", "--stop"])).is_err());
    assert!(parse(&words(&["main", "--extract"])).is_err());
    assert!(parse(&words(&["main", "--from", "/A.app"])).is_err());
    assert!(parse(&words(&[".", "--stop", "--extract"])).is_err());
    assert!(parse(&words(&[".", "--stop", "--dry-run"])).is_err());
    assert!(parse(&words(&[".", "--extract", "--from", "/A.app"])).is_err());
    assert!(parse(&words(&[".", "--from", "/A.app", "--app", "/B.app"])).is_err());
    assert!(parse(&words(&[".", "--from"])).is_err());
    assert!(parse(&words(&["dir:"])).is_err());
}

#[test]
fn app_try_dir_targets_never_take_a_branch_name() {
    let home = Path::new("/Users/me");
    assert_eq!(copy::dir_target(".", Some(home)), Some(PathBuf::from(".")));
    assert_eq!(
        copy::dir_target("~/src/cmux", Some(home)),
        Some(PathBuf::from("/Users/me/src/cmux"))
    );
    assert_eq!(copy::dir_target("~/x", None), None);
    assert_eq!(copy::dir_target("dir:rel/path", Some(home)), Some(PathBuf::from("rel/path")));
    for word in ["main", "lane/app-try", "43455", "#43455", "abc1234", ".hidden"] {
        assert_eq!(copy::dir_target(word, Some(home)), None, "{word}");
    }
    // Every word a dir target takes is one the PR/branch/sha form refuses, so no meaning moved.
    for word in [".", "..", "./a", "../a", "/a"] {
        assert!(resolve::classify(word).is_none(), "{word}");
    }
}

#[test]
fn app_try_copy_names_a_stable_side_per_checkout() {
    let name = copy::side_name(Path::new("/Users/me/Projects/checkouts/cmux/lane--App_Try.copy"));
    assert!(name.starts_with("try-lane-app-try-copy-"), "{name}");
    assert_eq!(
        name,
        copy::side_name(Path::new("/Users/me/Projects/checkouts/cmux/lane--App_Try.copy"))
    );
    assert_ne!(name, copy::side_name(Path::new("/Users/me/other/lane--App_Try.copy")));
    let long = copy::side_name(Path::new(&format!("/x/{}", "a".repeat(80))));
    let weird = copy::side_name(Path::new("/x/日本"));
    for name in [&name, &long, &weird] {
        // side-instance.sh's NAME: [a-z0-9][a-z0-9-]{0,39}.
        assert!(name.len() <= 40, "{name}");
        assert!(
            name.bytes().all(|b| b.is_ascii_lowercase() || b.is_ascii_digit() || b == b'-'),
            "{name}"
        );
        assert!(!name.contains("--"), "{name}");
    }
    assert!(weird.starts_with("try-tree-"), "{weird}");
}

#[test]
fn app_try_copy_routes_each_action_to_the_checkout_s_engine() {
    let tree = Path::new("/src/cmux");
    let from = Path::new("/Applications/cmux NIGHTLY.app");
    let argv = |action, dry_run| -> Vec<String> {
        copy::engine_args(action, tree, from, "try-cmux-abc123", dry_run)
            .iter()
            .map(|word| word.to_string_lossy().into_owned())
            .collect()
    };
    let engine = "/src/cmux/scripts/cmux-next/hot-verify.py";
    assert_eq!(
        argv(CopyAction::Run, false),
        [
            engine,
            "run",
            "--source",
            "dir:/src/cmux",
            "--app",
            "/Applications/cmux NIGHTLY.app",
            "--repo",
            "/src/cmux",
            "--side",
            "try-cmux-abc123",
            "--label",
            "cmux try-cmux-abc123",
        ]
    );
    assert_eq!(
        argv(CopyAction::Run, true),
        [
            engine,
            "plan",
            "--source",
            "dir:/src/cmux",
            "--app",
            "/Applications/cmux NIGHTLY.app",
            "--repo",
            "/src/cmux"
        ]
    );
    assert_eq!(argv(CopyAction::Extract, false), [engine, "extract", "--side", "try-cmux-abc123"]);
    assert_eq!(
        argv(CopyAction::Stop, false),
        [engine, "stop", "--side", "try-cmux-abc123", "--remove"]
    );
    assert_eq!(copy::DEFAULT_FROM, "/Applications/cmux NIGHTLY.app");
}

#[test]
fn app_try_copy_says_why_a_build_is_needed_and_offers_the_dev_build() {
    let result = json!({ "plan": { "needs_build": true, "build": {
        "Swift": ["a.swift", "b.swift", "c.swift", "d.swift", "e.swift", "f.swift"],
    } } });
    let text = copy::needs_build_text(&result, COMMIT, "try-cmux-abc123", "/src/cmux");
    assert!(text.contains("/src/cmux needs a build"), "{text}");
    assert!(text.contains("  - Swift: a.swift, b.swift, c.swift, d.swift, e.swift, ..."), "{text}");
    assert!(text.contains("cmux live start --swift"), "{text}");
    assert!(
        text.contains(&format!("cmux-ci build cmux --ref {COMMIT} --tag try-cmux-abc123")),
        "{text}"
    );
    // No Swift, no live code line; the dev build is still offered.
    let ffi = json!({ "plan": { "build": { "Rust the app links (FFI)": ["x.rs"] } } });
    let text = copy::needs_build_text(&ffi, COMMIT, "s", "/t");
    assert!(!text.contains("live start --swift"), "{text}");
    assert!(text.contains("cmux-ci build cmux"), "{text}");
}

#[test]
fn app_try_copy_summary_names_the_socket_and_the_way_out() {
    let result = json!({
        "copy": "/side/cmux try.app", "socket": "/tmp/side sock", "edit_to_live_s": 12.34,
        "applied": { "web": { "how": "dev server" }, "rust": { "how": "published tree build" } },
    });
    let text = copy::running(&result, Path::new("/Applications/cmux NIGHTLY.app"), "/src/cmux");
    assert!(text.contains("cmux --app-socket '/tmp/side sock' <command>"), "{text}");
    assert!(text.contains("cmux app try /src/cmux --stop"), "{text}");
    assert!(text.contains("cmux app try /src/cmux --extract"), "{text}");
    assert!(text.contains("(12.3 s)"), "{text}");
    assert!(text.contains("daemon Rust"), "{text}");
    let nothing = copy::running(&json!({ "applied": {} }), Path::new("/A.app"), ".");
    assert!(nothing.contains("nothing in the app changes"), "{nothing}");
}

#[test]
fn app_try_copy_elsewhere_says_to_push_first_only_when_needed() {
    assert!(copy::unpushed(true, Some(0)).is_some());
    assert!(copy::unpushed(false, None).is_some());
    assert!(copy::unpushed(false, Some(2)).is_some());
    assert_eq!(copy::unpushed(false, Some(0)), None);
    assert_eq!(copy::shell_word("/a/b"), "/a/b");
    assert_eq!(copy::shell_word("/a b/it's"), r"'/a b/it'\''s'");
}

#[test]
fn app_try_classify_and_resolve_answers() {
    assert_eq!(resolve::classify("43455"), Some(Spec::Pull(43455)));
    assert_eq!(resolve::classify("#7"), Some(Spec::Pull(7)));
    assert_eq!(
        resolve::classify("https://github.com/manaflow-ai/cmux/pull/43463"),
        Some(Spec::Pull(43463))
    );
    assert_eq!(resolve::classify("ABCDEF1"), Some(Spec::Commit("abcdef1".into())));
    assert_eq!(resolve::classify(COMMIT), Some(Spec::Commit(COMMIT.into())));
    assert_eq!(resolve::classify("feat-cmux-next"), Some(Spec::Branch("feat-cmux-next".into())));
    assert_eq!(resolve::classify("-x"), None);
    assert_eq!(resolve::classify("a..b"), None);
    assert_eq!(resolve::classify("has space"), None);
    // A full sha needs no network; a short one, a PR and a branch ask GitHub.
    assert_eq!(resolve::api_path(&Spec::Commit(COMMIT.into())), None);
    assert_eq!(
        resolve::api_path(&Spec::Pull(5)).as_deref(),
        Some("/repos/manaflow-ai/cmux/pulls/5")
    );
    let pull = Spec::Pull(5);
    let head = json!({"head": {"sha": COMMIT}}).to_string();
    assert_eq!(resolve::commit_in(&pull, 200, head.as_bytes()), Ok(COMMIT.to_owned()));
    let limited = br#"{"message":"API rate limit exceeded for 1.2.3.4."}"#;
    assert_eq!(resolve::commit_in(&pull, 403, limited), Err(Unresolved::RateLimited));
    assert_eq!(resolve::commit_in(&pull, 404, b"{}"), Err(Unresolved::NotFound));
    let short = Spec::Commit("0123456".into());
    let other = json!({"sha": "f".repeat(40)}).to_string();
    assert_eq!(resolve::commit_in(&short, 200, other.as_bytes()), Err(Unresolved::NotFound));
}

#[test]
fn app_try_verify_checks_signature_purpose_and_commit() {
    let good = envelope(&payload(live::PURPOSE, COMMIT, good_targets()));
    assert_eq!(live::verify(&good, &keys(), COMMIT).unwrap().commit, COMMIT);
    // A Cloud machine channel file is signed with the same key: its purpose keeps it out.
    let cloud = envelope(&payload("cmux-cloud-machine-update", COMMIT, good_targets()));
    assert!(live::verify(&cloud, &keys(), COMMIT).unwrap_err().contains("not a Mac live update"));
    let other = "f".repeat(40);
    assert!(live::verify(&good, &keys(), &other).unwrap_err().contains("not"));
    let unsigned = cmux_host::updater::channel::trusted_keys();
    assert!(live::verify(&good, &unsigned, COMMIT).unwrap_err().contains("signature"));
}

#[test]
fn app_try_native_proof_is_required_even_when_the_daemon_is_compatible() {
    let fixture = fixture();
    let listing = json!({"installed": "400", "switches": true, "builds": [
        {"build": "500", "commit": COMMIT, "installed": false, "switchable": true, "health": "pending"},
    ]});
    for proof in [None, Some(json!([])), Some(json!([COMMIT]))] {
        let mut body = payload(live::PURPOSE, COMMIT, good_targets());
        body.as_object_mut().unwrap().remove("native_from");
        if let Some(proof) = proof {
            body["native_from"] = proof;
        }
        let live = Live::Found(live::verify(&envelope(&body), &keys(), COMMIT).unwrap());
        // A Swift-only edit can retain live_from membership. It still needs the full app.
        let plan = choose(COMMIT, Some(APP_COMMIT), &live, Some(Ok(&listing)), &fixture.base);
        let Plan::Full { build, .. } = plan else { panic!("expected full, got {plan:?}") };
        assert_eq!(build["build"], "500");
        // No matching full build must never report that the requested app is live.
        let plan = choose(COMMIT, Some(APP_COMMIT), &live, None, &fixture.base);
        let Plan::None { why } = plan else { panic!("expected none, got {plan:?}") };
        assert!(why.iter().any(|reason| reason.contains("native")), "{why:?}");
        assert_eq!(read(&fixture.app, "cmux").as_deref(), Some(OLD_CMUX));
        assert!(fixture.store.last().is_none());
    }
}

#[test]
fn app_try_native_proof_keeps_compatible_live_swaps_and_same_commit_legacy_manifests() {
    let fixture = fixture();
    let live = found(good_targets());
    assert!(matches!(
        choose(COMMIT, Some(APP_COMMIT), &live, None, &fixture.base),
        Plan::Live { .. }
    ));
    let mut legacy = payload(live::PURPOSE, COMMIT, good_targets());
    legacy.as_object_mut().unwrap().remove("native_from");
    let live = Live::Found(live::verify(&envelope(&legacy), &keys(), COMMIT).unwrap());
    assert!(matches!(
        choose(COMMIT, Some(&COMMIT[..10]), &live, None, &fixture.base),
        Plan::Live { .. }
    ));
}

#[test]
fn app_try_native_proof_must_name_the_same_full_commit_as_daemon_compatibility() {
    let fixture = fixture();
    let mut body = payload(live::PURPOSE, COMMIT, good_targets());
    // Sharing the installed app's short prefix is not proof about the resolved full commit.
    body["native_from"] = json!([format!("{APP_COMMIT}{}", "0".repeat(33))]);
    let live = Live::Found(live::verify(&envelope(&body), &keys(), COMMIT).unwrap());
    assert!(matches!(
        choose(COMMIT, Some(APP_COMMIT), &live, None, &fixture.base),
        Plan::None { .. }
    ));
    // Native equality also cannot replace daemon compatibility.
    body["native_from"] = json!([APP_FULL_COMMIT]);
    body["live_from"] = json!([COMMIT]);
    let live = Live::Found(live::verify(&envelope(&body), &keys(), COMMIT).unwrap());
    assert!(matches!(
        choose(COMMIT, Some(APP_COMMIT), &live, None, &fixture.base),
        Plan::None { .. }
    ));
}

#[test]
fn app_try_plan_picks_live_full_and_none() {
    let fixture = fixture();
    let base = fixture.base.as_str();
    // Live: the app's short CMUXCommit is in live_from.
    let plan = choose(COMMIT, Some(APP_COMMIT), &found(good_targets()), None, base);
    let Plan::Live { files } = plan else { panic!("expected live, got {plan:?}") };
    let cmux = files.iter().find(|w| w.file == "cmux").unwrap();
    assert_eq!(
        cmux.fetch_url.as_deref(),
        Some(format!("{base}{COMMIT}/cmux-tui-aarch64-apple-darwin").as_str())
    );
    assert!(files.iter().any(|w| w.file == "cmux-holder" && w.binary.is_none()));

    // Full: the app is not in live_from, and the feed has the commit's build.
    let listing = json!({"installed": "400", "switches": true, "builds": [
        {"build": "500", "commit": &COMMIT[..10], "installed": false, "switchable": true, "health": "pending"},
        {"build": "400", "commit": "aaaaaaaaaa", "installed": true, "switchable": false},
    ]});
    let plan = choose(COMMIT, Some("fedcba9"), &found(good_targets()), Some(Ok(&listing)), base);
    let Plan::Full { build, from } = plan else { panic!("expected full, got {plan:?}") };
    assert_eq!((build["build"].as_str(), from.as_str()), (Some("500"), "400"));

    // Full too when there is no live file at all.
    let plan = choose(COMMIT, Some(APP_COMMIT), &Live::Missing, Some(Ok(&listing)), base);
    assert!(matches!(plan, Plan::Full { .. }), "{plan:?}");

    // None: no live file and no build in the feed, with each reason.
    let empty = json!({"installed": "400", "switches": true, "builds": []});
    let plan = choose(COMMIT, Some(APP_COMMIT), &Live::Missing, Some(Ok(&empty)), base);
    let Plan::None { why } = plan else { panic!("expected none, got {plan:?}") };
    assert_eq!(why.len(), 2, "{why:?}");
    // A binary this CLI does not know where to put refuses the live path.
    let odd = json!({"cmux-tui": binary("cmux-tui", NEW_CMUX), "cmux-tui-mystery": binary("cmux-tui-mystery", b"x")});
    let plan = choose(COMMIT, Some(APP_COMMIT), &found(odd), Some(Err("no app")), base);
    let Plan::None { why } = plan else { panic!("expected none, got {plan:?}") };
    assert!(why[0].contains("cmux-tui-mystery"), "{why:?}");
    // A url outside the commit's own publication is refused.
    let mut moved = good_targets();
    moved["cmux-tui"]["url"] =
        json!("https://files.cmux.com/cmux-tui/other/cmux-tui-aarch64-apple-darwin");
    assert!(matches!(
        choose(COMMIT, Some(APP_COMMIT), &found(moved), None, base),
        Plan::None { .. }
    ));
    // A DEV build (no CMUXCommit) never takes a live build.
    assert!(matches!(choose(COMMIT, None, &found(good_targets()), None, base), Plan::None { .. }));
}

#[test]
fn app_try_sha256_mismatch_refuses_and_changes_nothing() {
    let fixture = fixture();
    let mut targets = good_targets();
    targets["cmux-tui-app-host"]["sha256"] = json!(sha(b"something else"));
    targets["cmux-tui-app-host"]["size"] = json!(NEW_HOST.len());
    let files = live_files(&fixture, &found(targets));
    let daemon = FakeDaemon::new(fixture.app.join(live::BIN).join("cmux"), true);
    let error = try_live(&fixture.app, &files, &fixture.store, &daemon, &mut Phases::default())
        .unwrap_err();
    assert!(error.contains("hashes to"), "{error}");
    assert_eq!(read(&fixture.app, "cmux").as_deref(), Some(OLD_CMUX));
    assert_eq!(read(&fixture.app, "cmux-app-host").as_deref(), Some(OLD_HOST));
    assert_eq!(read(&fixture.app, "cmux-holder").as_deref(), Some(OLD_HOLDER));
    assert_eq!(daemon.terminated.get(), 0, "the daemon is never touched");
    assert!(fixture.store.last().is_none());
}

#[test]
fn app_try_live_swaps_hands_off_and_undo_restores_the_bytes() {
    let fixture = fixture();
    let files = live_files(&fixture, &found(good_targets()));
    let daemon = FakeDaemon::new(fixture.app.join(live::BIN).join("cmux"), true);
    let mut phases = Phases::default();
    let applied = try_live(&fixture.app, &files, &fixture.store, &daemon, &mut phases).unwrap();
    assert!(applied.changed);
    assert_eq!(read(&fixture.app, "cmux").as_deref(), Some(NEW_CMUX));
    assert_eq!(read(&fixture.app, "cmux-tui").as_deref(), Some(NEW_CMUX), "the link follows");
    assert_eq!(read(&fixture.app, "cmux-app-host").as_deref(), Some(NEW_HOST));
    assert_eq!(read(&fixture.app, "cmux-holder"), None);
    assert_eq!(daemon.terminated.get(), 1);
    assert_eq!(applied.steps["daemon"], "app handoff");
    assert_eq!(
        (applied.steps["old_pid"].as_i64(), applied.steps["new_pid"].as_i64()),
        (Some(100), Some(101))
    );
    let phases = phases.json();
    for phase in ["fetch", "find", "backup", "swap", "reload"] {
        assert!(phases.get(phase).is_some(), "{phase} in {phases}");
    }
    fixture
        .store
        .record(&json!({"action": "try", "ok": true, "app": fixture.app.to_string_lossy(), "app_commit": APP_COMMIT,
                        "steps": applied.steps, "undo": {"files": applied.prior}}))
        .unwrap();

    // The same try again changes nothing and leaves the daemon alone.
    let again =
        try_live(&fixture.app, &files, &fixture.store, &daemon, &mut Phases::default()).unwrap();
    assert!(!again.changed);
    assert_eq!(daemon.terminated.get(), 1);

    let undone = undo_live(&fixture.store, &daemon).unwrap();
    assert!(undone.changed);
    assert_eq!(read(&fixture.app, "cmux").as_deref(), Some(OLD_CMUX));
    assert_eq!(read(&fixture.app, "cmux-app-host").as_deref(), Some(OLD_HOST));
    assert_eq!(read(&fixture.app, "cmux-holder").as_deref(), Some(OLD_HOLDER));
    assert_eq!(daemon.terminated.get(), 2, "undo hands the daemon over too");
}

#[test]
fn app_try_undo_refuses_after_an_update_replaced_the_files() {
    let fixture = fixture();
    let files = live_files(&fixture, &found(good_targets()));
    let daemon = FakeDaemon::new(fixture.app.join(live::BIN).join("cmux"), true);
    let applied =
        try_live(&fixture.app, &files, &fixture.store, &daemon, &mut Phases::default()).unwrap();
    fixture
        .store
        .record(&json!({"action": "try", "ok": true, "app": fixture.app.to_string_lossy(), "app_commit": APP_COMMIT,
                        "steps": applied.steps, "undo": {"files": applied.prior}}))
        .unwrap();
    // The next nightly replaced the bundle: undo must not put the files from before the try back.
    fs::write(fixture.app.join(live::BIN).join("cmux"), b"next nightly").unwrap();
    let error = undo_live(&fixture.store, &daemon).unwrap_err();
    assert!(error.contains("changed since the try"), "{error}");
    assert_eq!(read(&fixture.app, "cmux").as_deref(), Some(&b"next nightly"[..]));
    assert_eq!(read(&fixture.app, "cmux-app-host").as_deref(), Some(NEW_HOST));
}

#[test]
fn app_try_failed_handoff_puts_every_file_back() {
    let fixture = fixture();
    let files = live_files(&fixture, &found(good_targets()));
    // SIGTERM and no new owner answers.
    let daemon = FakeDaemon::new(fixture.app.join(live::BIN).join("cmux"), false);
    let error = try_live(&fixture.app, &files, &fixture.store, &daemon, &mut Phases::default())
        .unwrap_err();
    assert!(error.contains("every file is back"), "{error}");
    assert_eq!(read(&fixture.app, "cmux").as_deref(), Some(OLD_CMUX));
    assert_eq!(read(&fixture.app, "cmux-app-host").as_deref(), Some(OLD_HOST));
    assert_eq!(read(&fixture.app, "cmux-holder").as_deref(), Some(OLD_HOLDER));
}

#[test]
fn app_try_refuses_a_daemon_that_is_not_this_apps() {
    let fixture = fixture();
    let files = live_files(&fixture, &found(good_targets()));
    let elsewhere = fixture.store.root.join("other-cmux");
    fs::create_dir_all(&fixture.store.root).unwrap();
    fs::write(&elsewhere, b"x").unwrap();
    let daemon = FakeDaemon::new(elsewhere, true);
    let error = try_live(&fixture.app, &files, &fixture.store, &daemon, &mut Phases::default())
        .unwrap_err();
    assert!(error.contains("not this app's"), "{error}");
    assert_eq!(read(&fixture.app, "cmux").as_deref(), Some(OLD_CMUX));
    assert_eq!(daemon.terminated.get(), 0);
}

#[test]
fn app_try_reads_the_short_commit_and_status_pid() {
    let fixture = fixture();
    assert_eq!(super::app_commit(&fixture.app).as_deref(), Some(APP_COMMIT));
    assert!(live::takes(&[COMMIT.to_owned()], "0123456"));
    assert!(!live::takes(&[COMMIT.to_owned()], "0123"));
    assert!(!live::takes(&[COMMIT.to_owned()], "fedcba9"));
    assert_eq!(live::status_pid(r#"{"pid": 4242, "socket": "/tmp/s"}"#), Some(4242));
    assert_eq!(live::status_pid(r#"{"result": {"pid": 7}}"#), Some(7));
    assert_eq!(live::status_pid("not json"), None);
    let absent = r#"{"code": "server.unavailable", "message": "x", "details": null}"#;
    assert_eq!(live::status_error(absent).as_deref(), Some("server.unavailable"));
    assert_eq!(
        live::status_error(r#"{"error": {"code": "server.wedged"}}"#).as_deref(),
        Some("server.wedged")
    );
    assert_eq!(live::status_error("cmux: boom"), None);
}

#[test]
fn app_try_refuses_to_swap_under_a_daemon_it_cannot_name() {
    let fixture = fixture();
    let files = live_files(&fixture, &found(good_targets()));
    let daemon = FakeDaemon::new(fixture.app.join(live::BIN).join("cmux"), true);
    daemon.probe_fails.set(true);
    let error = try_live(&fixture.app, &files, &fixture.store, &daemon, &mut Phases::default())
        .unwrap_err();
    assert!(error.contains("the daemon is unknown; nothing changed"), "{error}");
    assert_eq!(read(&fixture.app, "cmux").as_deref(), Some(OLD_CMUX));
    assert_eq!(read(&fixture.app, "cmux-app-host").as_deref(), Some(OLD_HOST));
    assert_eq!(read(&fixture.app, "cmux-holder").as_deref(), Some(OLD_HOLDER));
    assert_eq!(daemon.terminated.get(), 0);
}

#[test]
fn app_try_undo_refuses_into_another_build_with_the_same_rust_bytes() {
    let fixture = fixture();
    let files = live_files(&fixture, &found(good_targets()));
    let daemon = FakeDaemon::new(fixture.app.join(live::BIN).join("cmux"), true);
    let applied =
        try_live(&fixture.app, &files, &fixture.store, &daemon, &mut Phases::default()).unwrap();
    fixture
        .store
        .record(&json!({"action": "try", "ok": true, "app": fixture.app.to_string_lossy(), "app_commit": APP_COMMIT,
                        "steps": applied.steps, "undo": {"files": applied.prior}}))
        .unwrap();
    // A full update to another commit that ships the very Rust files the try put in.
    let plist = fixture.app.join("Contents/Info.plist");
    let text = fs::read_to_string(&plist).unwrap().replace(APP_COMMIT, "fedcba9");
    fs::write(&plist, text).unwrap();
    let error = undo_live(&fixture.store, &daemon).unwrap_err();
    assert!(error.contains("at fedcba9 now, not 89abcde"), "{error}");
    assert_eq!(read(&fixture.app, "cmux").as_deref(), Some(NEW_CMUX));
    assert_eq!(read(&fixture.app, "cmux-holder"), None);
}
