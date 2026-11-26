use std::cell::Cell;
use std::fs;
use std::path::{Path, PathBuf};
use std::time::Duration;

use base64::Engine as _;
use serde_json::{Value, json};
use sha2::{Digest as _, Sha256};

use super::copy::{self, Action as CopyAction};
use super::helper::{self, Signing};
use super::live::{self, Daemon, Phases, Store};
use super::resolve::{self, Spec, Unresolved};
use super::{
    ChannelApply, Command, Live, Plan, Scope, app_build, apply_channel, choose, finish, nearest,
    parse, plan_human, plan_json, try_live, try_live_checked, undo_live,
};

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

impl Fixture {
    /// Exercise the command's shared channel/apply boundary with signed fixture
    /// bytes and a fake daemon, including the forward-only state write.
    fn run_channel_once(
        &self,
        channel_body: &[u8],
        live_body: &[u8],
        keys: &[(String, [u8; 32])],
        daemon: &dyn Daemon,
        now: u64,
    ) -> Result<bool, String> {
        let channel = live::verify_channel(channel_body, keys, now)?;
        match apply_channel(&self.app, &self.store, &channel, false, |app_commit| {
            let payload = live::verify(live_body, keys, &channel.commit)?;
            let plan = choose(
                &channel.commit,
                Some(app_commit),
                &Live::Found(Box::new(payload)),
                None,
                &self.base,
            );
            let Plan::Live { files, helper, .. } = plan else {
                return Err("the signed channel has no live payload this app can take".to_owned());
            };
            let applied = try_live(
                &self.app,
                &files,
                helper.as_ref(),
                &self.store,
                daemon,
                &NoSigning,
                &mut Phases::default(),
            )?;
            Ok(applied.changed)
        })? {
            ChannelApply::SkippedOlder => Ok(false),
            ChannelApply::Applied { changed } => Ok(changed),
        }
    }
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
    Live::Found(Box::new(
        live::verify(&envelope(&payload(live::PURPOSE, COMMIT, targets)), &keys(), COMMIT).unwrap(),
    ))
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
        Plan::Live { files, scope: Scope::Whole, .. } => files,
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
    assert_eq!(
        parse(&words(&["channel"])).unwrap(),
        Command::Channel { dry_run: false, app: None }
    );
    assert_eq!(
        parse(&words(&["channel", "--dry-run", "--app", "/A.app"])).unwrap(),
        Command::Channel { dry_run: true, app: Some("/A.app".into()) }
    );
    assert_eq!(parse(&words(&["--help"])).unwrap(), Command::Help);
    assert!(parse(&words(&[])).is_err());
    assert!(parse(&words(&["a", "b"])).is_err());
    assert!(parse(&words(&["--bogus", "abc1234"])).is_err());
    assert!(parse(&words(&["a..b"])).is_err());
    assert!(parse(&words(&["status", "--dry-run"])).is_err());
}

#[test]
fn nightly_live_channel_checks_signature_binding_expiry_and_forward_only_order() {
    let signed = envelope(&payload(live::PURPOSE, COMMIT, good_targets()));
    let channel = live::verify_channel(&signed, &keys(), 1_200).unwrap();
    assert_eq!(channel.commit, COMMIT);
    assert!(live::channel_is_newer(None, channel.committed_at));
    assert!(!live::channel_is_newer(Some(channel.committed_at), channel.committed_at));
    assert!(!live::channel_is_newer(Some(channel.committed_at + 1), channel.committed_at));

    let wrong_purpose = envelope(&payload("cmux-cloud-machine-update", COMMIT, good_targets()));
    let error = live::verify_channel(&wrong_purpose, &keys(), 1_200).unwrap_err();
    assert!(error.contains("not the nightly-live Mac channel"), "{error}");

    let mut expired = payload(live::PURPOSE, COMMIT, good_targets());
    expired["expires_at"] = json!(1_200);
    let error = live::verify_channel(&envelope(&expired), &keys(), 1_200).unwrap_err();
    assert!(error.contains("expired"), "{error}");

    let mut unbound = payload(live::PURPOSE, COMMIT, good_targets());
    unbound["live_from"] = json!(["89abcdef0123456789abcdef0123456789abcdef", COMMIT]);
    let error = live::verify_channel(&envelope(&unbound), &keys(), 1_200).unwrap_err();
    assert!(error.contains("live_from does not start"), "{error}");

    let fixture = fixture();
    assert_eq!(fixture.store.channel_last().unwrap(), None);
    fixture.store.record_channel(1_100, COMMIT).unwrap();
    assert_eq!(fixture.store.channel_last().unwrap(), Some(1_100));
    fs::write(fixture.store.root.join("channel.json"), b"not json").unwrap();
    let error = fixture.store.channel_last().unwrap_err();
    assert!(error.contains("invalid channel state"), "{error}");
}

#[test]
fn nightly_live_channel_command_fixture_applies_readback_and_refuses_older_or_bad_updates() {
    let fixture = fixture();
    let channel_body = envelope(&payload(live::PURPOSE, COMMIT, good_targets()));
    let live_body = envelope(&payload(live::PURPOSE, COMMIT, good_targets()));
    let daemon = FakeDaemon::new(fixture.app.join(live::BIN).join("cmux"), true);

    assert!(fixture.run_channel_once(&channel_body, &live_body, &keys(), &daemon, 1_200).unwrap());
    assert_eq!(read(&fixture.app, "cmux").as_deref(), Some(NEW_CMUX));
    assert_eq!(fixture.store.channel_last().unwrap(), Some(1_000));
    // The same pointer is forward-only and does not re-run the daemon handoff.
    assert!(!fixture.run_channel_once(&channel_body, &live_body, &keys(), &daemon, 1_200).unwrap());
    assert_eq!(daemon.terminated.get(), 1);

    // A newer pointer whose files are already current still advances the
    // watermark, so a later older pointer cannot move it back.
    let mut current = payload(live::PURPOSE, COMMIT, good_targets());
    current["committed_at"] = json!(1_200);
    assert!(
        !fixture
            .run_channel_once(&envelope(&current), &live_body, &keys(), &daemon, 1_200)
            .unwrap()
    );
    assert_eq!(fixture.store.channel_last().unwrap(), Some(1_200));
    let mut older = payload(live::PURPOSE, COMMIT, good_targets());
    older["committed_at"] = json!(1_100);
    assert!(
        !fixture.run_channel_once(&envelope(&older), &live_body, &keys(), &daemon, 1_200).unwrap()
    );
    assert_eq!(fixture.store.channel_last().unwrap(), Some(1_200));
    assert_eq!(daemon.terminated.get(), 1);

    // A newer pointer whose per-commit bytes fail verification leaves the
    // already-applied files and channel receipt intact.
    let mut newer = payload(live::PURPOSE, COMMIT, good_targets());
    newer["committed_at"] = json!(1_300);
    let mut bad_targets = good_targets();
    bad_targets["cmux-tui-app-host"]["sha256"] = json!(sha(b"wrong"));
    let bad_live = envelope(&payload(live::PURPOSE, COMMIT, bad_targets));
    let error = fixture
        .run_channel_once(&envelope(&newer), &bad_live, &keys(), &daemon, 1_200)
        .unwrap_err();
    assert!(
        error.contains("live payload") || error.contains("sha256") || error.contains("hashes to"),
        "{error}"
    );
    assert_eq!(read(&fixture.app, "cmux").as_deref(), Some(NEW_CMUX));
    assert_eq!(fixture.store.channel_last().unwrap(), Some(1_200));
}

