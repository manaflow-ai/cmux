//! CLI parsing, exit codes and the install / status / upgrade / rollback /
//! pin / uninstall flow against a recorded service manager and an
//! in-memory channel.

mod common;

use std::process::ExitCode;

use cmux_server::cli::{Context, dispatch, parse, run_with};
use cmux_server::error::ExitKind;
use cmux_server::exec::RecordingExec;
use cmux_server::host;
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
    exec: RecordingExec,
    signer: Signer,
    guard: Option<String>,
}

impl Env {
    fn new() -> Env {
        Env {
            tmp: tempfile::tempdir().unwrap(),
            runner: RecordingRunner::new(),
            fetcher: MapFetcher::default(),
            exec: RecordingExec::default(),
            signer: Signer::new(3),
            guard: None,
        }
    }

    fn ctx(&self) -> Context<'_> {
        Context {
            runner: &self.runner,
            fetcher: Some(&self.fetcher),
            exec: &self.exec,
            keys: vec![self.signer.key("current")],
            running_cmux: "1.0.0".to_owned(),
            reexec_guard: self.guard.clone(),
            env: env_for(self.tmp.path()),
            now_ms: NOW_MS,
        }
    }

    fn run(&self, line: &str) -> cmux_server::Result<serde_json::Value> {
        dispatch(&self.ctx(), &parse(&words(line))?).map(|o| o.json)
    }

    /// Publishes `latest.json` (and `v/<version>.json`) on the test channel.
    fn publish(&self, sequence: u64, version: &'static str) {
        self.publish_needing(sequence, version, "1.0.0");
    }

    /// Like [`Env::publish`] with a `min_cmux_version`. Returns the
    /// `cmux` package.
    fn publish_needing(&self, sequence: u64, version: &'static str, min_cmux: &str) -> Pkg {
        let archive = files_package(&[("cmux", format!("cmux {version}").as_bytes())]);
        self.publish_archive(sequence, version, min_cmux, archive)
    }

    /// Publishes one `cmux` package with `archive`.
    fn publish_archive(
        &self,
        sequence: u64,
        version: &'static str,
        min_cmux: &str,
        archive: Vec<u8>,
    ) -> Pkg {
        let pkg = Pkg { name: "cmux", version, archive };
        self.fetcher.serve(&pkg);
        let m = manifest(sequence, "2027-01-01T00:00:00Z", min_cmux, &[&pkg]);
        let sig = self.signer.sign(&m);
        for path in ["latest.json".to_owned(), format!("v/{version}.json")] {
            let url = format!("https://chan.example.test/stable/{}/{path}", host::TARGET);
            self.fetcher.put(&url, m.clone());
            self.fetcher.put(&format!("{url}.sig"), sig.clone());
        }
        pkg
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
    let state_wal =
        cmux_server::fsx::local(&layout_at(env.tmp.path(), host::platform()).wal_archive());
    std::fs::create_dir_all(&state_wal).unwrap();
    if std::env::var_os("CMUX_SERVER_WAL_DIR").is_none() {
        let out =
            env.run(&format!("db archive-wal {} 000000010000000000000001", src.display())).unwrap();
        assert_eq!(out["stored"], true);
        assert!(state_wal.join("000000010000000000000001").is_file());
    }
}

#[test]
fn postgres_is_refused_in_system_mode() {
    use cmux_server::config::ServerConfig;
    use cmux_server::pg::{PgOptions, Postgres};
    use cmux_server_core::layout::layout;
    use cmux_server_core::{InstallMode, Platform};
    let tmp = tempfile::tempdir().unwrap();
    let system = layout(InstallMode::System, Platform::Linux, &Default::default()).unwrap();
    let mut cfg = ServerConfig::load(&tmp.path().join("server.json")).unwrap();
    let runner = RecordingRunner::new();
    let opts = PgOptions { pg_bin: Some(tmp.path().to_path_buf()), cmux_bin: None };
    let err = Postgres::open(&system, &runner, &mut cfg, &opts).err().unwrap();
    assert_eq!(err.kind, ExitKind::Rejected, "{err}");
    assert!(runner.commands().is_empty(), "no initdb or pg_ctl ran");
    assert!(!tmp.path().join("server.json").exists());
}

#[test]
fn purge_refuses_a_live_postmaster_it_cannot_stop() {
    if cmux_server::sys::is_root() {
        return;
    }
    let env = Env::new();
    env.publish(1, "1.0.0");
    env.run(&format!("install {CHAN}")).unwrap();
    let layout = layout_at(env.tmp.path(), host::platform());
    let data = cmux_server::fsx::local(&layout.postgres_data());
    std::fs::create_dir_all(&data).unwrap();
    std::fs::write(data.join("PG_VERSION"), "17\n").unwrap();
    // A live process (this test) in postmaster.pid, and no Postgres
    // binaries in the store or on the command line.
    std::fs::write(data.join("postmaster.pid"), format!("{}\n", std::process::id())).unwrap();
    let err = env.run("uninstall --purge --no-backup").unwrap_err();
    assert_eq!(err.kind, ExitKind::Rejected, "{err}");
    assert!(err.message.contains("cannot stop it"), "{err}");
    let store = cmux_server::store::Store::new(&layout);
    assert_eq!(store.current_generation(), Some(1), "nothing was removed");
    // Without --purge the data stays, so uninstall goes on and warns.
    let out = env.run("uninstall").unwrap();
    assert!(out["warnings"][0].as_str().unwrap().contains("left running"), "{out}");
    assert!(data.join("PG_VERSION").is_file());
}

