//! CLI parsing, exit codes and the install / status / upgrade / rollback /
//! pin / uninstall flow against a recorded service manager and an
//! in-memory channel.

mod common;

use std::process::ExitCode;

use cmux_server::cli::{Context, dispatch, parse, run_with};
use cmux_server::error::ExitKind;
use cmux_server::process::RecordingRunner;
use common::*;

fn words(s: &str) -> Vec<String> {
    s.split_whitespace().map(str::to_owned).collect()
}

#[test]
fn parses_verbs_flags_and_the_server_prefix() {
    let a = parse(&words("server db archive-wal pg_wal/0001 0001")).unwrap();
    assert_eq!(a.verb, ["db", "archive-wal"]);
    assert_eq!(a.positionals, ["pg_wal/0001", "0001"]);
    let a = parse(&words("install --version 1.2.3 --system --json --idempotency-key k1")).unwrap();
    assert_eq!(a.verb, ["install"]);
    assert_eq!(a.value("version"), Some("1.2.3"));
    assert!(a.has("system") && a.json);
    assert_eq!(a.idempotency_key.as_deref(), Some("k1"));
    let a = parse(&words("uninstall --purge --no-backup")).unwrap();
    assert!(a.has("purge") && a.has("no-backup"));
    let a = parse(&words("rollback --generation=7")).unwrap();
    assert_eq!(a.number("generation").unwrap(), Some(7));
    let a = parse(&words("db create cmux/tasks --mode schema")).unwrap();
    assert_eq!((a.positionals[0].as_str(), a.value("mode")), ("cmux/tasks", Some("schema")));
    assert!(parse(&words("pin")).unwrap().positionals.is_empty());
    assert!(parse(&[]).unwrap().help);
    assert!(parse(&words("--help")).unwrap().help);
}

#[test]
fn usage_errors_exit_2() {
    for bad in [
        "frobnicate",
        "install --bogus",
        "install --version",
        "uninstall --purge=yes",
        "db url",
        "db archive-wal one",
        "db url a b",
        "pin 1.0.0 2.0.0",
    ] {
        let err = parse(&words(bad)).unwrap_err();
        assert_eq!(err.kind, ExitKind::Usage, "{bad}: {err}");
    }
    let rollback = parse(&words("rollback --generation seven")).unwrap();
    assert_eq!(rollback.number("generation").unwrap_err().kind, ExitKind::Usage);
}

struct Env {
    tmp: tempfile::TempDir,
    runner: RecordingRunner,
    fetcher: MapFetcher,
    signer: Signer,
}

impl Env {
    fn new() -> Env {
        Env {
            tmp: tempfile::tempdir().unwrap(),
            runner: RecordingRunner::new(),
            fetcher: MapFetcher::default(),
            signer: Signer::new(3),
        }
    }

    fn ctx(&self) -> Context<'_> {
        Context {
            runner: &self.runner,
            fetcher: Some(&self.fetcher),
            keys: vec![self.signer.key("current")],
            running_cmux: "1.0.0".to_owned(),
            env: env_for(self.tmp.path()),
            now_ms: NOW_MS,
        }
    }

    fn run(&self, line: &str) -> cmux_server::Result<serde_json::Value> {
        dispatch(&self.ctx(), &parse(&words(line))?).map(|o| o.json)
    }

    /// Publishes `latest.json` (and `v/<version>.json`) on the test channel.
    fn publish(&self, sequence: u64, version: &'static str) {
        let pkg = Pkg { name: "cmux", version, archive: bin_package("cmux", version.as_bytes()) };
        self.fetcher.serve(&pkg);
        let m = manifest(sequence, "2027-01-01T00:00:00Z", "1.0.0", &[&pkg]);
        let sig = self.signer.sign(&m);
        for path in ["latest.json".to_owned(), format!("v/{version}.json")] {
            let url = format!("https://chan.example.test/stable/{path}");
            self.fetcher.put(&url, m.clone());
            self.fetcher.put(&format!("{url}.sig"), sig.clone());
        }
    }
}

const CHAN: &str = "--channel-url https://chan.example.test";

