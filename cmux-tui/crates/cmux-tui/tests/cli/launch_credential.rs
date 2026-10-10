#![cfg(unix)]
//! P8 slice 3 end to end (plans/cmux-next/identity.md section 5): a process
//! in a cmux terminal runs the CLI, the CLI sends the terminal's launch
//! credential, and the durable mutation names that terminal as its actor. A
//! forged credential is refused, and the CLI never sends a credential to a
//! session that is not its terminal's own.

use super::*;

/// The `resource_mutations.actor` of the row with `key`, once it exists.
fn recorded_actor(state: &std::path::Path, key: &str) -> String {
    let deadline = Instant::now() + Duration::from_secs(20);
    loop {
        for database in registry_databases(state) {
            let Ok(connection) = rusqlite::Connection::open_with_flags(
                &database,
                rusqlite::OpenFlags::SQLITE_OPEN_READ_ONLY,
            ) else {
                continue;
            };
            let actor = connection.query_row(
                "SELECT actor FROM resource_mutations WHERE idempotency_key = ?1",
                [key],
                |row| row.get::<_, String>(0),
            );
            if let Ok(actor) = actor {
                return actor;
            }
        }
        assert!(Instant::now() < deadline, "no mutation {key} was recorded");
        std::thread::sleep(Duration::from_millis(50));
    }
}

fn registry_databases(root: &std::path::Path) -> Vec<PathBuf> {
    let mut found = Vec::new();
    let mut pending = vec![root.to_path_buf()];
    while let Some(dir) = pending.pop() {
        for entry in fs::read_dir(&dir).into_iter().flatten().flatten() {
            let path = entry.path();
            if path.file_name().is_some_and(|name| name == "workspace-registry.sqlite3") {
                found.push(path);
            } else if path.is_dir() {
                pending.push(path);
            }
        }
    }
    found
}

fn wait_for_text(path: &std::path::Path) -> String {
    let deadline = Instant::now() + Duration::from_secs(20);
    loop {
        if let Ok(text) = fs::read_to_string(path) {
            return text;
        }
        assert!(Instant::now() < deadline, "{} never appeared", path.display());
        std::thread::sleep(Duration::from_millis(50));
    }
}

/// The CLI as a process in a terminal of `server` runs it, with `credential`.
fn cli_in_terminal(server: &HeadlessServer, credential: &str, args: &[&str]) -> Output {
    Command::new(bin())
        .arg("--json")
        .args(args)
        .env("CMUX_TUI_SOCKET", &server.socket)
        .env("CMUX_LAUNCH_CREDENTIAL", credential)
        .env_remove("CMUX_TUI_TERMINAL_ID")
        .output()
        .unwrap()
}

#[test]
fn a_terminal_child_cli_mutation_records_its_terminal() {
    let server = HeadlessServer::start("launch-credential");
    let created = json_cli(&server, &["workspace", "create", "--name", "credential"]);
    assert_success(&created);
    let workspace = json_output(&created)["value"]["workspace_id"].as_str().unwrap().to_string();
    let out = server.dir.join("credential");
    let script = format!(
        "printf %s \"$CMUX_LAUNCH_CREDENTIAL\" > '{out}.tmp' && mv '{out}.tmp' '{out}'; \
         exec '{bin}' --json workspace create --name from-terminal --empty \
         --idempotency-key lc-from-terminal",
        out = out.display(),
        bin = bin(),
    );
    let run = json_cli(
        &server,
        &["workspace", &workspace, "run", "--on-exit", "keep", "--", "/bin/sh", "-c", &script],
    );
    assert_success(&run);
    let terminal = json_output(&run)["value"]["terminal_id"].as_str().unwrap().to_string();

    let credential = wait_for_text(&out);
    assert!(credential.starts_with("cmuxlc1."), "the terminal child got no launch credential");
    assert_eq!(recorded_actor(&server.state, "lc-from-terminal"), format!("terminal:{terminal}"));

    // The same CLI with a forged credential is refused, and nothing is written.
    let mut forged = credential.into_bytes();
    let last = forged.last_mut().unwrap();
    *last = if *last == b'A' { b'B' } else { b'A' };
    let forged = String::from_utf8(forged).unwrap();
    let refused = cli_in_terminal(
        &server,
        &forged,
        &["workspace", "create", "--name", "forged", "--empty", "--idempotency-key", "lc-forged"],
    );
    assert!(!refused.status.success(), "a forged credential was accepted");
    let error = json_error(&refused);
    assert_eq!(error["code"], "validation.invalid", "{error}");
    assert_eq!(error["details"]["reason"], "credential_invalid", "{error}");
    assert!(!refused.stderr.windows(forged.len()).any(|w| w == forged.as_bytes()));

    // Another session's socket never receives this terminal's credential:
    // with `--socket` the CLI acts as the plain local user.
    let elsewhere = Command::new(bin())
        .args(["--json", "--socket"])
        .arg(&server.socket)
        .args(["workspace", "create", "--name", "routed", "--empty"])
        .args(["--idempotency-key", "lc-routed"])
        .env("CMUX_TUI_SOCKET", server.dir.join("other.sock"))
        .env("CMUX_LAUNCH_CREDENTIAL", &forged)
        .output()
        .unwrap();
    assert_success(&elsewhere);
    assert_eq!(recorded_actor(&server.state, "lc-routed"), "user:user_local");
}