#[test]
fn install_refuses_an_invalid_channel_before_writing_config() {
    if cmux_server::sys::is_root() {
        return;
    }
    let env = Env::new();
    let err = env.run(&format!("install --channel Beta {CHAN}")).unwrap_err();
    assert_eq!(err.kind, ExitKind::Usage);
    let layout = layout_at(env.tmp.path(), host::platform());
    assert!(!std::path::Path::new(layout.config_file.as_str()).exists());
}

#[test]
fn read_verbs_write_no_config() {
    let env = Env::new();
    // Binaries exist, so only the missing install id and port stop it.
    let bin = env.tmp.path().join("pgbin");
    std::fs::create_dir_all(&bin).unwrap();
    std::fs::write(bin.join("initdb"), "").unwrap();
    let err = env.run(&format!("db url notes --pg-bin {}", bin.display())).unwrap_err();
    assert_eq!(err.kind, ExitKind::NotFound, "{err}");
    env.run("status").unwrap();
    let layout = layout_at(env.tmp.path(), host::platform());
    let config = std::path::Path::new(layout.config_file.as_str());
    assert!(!config.exists(), "db url and status wrote {}", config.display());
    assert!(!std::path::Path::new(layout.state.as_str()).exists(), "no state was created");
}

#[test]
fn a_manifest_needing_newer_cmux_reexecs_once_into_the_verified_package() {
    // Decision SV-R2.
    if cmux_server::sys::is_root() {
        return;
    }
    let env = Env::new();
    env.publish(1, "1.0.0");
    env.run(&format!("install {CHAN}")).unwrap();
    let pkg = env.publish_needing(2, "9.0.0", "9.0.0");
    // Global flags before the noun: the argv comes from the parse result.
    let err = env.run(&format!("--json server upgrade {CHAN}")).unwrap_err();
    assert!(err.message.contains("recorded"), "the exec ran: {err}");
    let requests = env.exec.requests();
    assert_eq!(requests.len(), 1);
    let request = &requests[0];
    let layout = layout_at(env.tmp.path(), host::platform());
    let package = std::path::Path::new(layout.store.as_str()).join(sha_hex(&pkg.archive));
    assert_eq!(request.program, std::fs::canonicalize(package.join("bin/cmux")).unwrap());
    assert_eq!(std::fs::read(&request.program).unwrap(), b"cmux 9.0.0", "the staged binary");
    assert_eq!(
        request.args,
        words("server upgrade --channel-url=https://chan.example.test --json"),
        "the same verb and flags under the `server` noun"
    );
    assert_eq!(request.env.len(), 1);
    assert_eq!(request.env[0].0, "CMUX_SERVER_REEXEC");
    assert!(request.env[0].1.starts_with("2:"), "the marker names sequence 2: {:?}", request.env);
    // The argv parses back to the same verb (`parse` skips `server`).
    let back = parse(&request.args).unwrap();
    assert_eq!((back.verb_str(), back.json), ("upgrade".to_owned(), true));
    let store = cmux_server::store::Store::new(&layout);
    assert_eq!(store.current_generation(), Some(1), "this binary applied nothing");
    assert_eq!(store.last_applied().unwrap().map(|a| a.sequence), Some(1));

    // The re-exec'd process (guard set) that is still too old refuses with
    // the "needs newer cmux" exit and never execs again.
    let mut again = Env::new();
    again.tmp = env.tmp;
    again.guard = Some(request.env[0].1.clone());
    again.publish_needing(2, "9.0.0", "9.0.0");
    let err = again.run(&format!("upgrade {CHAN}")).unwrap_err();
    assert_eq!(err.kind, ExitKind::Rejected, "{err}");
    assert!(err.message.contains("already re-executed once"), "{err}");
    assert!(again.exec.requests().is_empty(), "no second exec");
}

#[test]
fn a_package_without_the_cmux_binary_is_refused_and_nothing_runs() {
    if cmux_server::sys::is_root() {
        return;
    }
    let env = Env::new();
    env.publish_archive(1, "9.0.0", "9.0.0", files_package(&[("other", b"not cmux")]));
    let err = env.run(&format!("install {CHAN}")).unwrap_err();
    assert_eq!(err.kind, ExitKind::Rejected, "{err}");
    assert!(err.message.contains("bin/cmux"), "{err}");
    assert!(env.exec.requests().is_empty());
}

