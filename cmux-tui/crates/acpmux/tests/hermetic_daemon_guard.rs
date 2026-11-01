//! Every `acpmux` process a test starts gets the hermetic test environment
//! (cx-s8wux): only `tests/support/daemon_env.rs` names the binary. A test
//! that starts it on its own keeps the host's environment, and on a fleet
//! host the daemon finds the real codex or claude on PATH and runs live
//! probes, sign-in checks and auto-updates with real accounts (cx-w014j).
//! Start it with `daemon_env::acpmux`, `daemon_env::command` or
//! `daemon_env::apply` instead.
//!
//! Every test process runs hermetic too (cx-s8wux.1): each test binary (a
//! top-level file in `tests/`) includes `support/daemon_env.rs`, which
//! starts the process again with the hermetic environment before `main`, so a
//! hub run in the test process never sees the host's PATH or HOME (cx-fylng).

use std::path::{Path, PathBuf};

const HELPER: &str = "support/daemon_env.rs";

fn rust_files(dir: &Path, out: &mut Vec<PathBuf>) {
    for entry in std::fs::read_dir(dir).unwrap() {
        let path = entry.unwrap().path();
        if path.is_dir() {
            rust_files(&path, out);
        } else if path.extension().is_some_and(|e| e == "rs") {
            out.push(path);
        }
    }
}

#[test]
fn only_the_hermetic_helper_starts_the_acpmux_binary() {
    let tests = Path::new(env!("CARGO_MANIFEST_DIR")).join("tests");
    let binary = "CARGO_BIN_EXE_acpmux";
    // The helper's path starts a process without its environment, so each
    // use of it is listed here with why it is safe.
    let bin = "daemon_env::bin()";
    let allowed = [
        // Compares the daemon's own directory; starts nothing.
        ("chief_builtin_presets.rs", "std::fs::canonicalize(daemon_env::bin())"),
        // The agent host launcher: its stand-in child gets the hermetic
        // `SpawnSpec.env` (the host process itself only runs that child).
        ("agent_host.rs", "HostLauncher { exe: daemon_env::bin().into()"),
        // The same launcher for a pinned harness; its stand-in child gets the hermetic
        // `SpawnSpec.env` too.
        ("cwd_pin.rs", "HostLauncher { exe: daemon_env::bin().into()"),
        // The same launcher for the CPU-class check; its stand-in child gets the hermetic
        // `SpawnSpec.env` too.
        ("cpu_class.rs", "HostLauncher { exe: daemon_env::bin().into()"),
        // Every start goes through `acpmux(exe, home)`, which calls `apply`.
        ("windows_daemon.rs", "daemon_env::bin().to_path_buf()"),
        // A disposable-account run swaps in a relocated build; the next line calls `apply`.
        ("person_allow.rs", "Command::new(machine_consent_home::binary(daemon_env::bin()))"),
        // The same swap; `cli` clears the environment and sets `daemon_env::vars`.
        ("machine_join.rs", "Command::new(machine_consent_home::binary(daemon_env::bin()))"),
        // Sandbox helpers, not daemons: the keeper child gets `env_clear()` and a fixed PATH;
        // init and the canary inherit this process's hermetic environment (`HERMETIC`).
        ("linux_sandbox_keeper.rs", "Command::new(daemon_env::bin())"),
        ("linux_sandbox_init.rs", "Command::new(daemon_env::bin())"),
        ("remote_sandbox_linux.rs", "PathBuf::from(daemon_env::bin())"),
        // The background-task runner the in-process hub starts; it inherits this process's
        // hermetic environment.
        ("hub_integration/bg_tasks.rs", "crate::daemon_env::bin().into()"),
        // Linked into a fake app bundle; that copy starts only after `apply`.
        ("app_orphan_exit.rs", "let source = daemon_env::bin();"),
    ];
    let mut files = Vec::new();
    rust_files(&tests, &mut files);
    let mut offenders = Vec::new();
    for file in &files {
        let rel = file.strip_prefix(&tests).unwrap();
        if rel == Path::new(HELPER) || rel == Path::new("hermetic_daemon_guard.rs") {
            continue;
        }
        let text = std::fs::read_to_string(file).unwrap();
        for (n, line) in text.lines().enumerate() {
            let listed = allowed.iter().any(|(f, text)| rel == Path::new(f) && line.contains(text));
            if line.contains(binary) || (line.contains(bin) && !listed) {
                offenders.push(format!("tests/{}:{}: {}", rel.display(), n + 1, line.trim()));
            }
        }
    }
    assert!(
        offenders.is_empty(),
        "start acpmux through tests/{HELPER} (daemon_env::acpmux, command or apply), \
         never with the host environment:\n{}",
        offenders.join("\n")
    );
    // The helper itself still clears the environment and denies launches.
    let helper = std::fs::read_to_string(tests.join(HELPER)).unwrap();
    for needle in [
        "env_clear()",
        "\"ACPMUX_AGENT_LAUNCH\".into(), \"deny\".into()",
        binary,
        "unsafe(link_section = \".init_array\")",
        "unsafe(link_section = \"__DATA,__mod_init_func\")",
        "enter(super::HERMETIC, args)",
    ] {
        assert!(helper.contains(needle), "tests/{HELPER} lost `{needle}`");
    }
}

#[test]
fn every_test_binary_runs_in_the_hermetic_environment() {
    let tests = Path::new(env!("CARGO_MANIFEST_DIR")).join("tests");
    let mut missing = Vec::new();
    for entry in std::fs::read_dir(&tests).unwrap() {
        let path = entry.unwrap().path();
        let name = path.file_name().unwrap().to_string_lossy().into_owned();
        if !name.ends_with(".rs") || name == "hermetic_daemon_guard.rs" {
            continue;
        }
        let text = std::fs::read_to_string(&path).unwrap();
        let included = text.contains("#[path = \"support/daemon_env.rs\"]")
            && text.contains("mod daemon_env;");
        if !included || !text.contains("const HERMETIC: daemon_env::Process") {
            missing.push(format!("tests/{name}"));
        }
    }
    assert!(
        missing.is_empty(),
        "each test binary includes tests/{HELPER} and defines \
         `const HERMETIC: daemon_env::Process = daemon_env::Process::deny();` \
         (or `stand_in()` when it runs stand-in agents):\n{}",
        missing.join("\n")
    );
}
