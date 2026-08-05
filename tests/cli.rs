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
         if [ \"$1 $2\" = 'daemon status' ]; then exit 1; fi\n\
         if [ \"$1\" = setup ]; then printf '%s\\n' \"$*\"; exit 0; fi\n\
         printf '%s\\n' \"$*\"\n\
         printf 'server=%s\\n' \"${SUBROUTER_CODEX_SERVER-unset}\"\n\
         printf 'state=%s\\n' \"$SUBROUTER_STATE_DIR\"\n\
         printf 'codex_home=%s\\n' \"$CODEX_HOME\"\n",
    )
    .unwrap();
    fs::set_permissions(&backend, fs::Permissions::from_mode(0o755)).unwrap();

    Command::cargo_bin("cr")
        .unwrap()
        .args(["codex", "exec", "hello"])
        .env("CODEROUTER_SUBROUTER_BIN", &backend)
        .env("CODEROUTER_DATA_DIR", root.path().join("data"))
        .env("CODEX_HOME", root.path().join("normal-codex"))
        .assert()
        .success()
        .stdout(
            predicate::str::contains("setup --no-config")
                .and(predicate::str::contains("codex exec hello"))
                .and(predicate::str::contains("server=local"))
                .and(predicate::str::contains(
                    root.path()
                        .join("data/coderouter/state")
                        .to_string_lossy()
                        .as_ref(),
                ))
                .and(predicate::str::contains(
                    root.path().join("normal-codex").to_string_lossy().as_ref(),
                )),
        );
}

#[cfg(unix)]
#[test]
fn bare_command_shows_the_routing_engine_account_summary() {
    use std::os::unix::fs::PermissionsExt;

    let root = TempDir::new().unwrap();
    let backend = root.path().join("subrouter");
    fs::write(
        &backend,
        "#!/bin/sh\nprintf 'argc=%s\\n' \"$#\"\nprintf 'args=%s\\n' \"$*\"\n",
    )
    .unwrap();
    fs::set_permissions(&backend, fs::Permissions::from_mode(0o755)).unwrap();

    Command::cargo_bin("cr")
        .unwrap()
        .env("CODEROUTER_SUBROUTER_BIN", &backend)
        .env("CODEROUTER_DATA_DIR", root.path().join("data"))
        .assert()
        .success()
        .stdout(
            predicate::str::contains("argc=1")
                .and(predicate::str::contains("args=status"))
                .and(predicate::str::contains("codex").not()),
        );
}

#[cfg(unix)]
#[test]
fn login_uses_the_production_control_plane_and_isolated_config() {
    use std::os::unix::fs::PermissionsExt;

    let root = TempDir::new().unwrap();
    let backend = root.path().join("subrouter");
    fs::write(
        &backend,
        "#!/bin/sh\n\
         printf '%s\\n' \"$*\"\n\
         printf 'config=%s\\n' \"$SUBROUTER_CLOUD_CONFIG\"\n\
         printf 'state=%s\\n' \"$SUBROUTER_STATE_DIR\"\n\
         printf 'codex_home=%s\\n' \"$CODEX_HOME\"\n",
    )
    .unwrap();
    fs::set_permissions(&backend, fs::Permissions::from_mode(0o755)).unwrap();

    Command::cargo_bin("cr")
        .unwrap()
        .args(["login", "--no-browser"])
        .env("CODEROUTER_SUBROUTER_BIN", &backend)
        .env("CODEROUTER_DATA_DIR", root.path().join("data"))
        .assert()
        .success()
        .stdout(
            predicate::str::contains("login --base-url https://coderouter.dev --no-browser").and(
                predicate::str::contains(
                    root.path()
                        .join("data/coderouter/cloud.json")
                        .to_string_lossy()
                        .as_ref(),
                )
                .and(predicate::str::contains(
                    root.path()
                        .join("data/coderouter/state")
                        .to_string_lossy()
                        .as_ref(),
                ))
                .and(predicate::str::contains(
                    root.path()
                        .join("data/coderouter/codex-home")
                        .to_string_lossy()
                        .as_ref(),
                )),
            ),
        );
}

#[cfg(unix)]
#[test]
fn logout_uses_only_coderouter_state_and_config() {
    use std::os::unix::fs::PermissionsExt;

    let root = TempDir::new().unwrap();
    let backend = root.path().join("subrouter");
    fs::write(
        &backend,
        "#!/bin/sh\n\
         printf '%s\\n' \"$*\"\n\
         printf 'config=%s\\n' \"$SUBROUTER_CLOUD_CONFIG\"\n\
         printf 'state=%s\\n' \"$SUBROUTER_STATE_DIR\"\n\
         printf 'codex_home=%s\\n' \"$CODEX_HOME\"\n",
    )
    .unwrap();
    fs::set_permissions(&backend, fs::Permissions::from_mode(0o755)).unwrap();

    Command::cargo_bin("cr")
        .unwrap()
        .arg("logout")
        .env("CODEROUTER_SUBROUTER_BIN", &backend)
        .env("CODEROUTER_DATA_DIR", root.path().join("data"))
        .env("CODEX_HOME", root.path().join("normal-codex"))
        .assert()
        .success()
        .stdout(
            predicate::str::contains("logout")
                .and(predicate::str::contains(
                    root.path()
                        .join("data/coderouter/cloud.json")
                        .to_string_lossy()
                        .as_ref(),
                ))
                .and(predicate::str::contains(
                    root.path()
                        .join("data/coderouter/state")
                        .to_string_lossy()
                        .as_ref(),
                ))
                .and(predicate::str::contains(
                    root.path()
                        .join("data/coderouter/codex-home")
                        .to_string_lossy()
                        .as_ref(),
                ))
                .and(
                    predicate::str::contains(
                        root.path().join("normal-codex").to_string_lossy().as_ref(),
                    )
                    .not(),
                ),
        );
}

#[cfg(unix)]
#[test]
fn device_login_prints_a_copyable_code_without_opening_a_browser() {
    use std::os::unix::fs::PermissionsExt;

    let root = TempDir::new().unwrap();
    let backend = root.path().join("subrouter");
    fs::write(
        &backend,
        "#!/bin/sh\n\
         printf 'Approve Subrouter at:\\n'\n\
         printf '  https://coderouter.dev/handler/cli-auth-confirm?login_code=copy-me-123\\n'\n\
         printf 'state=%s\\n' \"$SUBROUTER_STATE_DIR\"\n\
         printf 'codex_home=%s\\n' \"$CODEX_HOME\"\n",
    )
    .unwrap();
    fs::set_permissions(&backend, fs::Permissions::from_mode(0o755)).unwrap();

    Command::cargo_bin("cr")
        .unwrap()
        .args(["login", "--device-auth"])
        .env("CODEROUTER_SUBROUTER_BIN", &backend)
        .env("CODEROUTER_DATA_DIR", root.path().join("data"))
        .assert()
        .success()
        .stdout(
            predicate::str::contains("Open https://coderouter.dev/authorize")
                .and(predicate::str::contains("Authorization code: copy-me-123"))
                .and(predicate::str::contains("handler/cli-auth-confirm").not())
                .and(predicate::str::contains(
                    root.path()
                        .join("data/coderouter/state")
                        .to_string_lossy()
                        .as_ref(),
                ))
                .and(predicate::str::contains(
                    root.path()
                        .join("data/coderouter/codex-home")
                        .to_string_lossy()
                        .as_ref(),
                )),
        );
}