#[cfg(unix)]
#[test]
fn a_tampered_staged_package_is_never_executed() {
    if cmux_server::sys::is_root() {
        return;
    }
    let env = Env::new();
    let pkg = env.publish_needing(1, "9.0.0", "9.0.0");
    // A store directory for that SHA-256 that no verified unpack wrote.
    let layout = layout_at(env.tmp.path(), host::platform());
    let dir = std::path::Path::new(layout.store.as_str()).join(sha_hex(&pkg.archive));
    std::fs::create_dir_all(dir.join("bin")).unwrap();
    std::fs::write(dir.join("bin/cmux"), b"evil").unwrap();
    {
        // The store root keeps a mode its access policy accepts.
        use std::os::unix::fs::PermissionsExt;
        let root = std::path::Path::new(layout.root.as_str());
        std::fs::set_permissions(root, std::fs::Permissions::from_mode(0o700)).unwrap();
    }
    let store = cmux_server::store::Store::new(&layout);
    let package = cmux_server_core::manifest::Package {
        name: "cmux".to_owned(),
        version: "9.0.0".to_owned(),
        url: pkg.url(),
        sha256: sha_hex(&pkg.archive),
        size: pkg.archive.len() as u64,
        roles: vec!["all".to_owned()],
    };
    let err = store.verified_package_file(&package, &dir.join("bin/cmux")).unwrap_err();
    assert_eq!(err.kind, ExitKind::Verification, "{err}");
    // Through the verb: the unmarked directory is replaced by a verified
    // unpack before anything runs, so the exec gets the real bytes.
    let _ = env.run(&format!("install {CHAN}"));
    let requests = env.exec.requests();
    assert_eq!(requests.len(), 1);
    assert_eq!(std::fs::read(&requests[0].program).unwrap(), b"cmux 9.0.0");
}

/// Set in the child process of `the_reexec_really_execs_the_server_binary`
/// to the directory it works in.
#[cfg(unix)]
const EXEC_CHILD: &str = "CMUX_SERVER_TEST_EXEC_CHILD";

#[cfg(unix)]
#[test]
fn the_reexec_really_execs_the_server_binary() {
    if cmux_server::sys::is_root() {
        return;
    }
    if let Ok(dir) = std::env::var(EXEC_CHILD) {
        // Child: stage a package whose bin/cmux is a script that
        // records its argv and the guard, then exec it for real.
        let out = std::path::Path::new(&dir).join("exec.out");
        let script = format!(
            "#!/bin/sh\nprintf '%s\\n' \"$@\" > '{0}'\nprintf 'guard=%s\\n' \"$CMUX_SERVER_REEXEC\" >> '{0}'\n",
            out.display()
        );
        let mut env = Env::new();
        env.tmp = tempfile::tempdir_in(&dir).unwrap();
        env.publish_archive(1, "9.0.0", "9.0.0", files_package(&[("cmux", script.as_bytes())]));
        let mut ctx = env.ctx();
        let system = cmux_server::exec::SystemExec;
        ctx.exec = &system;
        let result = dispatch(&ctx, &parse(&words(&format!("upgrade --json {CHAN}"))).unwrap());
        panic!("the exec returned: {:?}", result.err());
    }
    let tmp = tempfile::tempdir().unwrap();
    let status = std::process::Command::new(std::env::current_exe().unwrap())
        .args(["the_reexec_really_execs_the_server_binary", "--exact", "--nocapture"])
        .env(EXEC_CHILD, tmp.path())
        .env("CMUX_SERVER_REEXEC", "stale")
        .status()
        .unwrap();
    assert!(status.success(), "{status}");
    let out = std::fs::read_to_string(tmp.path().join("exec.out")).unwrap();
    let lines: Vec<&str> = out.lines().collect();
    assert_eq!(
        lines[..4],
        ["server", "upgrade", "--channel-url=https://chan.example.test", "--json"]
    );
    assert!(lines[4].starts_with("guard=1:"), "{out}");
    assert_eq!(lines.len(), 5, "{out}");
}

#[cfg(unix)]
#[test]
fn exec_of_a_binary_this_machine_cannot_run_is_exit_4_with_its_path() {
    use std::os::unix::fs::PermissionsExt;
    let tmp = tempfile::tempdir().unwrap();
    let program = tmp.path().join("foreign");
    // Neither a script nor a binary format of this machine: execve fails
    // with ENOEXEC and the process is not replaced.
    std::fs::write(&program, [0u8, 1, 2, 3, 4, 5, 6, 7]).unwrap();
    std::fs::set_permissions(&program, std::fs::Permissions::from_mode(0o755)).unwrap();
    let request =
        cmux_server::exec::ExecRequest { program: program.clone(), args: vec![], env: vec![] };
    let err = cmux_server::exec::Exec::exec(&cmux_server::exec::SystemExec, &request);
    assert_eq!(err.kind, ExitKind::Rejected, "{err}");
    assert!(err.message.contains(&program.display().to_string()), "{err}");
}