#[test]
fn nightly_live_channel_takes_daemon_from_past_the_whole_app_floor() {
    // CI's live_from stops at the first Swift, web or resource change (a whole-app floor); daemon_from goes
    // on to the daemon ABI floor. The channel and `cmux app try COMMIT` both swap only the daemon then, and
    // `app try` names the Swift it leaves out instead of claiming the app is at COMMIT.
    let mut daemon_only = payload(live::PURPOSE, COMMIT, good_targets());
    daemon_only["live_from"] = json!([COMMIT]);
    daemon_only.as_object_mut().unwrap().remove("native_from");
    daemon_only["daemon_from"] = json!([COMMIT, APP_FULL_COMMIT]);
    let live =
        Live::Found(Box::new(live::verify(&envelope(&daemon_only), &keys(), COMMIT).unwrap()));
    let first = fixture();
    let plan = choose(COMMIT, Some(APP_COMMIT), &live, None, &first.base);
    let Plan::Live { scope: Scope::Daemon(left), .. } = &plan else {
        panic!("expected daemon-only live, got {plan:?}")
    };
    assert!(left.iter().any(|reason| reason.contains("whole-app floor")), "{left:?}");
    let daemon = FakeDaemon::new(first.app.join(live::BIN).join("cmux"), true);
    let body = envelope(&daemon_only);
    assert!(first.run_channel_once(&body, &body, &keys(), &daemon, 1_200).unwrap());
    assert_eq!(read(&first.app, "cmux").as_deref(), Some(NEW_CMUX));
    assert_eq!(daemon.terminated.get(), 1);

    // An app below the daemon floor is refused before anything is locked or fetched.
    let fixture = fixture();
    let mut floored = daemon_only.clone();
    floored["daemon_from"] = json!([COMMIT]);
    floored["committed_at"] = json!(1_500);
    let error =
        fixture.run_channel_once(&envelope(&floored), &body, &keys(), &daemon, 1_200).unwrap_err();
    assert!(error.contains("daemon_from"), "{error}");
    assert_eq!(read(&fixture.app, "cmux").as_deref(), Some(OLD_CMUX));

    let mut unbound = daemon_only.clone();
    unbound["daemon_from"] = json!([APP_FULL_COMMIT, COMMIT]);
    let error = live::verify_channel(&envelope(&unbound), &keys(), 1_200).unwrap_err();
    assert!(error.contains("daemon_from does not start"), "{error}");
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
        copy::engine_args(action, tree, from, "try-cmux-abc123", dry_run, false)
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
fn app_try_copy_with_no_from_lets_the_engine_pick_a_closer_golden_copy() {
    let tree = Path::new("/src/cmux");
    let from = Path::new("/Applications/cmux NIGHTLY.app");
    let argv = |dry_run| -> Vec<String> {
        copy::engine_args(CopyAction::Run, tree, from, "try-cmux-abc123", dry_run, true)
            .iter()
            .map(|word| word.to_string_lossy().into_owned())
            .collect()
    };
    let run = argv(false);
    assert_eq!(run[1], "run");
    assert_eq!(run.last().map(String::as_str), Some("--pick"));
    let dry = argv(true);
    assert_eq!(dry[1], "golden");
    assert!(!dry.contains(&"--pick".to_owned()));
}

#[test]
fn app_try_copy_names_the_golden_copy_only_when_it_is_not_the_nightly() {
    let picked = json!({
        "copy": "/side/cmux try.app", "socket": "/tmp/s", "applied": { "web": { "how": "dev server" } },
        "golden": { "kind": "fleet", "why": "fleet build ahead-x at 0123456789ab takes this tree with no build" },
    });
    let text = copy::running(&picked, Path::new("/cache/golden/fleet-0123/cmux DEV.app"), ".");
    assert!(text.starts_with("Golden copy: fleet build ahead-x"), "{text}");
    assert!(text.contains("copy of /cache/golden/fleet-0123/cmux DEV.app"), "{text}");
    let installed = json!({ "applied": {}, "golden": { "kind": "installed", "why": "w" } });
    assert_eq!(copy::golden_line(&installed), None);
    assert_eq!(copy::golden_line(&json!({ "applied": {} })), None);
    let none = json!({ "plan": { "build": { "Swift": ["a.swift"] } },
                       "golden": { "kind": "installed", "tried": [{}, {}, {}] } });
    let text = copy::needs_build_text(&none, COMMIT, "try-cmux-abc123", "/src/cmux");
    assert!(text.contains("(2 tried)"), "{text}");
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
fn app_try_native_proof_is_required_for_the_whole_app_and_the_daemon_goes_alone_without_it() {
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
        let live = Live::Found(Box::new(live::verify(&envelope(&body), &keys(), COMMIT).unwrap()));
        // Without native proof the whole app is not live: a build of the commit in the feed wins.
        let plan = choose(COMMIT, Some(APP_COMMIT), &live, Some(Ok(&listing)), &fixture.base);
        let Plan::Full { build, .. } = plan else { panic!("expected full, got {plan:?}") };
        assert_eq!(build["build"], "500");
        // With no such build the daemon goes in alone, and the plan says what the app keeps:
        // it is never reported as the whole app at COMMIT.
        let empty = json!({"installed": "400", "switches": true, "builds": []});
        for builds in [None, Some(Ok(&empty)), Some(Err("no app answers"))] {
            let plan = choose(COMMIT, Some(APP_COMMIT), &live, builds, &fixture.base);
            let Plan::Live { scope: Scope::Daemon(left), .. } = &plan else {
                panic!("expected daemon-only live, got {plan:?}")
            };
            assert!(left.iter().any(|reason| reason.contains("native_from")), "{left:?}");
        }
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
    let live = Live::Found(Box::new(live::verify(&envelope(&legacy), &keys(), COMMIT).unwrap()));
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
    let live = Live::Found(Box::new(live::verify(&envelope(&body), &keys(), COMMIT).unwrap()));
    assert!(matches!(
        choose(COMMIT, Some(APP_COMMIT), &live, None, &fixture.base),
        Plan::Live { scope: Scope::Daemon(_), .. }
    ));
    // Native equality also cannot replace daemon compatibility (no daemon_from: live_from is the list).
    body["native_from"] = json!([APP_FULL_COMMIT]);
    body["live_from"] = json!([COMMIT]);
    let live = Live::Found(Box::new(live::verify(&envelope(&body), &keys(), COMMIT).unwrap()));
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
    let Plan::Live { files, .. } = plan else { panic!("expected live, got {plan:?}") };
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
    let Plan::Full { build, from, nearest: false } = plan else {
        panic!("expected full, got {plan:?}")
    };
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
    let error = try_live(
        &fixture.app,
        &files,
        None,
        &fixture.store,
        &daemon,
        &NoSigning,
        &mut Phases::default(),
    )
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
    let applied =
        try_live(&fixture.app, &files, None, &fixture.store, &daemon, &NoSigning, &mut phases)
            .unwrap();
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
    let again = try_live(
        &fixture.app,
        &files,
        None,
        &fixture.store,
        &daemon,
        &NoSigning,
        &mut Phases::default(),
    )
    .unwrap();
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
    let applied = try_live(
        &fixture.app,
        &files,
        None,
        &fixture.store,
        &daemon,
        &NoSigning,
        &mut Phases::default(),
    )
    .unwrap();
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
    let error = try_live(
        &fixture.app,
        &files,
        None,
        &fixture.store,
        &daemon,
        &NoSigning,
        &mut Phases::default(),
    )
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
    let error = try_live(
        &fixture.app,
        &files,
        None,
        &fixture.store,
        &daemon,
        &NoSigning,
        &mut Phases::default(),
    )
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
    let error = try_live(
        &fixture.app,
        &files,
        None,
        &fixture.store,
        &daemon,
        &NoSigning,
        &mut Phases::default(),
    )
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
    let applied = try_live(
        &fixture.app,
        &files,
        None,
        &fixture.store,
        &daemon,
        &NoSigning,
        &mut Phases::default(),
    )
    .unwrap();
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

// ------------------------------------------------------------------ the nearest full build

/// Commits of a linear feat-cmux-next, oldest first, and a side branch merged into it.
const C0: &str = "c000000000000000000000000000000000000000";
const C1: &str = "c100000000000000000000000000000000000000";
const C2: &str = "c200000000000000000000000000000000000000";
const C3: &str = "c300000000000000000000000000000000000000";
const SIDE: &str = "5dde000000000000000000000000000000000000";

fn listed(sha: &str, parents: &[&str]) -> Value {
    json!({"sha": sha, "parents": parents.iter().map(|p| json!({"sha": p})).collect::<Vec<_>>()})
}

/// GitHub's compare of C0...C3: C1, a side branch commit from before C0, C2 merging it, C3.
fn compare_body(status: &str, ahead_by: u64) -> Vec<u8> {
    serde_json::to_vec(&json!({
        "status": status, "ahead_by": ahead_by, "behind_by": 0,
        // Listed out of topological order on purpose.
        "commits": [listed(C2, &[C1, SIDE]), listed(SIDE, &["0dd0000000000000000000000000000000000000"]),
                    listed(C1, &[C0]), listed(C3, &[C2])],
    }))
    .unwrap()
}

#[test]
fn app_try_descent_names_every_commit_that_contains_the_target() {
    let descent = resolve::descent_in(C0, 200, &compare_body("ahead", 4)).unwrap();
    assert!(descent.head_contains() && descent.complete);
    for sha in [C0, C1, C2, C3] {
        assert!(descent.has(sha), "{sha}");
        // A feed names a build's commit short.
        assert!(descent.has(&sha[..10].to_ascii_uppercase()), "{sha}");
    }
    // The merged side branch's own commit was never built on top of the target.
    assert!(!descent.has(SIDE));
    // Too short to name one commit, or not hex.
    assert!(!descent.has("c1000") && !descent.has("zzzzzzzzzz"));
    // GitHub lists at most 250 commits: the rest are unknown, the head still contains it.
    let truncated = resolve::descent_in(C0, 200, &compare_body("ahead", 900)).unwrap();
    assert!(!truncated.complete && truncated.head_contains());
    let apart = resolve::descent_in(C0, 200, &compare_body("diverged", 4)).unwrap();
    assert!(!apart.head_contains());
    assert_eq!(
        resolve::descent_path(C0, "c3000000"),
        format!("/repos/manaflow-ai/cmux/compare/{C0}...c3000000")
    );
    let limited = br#"{"message": "API rate limit exceeded for 1.2.3.4."}"#;
    assert_eq!(resolve::descent_in(C0, 403, limited), Err(Unresolved::RateLimited));
    assert_eq!(resolve::descent_in(C0, 404, b"{}"), Err(Unresolved::NotFound));
    assert!(matches!(resolve::descent_in(C0, 200, b"{}"), Err(Unresolved::Other(_))));
}

fn build(number: &str, commit: &str, installed: bool, health: &str) -> Value {
    json!({"build": number, "commit": &commit[..10], "installed": installed,
           "switchable": !installed && health != "pulled", "health": health})
}

fn feed(installed: &str, builds: Vec<Value>) -> Value {
    json!({"installed": installed, "switches": true, "builds": builds})
}

#[test]
fn app_try_takes_the_nearest_build_that_contains_the_commit() {
    let descent = resolve::descent_in(C0, 200, &compare_body("ahead", 4)).unwrap();
    let old = "0dd0000000000000000000000000000000000000";
    let listing = feed(
        "400",
        vec![
            build("700", C3, false, "pending"),
            build("600", C2, false, "promoted"),
            build("500", C1, false, "promoted"),
            build("400", old, true, "promoted"),
        ],
    );
    // The oldest build after the commit that holds it, not the newest.
    let plan = nearest(C0, &listing, Ok(&descent), vec![]);
    let Plan::Full { build: picked, from, nearest: true } = &plan else {
        panic!("expected the nearest full build, got {plan:?}")
    };
    assert_eq!((picked["build"].as_str(), from.as_str()), (Some("500"), "400"));
    let text = plan_human(&plan, C0, Path::new("/A.app"), None);
    assert!(text.contains("500") && text.contains(&C1[..10]) && text.contains(&C0[..12]), "{text}");
    assert_eq!(plan_json(&plan, C0, Path::new("/A.app"), None)["nearest"], true);

    // A pulled build is passed over for the next one.
    let mut pulled = listing;
    pulled["builds"][2] = build("500", C1, false, "pulled");
    let Plan::Full { build: picked, .. } = nearest(C0, &pulled, Ok(&descent), vec![]) else {
        panic!("expected full")
    };
    assert_eq!(picked["build"], "600");

    // Never a build older than the app's own: that would take away what it runs now.
    let newer_app = feed(
        "600",
        vec![
            build("700", C3, false, "pending"),
            build("600", "0dd1".repeat(10).as_str(), true, "promoted"),
            build("500", C1, false, "promoted"),
        ],
    );
    let Plan::Full { build: picked, .. } = nearest(C0, &newer_app, Ok(&descent), vec![]) else {
        panic!("expected full")
    };
    assert_eq!(picked["build"], "700");

    // The app's own build already contains the commit: nothing to install, and exit 0.
    let have =
        feed("600", vec![build("700", C3, false, "pending"), build("600", C2, true, "promoted")]);
    let plan = nearest(C0, &have, Ok(&descent), vec![]);
    let Plan::Have { build: own } = &plan else { panic!("expected have, got {plan:?}") };
    assert_eq!(own["build"], "600");
    assert_eq!(plan.path(), "current");

    // Further back than GitHub lists: the newest build, which the compare says contains it.
    let truncated = resolve::descent_in(C0, 200, &compare_body("ahead", 900)).unwrap();
    let far = feed(
        "400",
        vec![build("900", &"f".repeat(40), false, "pending"), build("400", old, true, "promoted")],
    );
    let Plan::Full { build: picked, .. } = nearest(C0, &far, Ok(&truncated), vec![]) else {
        panic!("expected full")
    };
    assert_eq!(picked["build"], "900");
}

#[test]
fn app_try_nearest_says_why_when_no_build_contains_the_commit() {
    let old = "0dd0000000000000000000000000000000000000";
    let listing = feed(
        "400",
        vec![build("500", old, false, "promoted"), build("400", old, true, "promoted")],
    );
    // A commit newer than every build (or a PR head that never landed as itself).
    let apart = resolve::descent_in(C0, 200, &compare_body("behind", 0)).unwrap();
    let earlier = vec!["the nightly feed has no build".to_owned()];
    let Plan::None { why } = nearest(C0, &listing, Ok(&apart), earlier) else {
        panic!("expected none")
    };
    assert_eq!(why.len(), 2, "{why:?}");
    assert!(why[1].contains("500") && why[1].contains(&C0[..12]), "{why:?}");
    // GitHub could not answer: the reason says so and nothing is installed.
    let Plan::None { why } = nearest(C0, &listing, Err("rate limited"), vec![]) else {
        panic!("expected none")
    };
    assert!(why[0].contains("rate limited"), "{why:?}");
    // The newest build compared with is the highest number, whatever order the feed lists.
    assert_eq!(super::newest_built(&listing), Some(&old[..10]));
}

// ------------------------------------------------------------------ the Screen Sharing helper

/// The tools no helper-less try may run.
struct NoSigning;

impl Signing for NoSigning {
    fn unpack(&self, _: &Path, _: &Path) -> Result<(), String> {
        panic!("a try without a helper unpacks nothing")
    }
    fn requirement(&self, _: &Path) -> Result<String, String> {
        panic!("a try without a helper reads no requirement")
    }
    fn verify(&self, _: &Path, _: &str) -> Result<(), String> {
        panic!("a try without a helper checks no signature")
    }
}

const HELPER_ID: &str = "com.cmuxterm.app.nightly.screen-sharing";
const HELPER_NAME: &str = "cmux NIGHTLY Helper.app";
/// The same helper in an app built before the rename.
const LEGACY_HELPER_NAME: &str = "cmux NIGHTLY Screen Sharing.app";
/// What `codesign -d -r-` prints for the NIGHTLY's helper, byte for byte (ss-host-helper's ask (a)).
const REQUIREMENT: &str = "identifier \"com.cmuxterm.app.nightly.screen-sharing\" and anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] /* exists */ and certificate leaf[field.1.2.840.113635.100.6.1.13] /* exists */ and certificate leaf[subject.OU] = \"7WLXT3NR37\"";
/// The requirement form without the Developer ID clauses (cmux_signed_bundle::team_requirement).
const SHORT_REQUIREMENT: &str = "identifier \"com.cmuxterm.app.nightly.screen-sharing\" and anchor apple generic and certificate leaf[subject.OU] = \"7WLXT3NR37\"";
const OLD_HELPER: &[u8] = b"old cmux-rd host";
const NEW_HELPER: &[u8] = b"new cmux-rd host, from the try";
const HELPER_ZIP: &[u8] = b"the signed helper's zip";

/// A helper bundle at `bundle`: Info.plist with `id`, the executable, a seal.
fn write_helper(bundle: &Path, id: &str, executable: &[u8]) {
    fs::create_dir_all(bundle.join("Contents/MacOS")).unwrap();
    fs::create_dir_all(bundle.join("Contents/_CodeSignature")).unwrap();
    fs::write(
        bundle.join("Contents/Info.plist"),
        format!(
            "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<plist version=\"1.0\"><dict>\
             <key>CFBundleIdentifier</key><string>{id}</string></dict></plist>\n"
        ),
    )
    .unwrap();
    fs::write(bundle.join("Contents/MacOS").join(helper::EXECUTABLE), executable).unwrap();
    fs::write(
        bundle.join("Contents/_CodeSignature/CodeResources"),
        [b"seal of ", executable].concat(),
    )
    .unwrap();
}

fn installed_helper(app: &Path) -> PathBuf {
    app.join(helper::LIBRARY).join(HELPER_NAME)
}

fn helper_bytes(app: &Path) -> Option<Vec<u8>> {
    fs::read(installed_helper(app).join("Contents/MacOS").join(helper::EXECUTABLE)).ok()
}

/// The fixture with the NIGHTLY's helper installed and the commit's helper zip published; the
/// returned folder holds what the zip unpacks to.
fn helper_fixture() -> (Fixture, PathBuf) {
    let fixture = fixture();
    write_helper(&installed_helper(&fixture.app), HELPER_ID, OLD_HELPER);
    let root = fixture.app.parent().unwrap().to_path_buf();
    fs::write(root.join("files").join(COMMIT).join(helper::ZIP), HELPER_ZIP).unwrap();
    let unpacked = root.join("zip-contents");
    write_helper(&unpacked.join(HELPER_NAME), HELPER_ID, NEW_HELPER);
    (fixture, unpacked)
}

fn helper_key() -> Value {
    json!({
        "url": format!("https://files.cmux.com/cmux-tui/{COMMIT}/{}", helper::ZIP),
        "sha256": sha(HELPER_ZIP), "size": HELPER_ZIP.len(),
        "bundle_id": HELPER_ID, "team": "7WLXT3NR37", "designated_requirement": REQUIREMENT,
    })
}

/// A payload with the helper key (the new CI's shape).
fn payload_with_helper(helper: Value) -> Value {
    let mut value = payload(live::PURPOSE, COMMIT, good_targets());
    value[helper::KEY] = helper;
    value
}

fn found_value(value: &Value) -> Live {
    Live::Found(Box::new(live::verify(&envelope(value), &keys(), COMMIT).unwrap()))
}

/// The real tools stood in for: the zip unpacks to `from`; the installed helper's requirement
/// is REQUIREMENT, and a bundle meets it only when `accepts`.
struct FakeSigning {
    from: PathBuf,
    accepts: bool,
    verified: Cell<u32>,
    /// The installed helper's own requirement.
    installed: &'static str,
}

fn signing(from: PathBuf, accepts: bool) -> FakeSigning {
    FakeSigning { from, accepts, verified: Cell::new(0), installed: REQUIREMENT }
}

impl Signing for FakeSigning {
    fn unpack(&self, zip: &Path, into: &Path) -> Result<(), String> {
        assert_eq!(fs::read(zip).unwrap(), HELPER_ZIP, "only the checked zip is unpacked");
        for entry in fs::read_dir(&self.from).unwrap() {
            let entry = entry.unwrap();
            helper::copy_tree(&entry.path(), &into.join(entry.file_name()))?;
        }
        Ok(())
    }
    fn requirement(&self, bundle: &Path) -> Result<String, String> {
        assert!(
            bundle.ends_with(HELPER_NAME) || bundle.ends_with(LEGACY_HELPER_NAME),
            "the INSTALLED helper's requirement: {bundle:?}"
        );
        Ok(self.installed.to_owned())
    }
    fn verify(&self, bundle: &Path, requirement: &str) -> Result<(), String> {
        self.verified.set(self.verified.get() + 1);
        assert_eq!(requirement, REQUIREMENT);
        assert!(!bundle.starts_with(installed_helper(bundle).parent().unwrap().join(HELPER_NAME)));
        if self.accepts {
            Ok(())
        } else {
            Err("code failed to satisfy specified code requirement(s)".into())
        }
    }
}

fn live_plan(fixture: &Fixture, live: &Live) -> (Vec<live::Wanted>, Option<helper::WantedHelper>) {
    match choose(COMMIT, Some(APP_COMMIT), live, None, &fixture.base) {
        Plan::Live { files, helper, .. } => (files, helper),
        other => panic!("expected the live path, got {other:?}"),
    }
}

/// `LivePayload` as every CLI before the helper key parses it: its fields, no others denied.
#[derive(serde::Deserialize)]
#[allow(dead_code)]
struct OldCliPayload {
    schema: u64,
    purpose: String,
    commit: String,
    #[serde(default)]
    live_from: Vec<String>,
    targets: std::collections::BTreeMap<
        String,
        std::collections::BTreeMap<String, cmux_host::updater::channel::Binary>,
    >,
}

/// The same cases on the old-CLI path and the new one: a payload without the key and one with
/// it parse on both; the old CLI takes the same `bin/` files from each and never reads the key.
#[test]
fn app_try_helper_key_parses_on_the_old_and_the_new_cli() {
    let without = payload(live::PURPOSE, COMMIT, good_targets());
    let with = payload_with_helper(helper_key());
    for (name, value, has) in [("without the key", &without, false), ("with the key", &with, true)]
    {
        let bytes = serde_json::to_vec(value).unwrap();
        // Old CLI: parses, and its `targets` (all it places) are the same either way.
        let old: OldCliPayload = serde_json::from_slice(&bytes).unwrap();
        assert_eq!(old.targets["aarch64-apple-darwin"].len(), 2, "{name}");
        // New CLI: the same verify; the key is there exactly when CI wrote it.
        let new = live::verify(&envelope(value), &keys(), COMMIT).unwrap();
        assert_eq!(new.screen_sharing_helper.is_some(), has, "{name}");
        assert_eq!(live::wanted(&new, "file:///x/").unwrap().len(), live::FILES.len(), "{name}");
    }
}

/// No key (old-CLI shape on the new CLI): the try goes live, and the app's helper stays as it
/// was, with no removal and no refusal.
#[test]
fn app_try_without_the_helper_key_leaves_the_helper_untouched() {
    let (fixture, _) = helper_fixture();
    let (files, helper) = live_plan(&fixture, &found(good_targets()));
    assert!(helper.is_none());
    let daemon = FakeDaemon::new(fixture.app.join(live::BIN).join("cmux"), true);
    let applied = try_live(
        &fixture.app,
        &files,
        helper.as_ref(),
        &fixture.store,
        &daemon,
        &NoSigning,
        &mut Phases::default(),
    )
    .unwrap();
    assert!(applied.changed);
    assert_eq!(read(&fixture.app, "cmux").as_deref(), Some(NEW_CMUX));
    assert_eq!(helper_bytes(&fixture.app).as_deref(), Some(OLD_HELPER));
    assert_eq!(applied.helper_step.as_ref().unwrap()["did"], "untouched");
    assert!(applied.helper_undo.is_none());
}

/// With the key: the bundle is checked against the installed helper's requirement, swapped
/// whole by rename, and `undo` puts the one from before back.
#[test]
fn app_try_with_the_helper_key_swaps_the_bundle_and_undo_restores_it() {
    let (fixture, unpacked) = helper_fixture();
    let (files, helper) = live_plan(&fixture, &found_value(&payload_with_helper(helper_key())));
    let wanted = helper.expect("the plan carries the helper");
    assert_eq!(
        wanted.fetch_url,
        format!("{}{COMMIT}/{}", fixture.base, helper::ZIP),
        "fetched from the commit's own publication"
    );
    let signing = signing(unpacked, true);
    let daemon = FakeDaemon::new(fixture.app.join(live::BIN).join("cmux"), true);
    let applied = try_live(
        &fixture.app,
        &files,
        Some(&wanted),
        &fixture.store,
        &daemon,
        &signing,
        &mut Phases::default(),
    )
    .unwrap();
    assert_eq!(signing.verified.get(), 1);
    assert_eq!(helper_bytes(&fixture.app).as_deref(), Some(NEW_HELPER));
    assert_eq!(read(&fixture.app, "cmux").as_deref(), Some(NEW_CMUX));
    let step = applied.helper_step.clone().unwrap();
    assert_eq!(step["did"], "swapped");
    // Only the one helper sits in Contents/Library: no staging folder is left.
    let names: Vec<_> = fs::read_dir(fixture.app.join(helper::LIBRARY))
        .unwrap()
        .map(|e| e.unwrap().file_name().to_string_lossy().into_owned())
        .collect();
    assert_eq!(names, [HELPER_NAME]);
    fixture
        .store
        .record(&json!({"action": "try", "ok": true, "app": fixture.app.to_string_lossy(), "app_commit": APP_COMMIT,
                        "steps": applied.steps, "undo": {"files": applied.prior, "screen_sharing_helper": applied.helper_undo}}))
        .unwrap();
    let undone = undo_live(&fixture.store, &daemon).unwrap();
    assert!(undone.changed);
    assert_eq!(helper_bytes(&fixture.app).as_deref(), Some(OLD_HELPER));
    assert_eq!(read(&fixture.app, "cmux").as_deref(), Some(OLD_CMUX));
}

/// An app built before the rename holds `<app> Screen Sharing.app`: the try still finds it,
/// swaps in the commit's helper (named `<app> Helper.app` in the zip) under the app's own name,
/// and undo puts the old one back.
#[test]
fn app_try_still_finds_a_helper_named_screen_sharing_and_keeps_its_name() {
    let (fixture, unpacked) = helper_fixture();
    let library = fixture.app.join(helper::LIBRARY);
    fs::remove_dir_all(library.join(HELPER_NAME)).unwrap();
    write_helper(&library.join(LEGACY_HELPER_NAME), HELPER_ID, OLD_HELPER);
    let exe =
        |name: &str| fs::read(library.join(name).join("Contents/MacOS").join(helper::EXECUTABLE));
    let (files, helper) = live_plan(&fixture, &found_value(&payload_with_helper(helper_key())));
    let signing = signing(unpacked, true);
    let daemon = FakeDaemon::new(fixture.app.join(live::BIN).join("cmux"), true);
    let applied = try_live(
        &fixture.app,
        &files,
        helper.as_ref(),
        &fixture.store,
        &daemon,
        &signing,
        &mut Phases::default(),
    )
    .unwrap();
    assert_eq!(applied.helper_step.as_ref().unwrap()["did"], "swapped");
    assert_eq!(exe(LEGACY_HELPER_NAME).unwrap(), NEW_HELPER);
    assert!(!library.join(HELPER_NAME).exists(), "the app keeps its own helper name");
    fixture
        .store
        .record(&json!({"action": "try", "ok": true, "app": fixture.app.to_string_lossy(), "app_commit": APP_COMMIT,
                        "steps": applied.steps, "undo": {"files": applied.prior, "screen_sharing_helper": applied.helper_undo}}))
        .unwrap();
    undo_live(&fixture.store, &daemon).unwrap();
    assert_eq!(exe(LEGACY_HELPER_NAME).unwrap(), OLD_HELPER);
}

/// A bundle that fails the installed helper's requirement is refused before anything changes.
#[test]
fn app_try_refuses_a_helper_failing_the_requirement_and_swaps_nothing() {
    let (fixture, unpacked) = helper_fixture();
    let (files, helper) = live_plan(&fixture, &found_value(&payload_with_helper(helper_key())));
    let signing = signing(unpacked, false);
    let daemon = FakeDaemon::new(fixture.app.join(live::BIN).join("cmux"), true);
    let error = try_live(
        &fixture.app,
        &files,
        helper.as_ref(),
        &fixture.store,
        &daemon,
        &signing,
        &mut Phases::default(),
    )
    .unwrap_err();
    assert!(error.contains("does not meet the installed helper's requirement"), "{error}");
    assert_eq!(helper_bytes(&fixture.app).as_deref(), Some(OLD_HELPER));
    assert_eq!(read(&fixture.app, "cmux").as_deref(), Some(OLD_CMUX));
    assert_eq!(read(&fixture.app, "cmux-holder").as_deref(), Some(OLD_HOLDER));
    assert_eq!(daemon.terminated.get(), 0, "the daemon is never touched");
    let names: Vec<_> = fs::read_dir(fixture.app.join(helper::LIBRARY)).unwrap().collect();
    assert_eq!(names.len(), 1, "no staging folder is left");
}

/// A helper of another bundle id, or an app with none, is left as it is: never removed, never added.
#[test]
fn app_try_leaves_a_helper_it_cannot_match_untouched() {
    let (fixture, unpacked) = helper_fixture();
    let signing = signing(unpacked, true);
    let daemon = FakeDaemon::new(fixture.app.join(live::BIN).join("cmux"), true);
    let mut other = helper_key();
    let other_id = "com.cmuxterm.app.nightly.cmux-next-stable.screen-sharing";
    other["bundle_id"] = json!(other_id);
    other["designated_requirement"] =
        json!(helper::developer_id_requirement(other_id, "7WLXT3NR37"));
    let (files, helper) = live_plan(&fixture, &found_value(&payload_with_helper(other)));
    let applied = try_live(
        &fixture.app,
        &files,
        helper.as_ref(),
        &fixture.store,
        &daemon,
        &signing,
        &mut Phases::default(),
    )
    .unwrap();
    assert_eq!(applied.helper_step.unwrap()["did"], "untouched");
    assert_eq!(helper_bytes(&fixture.app).as_deref(), Some(OLD_HELPER));

    fs::remove_dir_all(installed_helper(&fixture.app)).unwrap();
    let (files, helper) = live_plan(&fixture, &found_value(&payload_with_helper(helper_key())));
    let applied = try_live(
        &fixture.app,
        &files,
        helper.as_ref(),
        &fixture.store,
        &daemon,
        &signing,
        &mut Phases::default(),
    )
    .unwrap();
    assert_eq!(applied.helper_step.unwrap()["did"], "untouched");
    assert!(!installed_helper(&fixture.app).exists(), "no helper is added to an app without one");
    assert_eq!(signing.verified.get(), 0);
}

/// A hand-off that fails after the helper swapped puts the helper back with the files.
#[test]
fn app_try_failed_handoff_puts_the_helper_back_too() {
    let (fixture, unpacked) = helper_fixture();
    let (files, helper) = live_plan(&fixture, &found_value(&payload_with_helper(helper_key())));
    let signing = signing(unpacked, true);
    let daemon = FakeDaemon::new(fixture.app.join(live::BIN).join("cmux"), false);
    let error = try_live(
        &fixture.app,
        &files,
        helper.as_ref(),
        &fixture.store,
        &daemon,
        &signing,
        &mut Phases::default(),
    )
    .unwrap_err();
    assert!(error.contains("the Screen Sharing helper is back as it was"), "{error}");
    assert_eq!(helper_bytes(&fixture.app).as_deref(), Some(OLD_HELPER));
    assert_eq!(read(&fixture.app, "cmux").as_deref(), Some(OLD_CMUX));
}

/// A prior helper the store cannot keep refuses the swap before it starts, so `undo` never
/// meets a try whose old helper is gone (review finding F1 on #47936).
#[test]
fn app_try_refuses_the_swap_when_the_prior_helper_cannot_be_kept() {
    let (fixture, unpacked) = helper_fixture();
    let (files, helper) = live_plan(&fixture, &found_value(&payload_with_helper(helper_key())));
    // A file where the store keeps helpers: create_dir_all under it fails.
    fs::create_dir_all(&fixture.store.root).unwrap();
    fs::write(fixture.store.root.join("helpers"), b"not a folder").unwrap();
    let signing = signing(unpacked, true);
    let daemon = FakeDaemon::new(fixture.app.join(live::BIN).join("cmux"), true);
    let error = try_live(
        &fixture.app,
        &files,
        helper.as_ref(),
        &fixture.store,
        &daemon,
        &signing,
        &mut Phases::default(),
    )
    .unwrap_err();
    assert!(error.contains("the Screen Sharing helper"), "{error}");
    assert_eq!(helper_bytes(&fixture.app).as_deref(), Some(OLD_HELPER));
    assert_eq!(read(&fixture.app, "cmux").as_deref(), Some(OLD_CMUX));
    assert_eq!(daemon.terminated.get(), 0, "the daemon is never touched");
    let names: Vec<_> = fs::read_dir(fixture.app.join(helper::LIBRARY)).unwrap().collect();
    assert_eq!(names.len(), 1, "no staging folder is left");
}

/// The key is checked as the binaries are: the commit's own url, a sha256, a size in range, a
/// helper's bundle id; and a zip entry that would leave its folder is refused.
#[test]
fn app_try_checks_the_helper_key_like_the_binaries() {
    let fixture = fixture();
    let refused = |mutate: &dyn Fn(&mut Value)| {
        let mut key = helper_key();
        mutate(&mut key);
        matches!(
            choose(
                COMMIT,
                Some(APP_COMMIT),
                &found_value(&payload_with_helper(key)),
                None,
                &fixture.base
            ),
            Plan::None { .. }
        )
    };
    assert!(!refused(&|_| {}));
    assert!(refused(
        &|key| key["url"] = json!(format!("https://files.cmux.com/cmux-tui/other/{}", helper::ZIP))
    ));
    assert!(refused(&|key| key["sha256"] = json!("not a sha")));
    assert!(refused(&|key| key["size"] = json!(0)));
    assert!(refused(&|key| key["bundle_id"] = json!("com.cmuxterm.app.nightly")));
    assert!(refused(&|key| key["bundle_id"] = json!("../x.screen-sharing")));
    assert!(
        helper::safe_entries(["cmux NIGHTLY Screen Sharing.app/Contents/Info.plist"].into_iter())
            .is_ok()
    );
    assert!(helper::safe_entries(["../evil"].into_iter()).is_err());
    assert!(helper::safe_entries(["/etc/evil"].into_iter()).is_err());
}

/// ss-host-helper's ask (a): the key's requirement is the Developer ID form, byte for byte, with
/// the intermediate and leaf clauses NIGHTLY's helper carries; a shorter one refuses the plan.
#[test]
fn app_try_helper_key_names_the_full_developer_id_requirement() {
    assert_eq!(helper::developer_id_requirement(HELPER_ID, "7WLXT3NR37"), REQUIREMENT);
    let fixture = fixture();
    for (name, mutate) in [
        ("short requirement", json!({"designated_requirement": SHORT_REQUIREMENT})),
        ("no requirement", json!({"designated_requirement": null})),
        ("another team", json!({"team": "ABCDEFGHIJ"})),
        ("no team", json!({"team": null})),
        ("cdhash", json!({"designated_requirement": "cdhash H\"00\""})),
    ] {
        let mut key = helper_key();
        for (field, value) in mutate.as_object().unwrap() {
            key[field] = value.clone();
        }
        let plan = choose(
            COMMIT,
            Some(APP_COMMIT),
            &found_value(&payload_with_helper(key)),
            None,
            &fixture.base,
        );
        assert!(matches!(plan, Plan::None { .. }), "{name}: {plan:?}");
    }
}

/// Ask (a) on the installed side: an installed helper whose requirement lacks the Developer ID
/// clauses is not the build's identity, so the try is refused and nothing is swapped.
#[test]
fn app_try_refuses_an_installed_helper_of_another_requirement() {
    let (fixture, unpacked) = helper_fixture();
    let (files, helper) = live_plan(&fixture, &found_value(&payload_with_helper(helper_key())));
    let mut signing = signing(unpacked, true);
    signing.installed = SHORT_REQUIREMENT;
    let daemon = FakeDaemon::new(fixture.app.join(live::BIN).join("cmux"), true);
    let error = try_live(
        &fixture.app,
        &files,
        helper.as_ref(),
        &fixture.store,
        &daemon,
        &signing,
        &mut Phases::default(),
    )
    .unwrap_err();
    assert!(error.contains("is not the build's"), "{error}");
    assert_eq!(signing.verified.get(), 0);
    assert_eq!(helper_bytes(&fixture.app).as_deref(), Some(OLD_HELPER));
    assert_eq!(read(&fixture.app, "cmux").as_deref(), Some(OLD_CMUX));
    assert_eq!(daemon.terminated.get(), 0);
}

/// ss-host-helper's ask (b), on both payload shapes: an app holding two Screen Sharing helpers, or
/// cmux Computer Use.app beside one, refuses a try that carries a helper (nothing swapped, no
/// helper picked); a try without the key leaves the helpers alone and still goes live.
#[test]
fn app_try_refuses_two_helpers_or_computer_use_and_swaps_nothing() {
    for extra in ["cmux Screen Sharing.app", live::COMPUTER_USE_APP] {
        // With the key (new CI): refused before anything changes.
        let (fixture, unpacked) = helper_fixture();
        write_helper(&fixture.app.join(helper::LIBRARY).join(extra), HELPER_ID, OLD_HELPER);
        let (files, helper) = live_plan(&fixture, &found_value(&payload_with_helper(helper_key())));
        let signing = signing(unpacked, true);
        let daemon = FakeDaemon::new(fixture.app.join(live::BIN).join("cmux"), true);
        let error = try_live(
            &fixture.app,
            &files,
            helper.as_ref(),
            &fixture.store,
            &daemon,
            &signing,
            &mut Phases::default(),
        )
        .unwrap_err();
        let want = if extra == live::COMPUTER_USE_APP {
            "Computer Use"
        } else {
            "2 Screen Sharing helpers"
        };
        assert!(error.contains(want), "{extra}: {error}");
        assert_eq!(signing.verified.get(), 0, "{extra}");
        assert_eq!(helper_bytes(&fixture.app).as_deref(), Some(OLD_HELPER), "{extra}");
        assert!(fixture.app.join(helper::LIBRARY).join(extra).is_dir(), "{extra}: nothing removed");
        assert_eq!(read(&fixture.app, "cmux").as_deref(), Some(OLD_CMUX), "{extra}");
        assert_eq!(daemon.terminated.get(), 0, "{extra}");

        // Without the key (the old CI's shape): no refusal, the helpers stay, bin/ goes live.
        let (files, helper) = live_plan(&fixture, &found(good_targets()));
        assert!(helper.is_none());
        let applied = try_live(
            &fixture.app,
            &files,
            None,
            &fixture.store,
            &daemon,
            &NoSigning,
            &mut Phases::default(),
        )
        .unwrap();
        assert_eq!(applied.helper_step.unwrap()["did"], "untouched", "{extra}");
        assert_eq!(read(&fixture.app, "cmux").as_deref(), Some(NEW_CMUX), "{extra}");
        assert_eq!(helper_bytes(&fixture.app).as_deref(), Some(OLD_HELPER), "{extra}");
        assert!(fixture.app.join(helper::LIBRARY).join(extra).is_dir(), "{extra}");
    }
}

/// The helper apps the app bundles, read from the bundling scripts (every
/// `scripts/cmux-next/bundle-*.sh` that places a `Contents/Library/<name>.app`): `cmux app try`
/// carries each one live, so a try never leaves a bundled helper on the installed build's code.
#[test]
fn app_try_live_set_covers_every_helper_app_the_app_bundles() {
    let scripts = Path::new(env!("CARGO_MANIFEST_DIR")).join("../../../scripts/cmux-next");
    let mut helpers = Vec::new();
    for entry in fs::read_dir(&scripts).unwrap() {
        let path = entry.unwrap().path();
        let name = path.file_name().unwrap().to_string_lossy().into_owned();
        if !(name.starts_with("bundle-") && name.ends_with(".sh")) {
            continue;
        }
        let text = fs::read_to_string(&path).unwrap();
        // The script's own shell variables (`SUFFIX=" Helper"`), to read its destination.
        let vars: Vec<(String, String)> = text
            .lines()
            .filter_map(|line| {
                let (var, value) = line.trim().split_once('=')?;
                let plain =
                    !var.is_empty() && var.bytes().all(|b| b.is_ascii_uppercase() || b == b'_');
                plain.then(|| (var.to_owned(), value.trim_matches('"').to_owned()))
            })
            .collect();
        for line in text.lines() {
            let line = line.trim();
            let Some(rest) = line.strip_prefix("dest=\"$app/Contents/Library/") else { continue };
            let Some(bundle) = rest.strip_suffix(".app\"") else { continue };
            let mut resolved = bundle.to_owned();
            for (var, value) in &vars {
                resolved = resolved.replace(&format!("${var}"), value);
            }
            helpers.push((name.clone(), format!("{resolved}.app")));
        }
    }
    assert!(
        helpers.iter().any(|(script, _)| script == "bundle-screen-sharing-helper.sh"),
        "the Screen Sharing helper's bundling script was not read: {helpers:?}"
    );
    for (script, bundle) in &helpers {
        // `$name` is the app's name ("cmux NIGHTLY"): the live set's helper is every
        // `<app name> Helper.app` (or the older `<app name> Screen Sharing.app`).
        let covered = bundle.strip_prefix("$name").is_some_and(|tail| helper::is_helper_name(tail));
        assert!(covered, "{script} bundles {bundle}, which `cmux app try` does not carry live");
    }
}

/// A signed file past the app's whole-app floor: live_from stops at COMMIT, daemon_from goes on.
fn past_floor() -> Live {
    let mut body = payload(live::PURPOSE, COMMIT, good_targets());
    body["live_from"] = json!([COMMIT]);
    body.as_object_mut().unwrap().remove("native_from");
    body["daemon_from"] = json!([COMMIT, APP_FULL_COMMIT]);
    Live::Found(Box::new(live::verify(&envelope(&body), &keys(), COMMIT).unwrap()))
}

#[test]
fn app_try_sha_takes_the_daemon_past_a_web_or_swift_floor_and_never_claims_the_whole_app() {
    // Fix list item 1: a webviews .ts or Swift change after the app's build set live_from's floor, so
    // `cmux app try SHA` took only an app built from SHA. The daemon ABI floor (daemon_from) decides now.
    let fixture = fixture();
    let plan = choose(COMMIT, Some(APP_COMMIT), &past_floor(), None, &fixture.base);
    let Plan::Live { files, scope: Scope::Daemon(left), .. } = &plan else {
        panic!("expected daemon-only live, got {plan:?}")
    };
    assert!(files.iter().any(|w| w.file == "cmux" && w.binary.is_some()));
    assert_eq!(left.len(), 1, "{left:?}");
    assert!(left[0].contains(APP_COMMIT) && left[0].contains(&COMMIT[..12]), "{left:?}");
    assert!(left[0].contains("Swift"), "{left:?}");

    let planned = plan_json(&plan, COMMIT, &fixture.app, Some(APP_COMMIT));
    assert_eq!(
        (planned["path"].as_str(), planned["scope"].as_str()),
        (Some("live"), Some("daemon"))
    );
    assert_eq!(planned["left_out"].as_array().map(Vec::len), Some(1));
    let human = plan_human(&plan, COMMIT, &fixture.app, Some(APP_COMMIT));
    assert!(human.contains("daemon only") && human.contains("Swift left out:"), "{human}");
    assert!(human.contains("is not at"), "{human}");

    // A whole-app plan says neither.
    let whole = choose(COMMIT, Some(APP_COMMIT), &found(good_targets()), None, &fixture.base);
    assert!(matches!(whole, Plan::Live { scope: Scope::Whole, .. }), "{whole:?}");
    let planned = plan_json(&whole, COMMIT, &fixture.app, Some(APP_COMMIT));
    assert_eq!(planned["scope"], "whole");
    assert_eq!(planned["left_out"], json!([]));
    assert!(!plan_human(&whole, COMMIT, &fixture.app, Some(APP_COMMIT)).contains("daemon only"));

    // Below the daemon ABI floor it is still refused, naming daemon_from.
    let plan = choose(COMMIT, Some("fedcba9"), &past_floor(), None, &fixture.base);
    let Plan::None { why } = plan else { panic!("expected none, got {plan:?}") };
    assert!(why[0].contains("daemon_from"), "{why:?}");
}

#[test]
fn app_try_sha_daemon_only_swap_receipt_says_daemon_only_and_undo_restores() {
    let fixture = fixture();
    let plan = choose(COMMIT, Some(APP_COMMIT), &past_floor(), None, &fixture.base);
    let Plan::Live { files, scope, .. } = plan else { panic!("expected live") };
    let daemon = FakeDaemon::new(fixture.app.join(live::BIN).join("cmux"), true);
    let mut phases = Phases::default();
    let result =
        try_live(&fixture.app, &files, None, &fixture.store, &daemon, &NoSigning, &mut phases);
    let receipt = json!({
        "schema": 1, "action": "try", "target": COMMIT, "commit": COMMIT, "path": "live",
        "app": fixture.app.to_string_lossy(), "app_commit": APP_COMMIT,
        "scope": scope.name(), "left_out": scope.left_out(),
    });
    let global =
        super::GlobalArgs { output: super::OutputMode::Json, ..super::GlobalArgs::default() };
    let code = finish(
        &global,
        &fixture.store,
        receipt,
        result,
        phases,
        std::time::Instant::now(),
        COMMIT,
        &fixture.app,
        None,
    );
    assert_eq!(code, 0);
    assert_eq!(read(&fixture.app, "cmux").as_deref(), Some(NEW_CMUX));
    let last = fixture.store.last().unwrap();
    assert_eq!((last["scope"].as_str(), last["ok"].as_bool()), (Some("daemon"), Some(true)));
    assert!(last["left_out"][0].as_str().unwrap().contains("Swift"), "{last}");
    assert_eq!(super::receipt_left_out(&last).as_deref(), last["left_out"][0].as_str());
    // The daemon-only try undoes as any live try does.
    undo_live(&fixture.store, &daemon).unwrap();
    assert_eq!(read(&fixture.app, "cmux").as_deref(), Some(OLD_CMUX));
}

#[test]
fn app_try_sha_from_a_file_before_daemon_from_says_so() {
    // An older mac-live.json has no daemon_from: live_from stands in, and the reason says so.
    let fixture = fixture();
    let mut legacy = payload(live::PURPOSE, COMMIT, good_targets());
    legacy.as_object_mut().unwrap().remove("native_from");
    let live = Live::Found(Box::new(live::verify(&envelope(&legacy), &keys(), COMMIT).unwrap()));
    let plan = choose(COMMIT, Some(APP_COMMIT), &live, None, &fixture.base);
    let Plan::Live { scope: Scope::Daemon(left), .. } = &plan else {
        panic!("expected daemon-only live, got {plan:?}")
    };
    assert!(left.iter().any(|reason| reason.contains("predates daemon_from")), "{left:?}");
}

#[path = "cu_upgrade_tests.rs"]
mod cu_upgrade_tests;

const TREE: &str = "cccccccccccccccccccccccccccccccccccccccc";
const SIGNED_CMUX: &[u8] = b"new cmux, Team-signed, longer still";
const SIGNED_HOST: &[u8] = b"new app host, Team-signed";

/// The tree's Team-signed set beside the fixture's files (cmux_tui_team_sign.py's layout), each
/// file named by the sha256 of the ad-hoc build it signs.
fn team_set(fixture: &Fixture) -> Value {
    let root = fixture.base.strip_prefix("file://").unwrap();
    let mut files = serde_json::Map::new();
    for (file, unsigned, signed) in
        [("cmux", NEW_CMUX, SIGNED_CMUX), ("cmux-app-host", NEW_HOST, SIGNED_HOST)]
    {
        let dir = Path::new(root).join(format!("tree/{TREE}/team-signed/{}", sha(signed)));
        fs::create_dir_all(&dir).unwrap();
        fs::write(dir.join(file), signed).unwrap();
        files.insert(
            file.to_owned(),
            json!({"sha256": sha(signed), "size": signed.len(), "unsigned_sha256": sha(unsigned)}),
        );
    }
    json!({"schema": 1, "key": TREE, "target": "aarch64-apple-darwin", "team": "7WLXT3NR37", "files": files})
}

#[test]
fn a_team_signed_app_takes_the_trees_team_signed_set_bound_by_the_unsigned_sha256() {
    let fixture = fixture();
    let completion = team_set(&fixture);
    let files = live_files(&fixture, &found(good_targets()));
    let signed = live::team_signed(files.clone(), TREE, &completion, &fixture.base).unwrap();
    let cmux = signed.iter().find(|wanted| wanted.file == "cmux").unwrap();
    let binary = cmux.binary.as_ref().unwrap();
    assert_eq!(binary.sha256, sha(SIGNED_CMUX));
    assert_eq!(
        binary.url,
        format!(
            "https://files.cmux.com/cmux-tui/tree/{TREE}/team-signed/{}/cmux",
            sha(SIGNED_CMUX)
        )
    );
    // A file the build lacks stays absent (the app's goes, as before).
    assert!(signed.iter().any(|wanted| wanted.file == "cmux-holder" && wanted.binary.is_none()));
    let daemon = FakeDaemon::new(fixture.app.join(live::BIN).join("cmux"), true);
    let checked = Cell::new(0);
    let applied = try_live_checked(
        &fixture.app,
        &signed,
        None,
        &fixture.store,
        &daemon,
        &NoSigning,
        &mut Phases::default(),
        &|_| {
            checked.set(checked.get() + 1);
            Ok(())
        },
    )
    .unwrap();
    assert!(applied.changed);
    assert_eq!(checked.get(), 2, "every fetched file passes the Team ID check");
    assert_eq!(read(&fixture.app, "cmux").as_deref(), Some(SIGNED_CMUX));
    assert_eq!(read(&fixture.app, "cmux-app-host").as_deref(), Some(SIGNED_HOST));

    // A set signed from other bytes, of another tree, or missing a file refuses the whole set.
    let mut other = completion.clone();
    other["files"]["cmux-app-host"]["unsigned_sha256"] = json!(sha(b"other build"));
    assert!(live::team_signed(files.clone(), TREE, &other, &fixture.base).is_err());
    assert!(live::team_signed(files.clone(), &"d".repeat(40), &completion, &fixture.base).is_err());
    let mut missing = completion.clone();
    missing["files"].as_object_mut().unwrap().remove("cmux");
    assert!(live::team_signed(files.clone(), TREE, &missing, &fixture.base).is_err());
    let mut null = completion;
    null["files"]["cmux"] = Value::Null;
    assert!(live::team_signed(files, TREE, &null, &fixture.base).is_err());
}

#[test]
fn a_file_failing_the_team_check_changes_nothing() {
    let fixture = fixture();
    let completion = team_set(&fixture);
    let files = live_files(&fixture, &found(good_targets()));
    let signed = live::team_signed(files, TREE, &completion, &fixture.base).unwrap();
    let daemon = FakeDaemon::new(fixture.app.join(live::BIN).join("cmux"), true);
    let error = try_live_checked(
        &fixture.app,
        &signed,
        None,
        &fixture.store,
        &daemon,
        &NoSigning,
        &mut Phases::default(),
        &|path| Err(format!("{}: not signed by this app's team", path.display())),
    )
    .unwrap_err();
    assert!(error.contains("not signed by this app's team"), "{error}");
    assert_eq!(read(&fixture.app, "cmux").as_deref(), Some(OLD_CMUX));
    assert_eq!(daemon.terminated.get(), 0, "the daemon is never touched");
}

// ------------------------------------------------------------------ the app-build path (app_build.rs)

fn app_payload(commit: &str) -> Value {
    json!({
        "schema": 1, "purpose": app_build::PURPOSE, "commit": commit, "configuration": "release",
        "arch": "arm64",
        "app": { "url": app_build::zip_url(commit), "sha256": sha(b"zip"), "size": 3 },
        "run_id": "123",
    })
}

#[test]
fn app_payload_verifies_only_its_own_commit_and_zip() {
    let good = app_build::verify(&envelope(&app_payload(COMMIT)), &keys(), COMMIT).unwrap();
    assert_eq!(good.app.sha256, sha(b"zip"));
    assert_eq!(good.run_id, "123");
    let other = "f".repeat(40);
    assert!(app_build::verify(&envelope(&app_payload(&other)), &keys(), COMMIT).is_err());
    let mut wrong = app_payload(COMMIT);
    wrong["purpose"] = json!("cmux-mac-live-update");
    assert!(app_build::verify(&envelope(&wrong), &keys(), COMMIT).is_err());
    let mut elsewhere = app_payload(COMMIT);
    elsewhere["app"]["url"] = json!("https://example.com/cmux.zip");
    assert!(app_build::verify(&envelope(&elsewhere), &keys(), COMMIT).is_err());
    let mut huge = app_payload(COMMIT);
    huge["app"]["size"] = json!(app_build::ZIP_MAX_BYTES + 1);
    assert!(app_build::verify(&envelope(&huge), &keys(), COMMIT).is_err());
    let mut bad_sha = app_payload(COMMIT);
    bad_sha["app"]["sha256"] = json!("not-a-sha");
    assert!(app_build::verify(&envelope(&bad_sha), &keys(), COMMIT).is_err());
    // Unsigned bytes are refused before anything reads them.
    assert!(
        app_build::verify(app_payload(COMMIT).to_string().as_bytes(), &keys(), COMMIT).is_err()
    );
}

#[test]
fn app_payload_reads_from_the_files_base() {
    let dir = tempfile::tempdir().unwrap();
    let base = format!("file://{}/", dir.path().display());
    assert_eq!(app_build::read(COMMIT, &base), Ok(None));
    fs::create_dir_all(dir.path().join(COMMIT)).unwrap();
    fs::write(dir.path().join(COMMIT).join("mac-app.json"), b"{}").unwrap();
    assert!(app_build::read(COMMIT, &base).is_err());
}

#[test]
fn reidentified_takes_the_apps_identity_and_keeps_the_builds_code() {
    let mut build = plist::Dictionary::new();
    build.insert("CFBundleIdentifier".into(), "com.cmuxterm.app.debug.pr".into());
    build.insert("CFBundleExecutable".into(), "cmux".into());
    build.insert("CMUXCommit".into(), "0123456789ab".into());
    build.insert("SUFeedURL".into(), "https://example.com/pr.xml".into());
    build.insert("CMUXInPlaceTry".into(), "stale".into());
    let mut app = plist::Dictionary::new();
    app.insert("CFBundleIdentifier".into(), "com.cmuxterm.app.nightly".into());
    app.insert("CFBundleName".into(), "cmux NIGHTLY".into());
    app.insert("CMUXCommit".into(), "89abcdef0123".into());
    app.insert("SUFeedURL".into(), "https://example.com/nightly.xml".into());
    app.insert("CMUXIrohRelay".into(), "relay".into());
    let mut marker = plist::Dictionary::new();
    marker.insert("commit".into(), COMMIT.into());
    let out = app_build::reidentified(&build, &app, marker);
    let get = |key: &str| out.get(key).and_then(plist::Value::as_string);
    assert_eq!(get("CFBundleIdentifier"), Some("com.cmuxterm.app.nightly"));
    assert_eq!(get("CFBundleName"), Some("cmux NIGHTLY"));
    assert_eq!(get("SUFeedURL"), Some("https://example.com/nightly.xml"));
    assert_eq!(get("CMUXIrohRelay"), Some("relay"));
    // The build's own code and commit stay its own.
    assert_eq!(get("CFBundleExecutable"), Some("cmux"));
    assert_eq!(get("CMUXCommit"), Some("0123456789ab"));
    let marker = out.get(app_build::MARKER).and_then(plist::Value::as_dictionary).unwrap();
    assert_eq!(marker.get("commit").and_then(plist::Value::as_string), Some(COMMIT));
}

#[test]
fn app_build_commit_and_process_checks() {
    assert!(app_build::commit_matches(Some("0123456789ab"), COMMIT));
    assert!(app_build::commit_matches(Some(COMMIT), COMMIT));
    assert!(!app_build::commit_matches(Some("012345"), COMMIT));
    assert!(!app_build::commit_matches(Some("fedcba987654"), COMMIT));
    assert!(!app_build::commit_matches(None, COMMIT));
    // Nothing answers on a socket that is not there: the app is not running.
    assert_eq!(app_build::identify(Path::new("/nonexistent/cmux.sock"), Path::new("/A.app")), None);
    assert!(app_build::identity_key("SUPublicEDKey"));
    assert!(app_build::identity_key("CMUX_IROH_RELAY"));
    assert!(!app_build::identity_key("CMUXCommit"));
    assert!(!app_build::identity_key("CFBundleExecutable"));
}

#[test]
fn app_build_plan_path_and_swap_word() {
    let payload = app_build::verify(&envelope(&app_payload(COMMIT)), &keys(), COMMIT).unwrap();
    let plan = Plan::App { payload: Box::new(payload) };
    assert_eq!(plan.path(), "app");
    let value = plan_json(&plan, COMMIT, Path::new("/A.app"), Some(APP_COMMIT));
    assert_eq!(value["path"], "app");
    assert_eq!(value["sha256"], json!(sha(b"zip")));
    assert_eq!(
        parse(&words(&[app_build::SWAP_VERB, "/tmp/swap.json"])).unwrap(),
        Command::Swap { spec: PathBuf::from("/tmp/swap.json") }
    );
    assert!(parse(&words(&[app_build::SWAP_VERB, "/tmp/swap.json", "--dry-run"])).is_err());
}

#[test]
fn app_build_undo_after_an_update_drops_the_kept_original() {
    let dir = tempfile::tempdir().unwrap();
    let store = Store { root: dir.path().join("store") };
    let app = dir.path().join("cmux NIGHTLY.app");
    fs::create_dir_all(app.join("Contents")).unwrap();
    plist::Value::Dictionary(plist::Dictionary::new())
        .to_file_xml(app.join("Contents/Info.plist"))
        .unwrap();
    let original = app_build::original_path(&store, &app);
    fs::create_dir_all(&original).unwrap();
    assert!(!app_build::is_try(&app));
    let last = json!({ "action": "try", "ok": true, "path": "app", "commit": COMMIT, "app": app.to_string_lossy(), "original": original.to_string_lossy() });
    store.record(&last).unwrap();
    let global = super::GlobalArgs::default();
    assert_eq!(super::undo_app(&global, &store, &last, COMMIT, &app, false), 0);
    assert!(!original.exists());
    assert_eq!(store.last().unwrap()["action"], "undo");
}