#[test]
fn install_status_upgrade_rollback_pin_uninstall() {
    if cmux_server::sys::is_root() {
        eprintln!("skipped: user-mode install refuses root");
        return;
    }
    let env = Env::new();
    env.publish(1, "1.0.0");
    let out = env.run(&format!("install {CHAN}")).unwrap();
    assert_eq!(out["generation"], 1);
    assert_eq!(out["changed"], true);
    assert_eq!(out["mode"], "user");
    // Idempotent rerun.
    let out = env.run(&format!("install {CHAN}")).unwrap();
    assert_eq!(out["changed"], false, "{out}");
    let status = env.run("status").unwrap();
    assert_eq!(status["store"]["generation"], 1);
    assert_eq!(status["store"]["version"], "1.0.0");
    assert_eq!(status["store"]["channel"], "stable");

    env.publish(2, "1.1.0");
    let up = env.run(&format!("upgrade {CHAN}")).unwrap();
    assert_eq!((up["from"].as_u64(), up["to"].as_u64()), (Some(1), Some(2)));
    let back = env.run("rollback").unwrap();
    assert_eq!((back["from"].as_u64(), back["to"].as_u64()), (Some(2), Some(1)));
    let fwd = env.run("upgrade --generation 2").unwrap();
    assert_eq!(fwd["to"], 2);
    assert_eq!(env.run("upgrade --generation 9").unwrap_err().kind, ExitKind::NotFound);

    // Pinning selects v/<version>.json; the older pinned manifest is a
    // downgrade and is refused (exit 7).
    assert_eq!(env.run("pin 1.0.0").unwrap()["pinned"], "1.0.0");
    assert_eq!(env.run("status").unwrap()["store"]["pinned"], "1.0.0");
    assert_eq!(env.run(&format!("upgrade {CHAN}")).unwrap_err().kind, ExitKind::Verification);
    assert!(env.run("pin --clear").unwrap()["pinned"].is_null());

    let out = env.run("uninstall").unwrap();
    let kept = out["kept_state"].as_str().unwrap().to_owned();
    assert!(std::path::Path::new(&kept).join("updater.json").is_file());
    assert_eq!(env.run("status").unwrap()["store"]["generation"], serde_json::Value::Null);
    // Purge removes the state too (no cluster, so no final backup).
    env.run("uninstall --purge").unwrap();
    assert!(!std::path::Path::new(&kept).exists());
}

#[test]
fn verbs_map_failures_to_exit_codes() {
    let env = Env::new();
    // Nothing installed.
    assert_eq!(env.run("rollback").unwrap_err().kind, ExitKind::NotFound);
    // No Postgres binaries in the store and none given.
    assert_eq!(env.run("db url notes").unwrap_err().kind, ExitKind::NotFound);
    assert_eq!(env.run("db create Bad-Id").unwrap_err().kind, ExitKind::Usage);
    // A manifest that is not on the channel.
    if !cmux_server::sys::is_root() {
        assert_eq!(env.run(&format!("install {CHAN}")).unwrap_err().kind, ExitKind::NotFound);
    }
    // No release keys: every manifest is refused with exit 7.
    let mut ctx = env.ctx();
    ctx.keys.clear();
    let code = run_with(&ctx, &words(&format!("install {CHAN}")));
    let expected =
        if cmux_server::sys::is_root() { ExitKind::Rejected } else { ExitKind::Verification };
    assert_eq!(code, ExitCode::from(expected.code()));
    assert_eq!(run_with(&ctx, &words("nope")), ExitCode::from(2));
    // --system without root never escalates.
    if !cmux_server::sys::is_root() {
        assert_eq!(env.run("install --system").unwrap_err().kind, ExitKind::Rejected);
    }
}

#[test]
fn archive_wal_verb_copies_into_the_layout() {
    let env = Env::new();
    let src = env.tmp.path().join("seg");
    std::fs::write(&src, b"wal").unwrap();
    let wal = env.tmp.path().join("wal");
    std::fs::create_dir(&wal).unwrap();
    // The verb reads CMUX_SERVER_WAL_DIR when Postgres runs it; without
    // it, the layout's `<state>/backups/wal`.
    let state_wal = cmux_server::fsx::local(
        &layout_at(env.tmp.path(), cmux_server::host::platform()).wal_archive(),
    );
    std::fs::create_dir_all(&state_wal).unwrap();
    if std::env::var_os("CMUX_SERVER_WAL_DIR").is_none() {
        let out =
            env.run(&format!("db archive-wal {} 000000010000000000000001", src.display())).unwrap();
        assert_eq!(out["stored"], true);
        assert!(state_wal.join("000000010000000000000001").is_file());
    }
}
