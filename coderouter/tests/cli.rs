use std::fs;

use assert_cmd::Command;
use predicates::prelude::*;
use tempfile::TempDir;

#[test]
fn both_binary_names_show_the_same_help() {
    Command::cargo_bin("cr")
        .unwrap()
        .arg("--help")
        .assert()
        .success()
        .stdout(predicate::str::contains("cr naked"));
    Command::cargo_bin("coderouter")
        .unwrap()
        .arg("--help")
        .assert()
        .success()
        .stdout(predicate::str::contains("cr naked"));
}

#[cfg(unix)]
#[test]
fn naked_executes_codex_without_coderouter_routing_environment() {
    use std::os::unix::fs::PermissionsExt;

    let root = TempDir::new().unwrap();
    let codex = root.path().join("codex");
    fs::write(
        &codex,
        "#!/bin/sh\nprintf '%s\\n' \"$*\"\nprintf 'route=%s\\n' \"${SUBROUTER_CODEX_SERVER-unset}\"\nexit 23\n",
    )
    .unwrap();
    fs::set_permissions(&codex, fs::Permissions::from_mode(0o755)).unwrap();

    let path = format!(
        "{}:{}",
        root.path().display(),
        std::env::var("PATH").unwrap_or_default()
    );
    Command::cargo_bin("cr")
        .unwrap()
        .args(["naked", "exec", "hello"])
        .env("PATH", path)
        .env("SUBROUTER_CODEX_SERVER", "cmux")
        .assert()
        .code(23)
        .stdout(
            predicate::str::contains("exec hello").and(predicate::str::contains("route=unset")),
        );
}

#[cfg(unix)]
#[test]
fn codex_command_delegates_to_the_routing_engine() {
    use std::os::unix::fs::PermissionsExt;

    let root = TempDir::new().unwrap();
    let backend = root.path().join("subrouter");
    fs::write(
        &backend,
        "#!/bin/sh\n\
         if [ \"$1 $2\" = 'team current' ]; then exit 0; fi\n\
         if [ \"$1\" = storage ]; then printf 'hosted\\n'; exit 0; fi\n\
         if [ \"$1 $2\" = 'daemon status' ]; then exit 0; fi\n\
         printf '%s\\n' \"$*\"\n\
         printf 'server=%s\\n' \"${SUBROUTER_CODEX_SERVER-unset}\"\n",
    )
    .unwrap();
    fs::set_permissions(&backend, fs::Permissions::from_mode(0o755)).unwrap();

    Command::cargo_bin("cr")
        .unwrap()
        .args(["codex", "exec", "hello"])
        .env("CODEROUTER_SUBROUTER_BIN", &backend)
        .assert()
        .success()
        .stdout(
            predicate::str::contains("codex exec hello")
                .and(predicate::str::contains("server=local")),
        );
}
