//! Every `acpmux` process a test starts gets the hermetic test environment
//! (cx-s8wux): only `tests/support/daemon_env.rs` names the binary. A test
//! that starts it on its own keeps the host's environment, and on a fleet
//! host the daemon finds the real codex or claude on PATH and runs live
//! probes, sign-in checks and auto-updates with real accounts (cx-w014j).
//! Start it with `daemon_env::acpmux`, `daemon_env::command` or
//! `daemon_env::apply` instead.

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
        // Every start goes through `acpmux(exe, home)`, which calls `apply`.
        ("windows_daemon.rs", "daemon_env::bin().to_path_buf()"),
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
    for needle in ["env_clear()", "\"ACPMUX_AGENT_LAUNCH\".into(), \"deny\".into()", binary] {
        assert!(helper.contains(needle), "tests/{HELPER} lost `{needle}`");
    }
}
