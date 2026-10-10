//! Page history through `cmux history` and the daemon socket against a real
//! headless daemon, with no app running (H3, plans/cmux-next/react-pages.md
//! 2.3). Visits are seeded straight into the daemon's page store file, the
//! way an older app log arrives; the CLI and the socket then read and edit
//! them.

use super::*;
use serde_json::{Value, json};

/// `cmux --json --socket <server> <args>`, success or not.
fn history_cli(server: &HeadlessServer, args: &[&str]) -> Output {
    Command::new(bin())
        .arg("--json")
        .arg("--socket")
        .arg(&server.socket)
        .args(args)
        .env("LC_ALL", "C")
        .env_remove("CMUX_TUI_SOCKET")
        .env_remove("CMUX_TUI_TERMINAL_ID")
        .env_remove("CMUX_SOCKET_PATH")
        .env_remove("CMUX_BUNDLE_ID")
        .env_remove("CMUX_TAG")
        .output()
        .unwrap()
}

/// One `cmux.protocol/2` request on a plain socket connection (origin agent:
/// no client hello); the whole response.
fn v2(server: &HeadlessServer, operation: &str, params: Value, key: Option<&str>) -> Value {
    let mut params = params;
    params["machine"] = json!("current");
    params["session"] = json!("current");
    let mut request = json!({
        "protocol": "cmux.protocol/2", "type": "request", "id": "history",
        "operation": operation, "params": params,
    });
    if let Some(key) = key {
        request["idempotency_key"] = json!(key);
    }
    let stream = transport::connect(&server.socket).unwrap();
    let mut writer = stream.try_clone_box().unwrap();
    let mut reader = BufReader::new(stream);
    writeln!(writer, "{request}").unwrap();
    let mut line = String::new();
    reader.read_line(&mut line).unwrap();
    serde_json::from_str(&line).unwrap()
}

/// The daemon's page store directory (made by the first history request).
fn history_dir(server: &HeadlessServer) -> PathBuf {
    let listed = history_cli(server, &["history", "list", "--kind", "page"]);
    assert_success(&listed);
    server.state.join("history")
}

/// Seeds visits `(url, title, age in ms)` into a profile's page store file.
fn seed(server: &HeadlessServer, profile: &str, visits: &[(&str, &str, i64)]) {
    let path = history_dir(server).join(format!("{profile}.sqlite"));
    let db = rusqlite::Connection::open(path).unwrap();
    db.execute_batch(
        "CREATE TABLE IF NOT EXISTS visits(id INTEGER PRIMARY KEY, url TEXT NOT NULL, \
         title TEXT, visit_time_ms INTEGER NOT NULL, tab TEXT)",
    )
    .unwrap();
    let now =
        i64::try_from(SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_millis()).unwrap();
    for (url, title, age) in visits {
        db.execute(
            "INSERT INTO visits(url, title, visit_time_ms) VALUES (?1, ?2, ?3)",
            rusqlite::params![url, title, now - age],
        )
        .unwrap();
    }
}

fn titles(listed: &Value) -> Vec<String> {
    listed["entries"]
        .as_array()
        .unwrap_or_else(|| panic!("{listed}"))
        .iter()
        .map(|entry| entry["title"].as_str().unwrap().to_owned())
        .collect()
}

#[test]
fn history_cli_reads_and_edits_page_history_with_no_app_through_a_real_daemon() {
    let server = HeadlessServer::start("history-cli");
    seed(
        &server,
        "default",
        &[
            ("https://example.com/docs", "Résumé docs", 5_000),
            ("https://other.test/", "Other", 1_000),
        ],
    );

    let found = state_cli(&server, None, &["history", "search", "resume", "--kind", "page"]);
    assert_eq!(titles(&found), ["Résumé docs"], "the search folds case and diacritics");
    let id = found["entries"][0]["id"].as_str().unwrap().to_owned();
    assert!(id.starts_with("page:default:"), "{id}");
    let listed = state_cli(&server, None, &["history", "list", "--kind", "page"]);
    assert_eq!(titles(&listed), ["Other", "Résumé docs"], "newest first");

    let removed = state_cli(&server, None, &["history", "remove", &id]);
    assert_eq!(removed["value"]["removed"], 1, "{removed}");
    let restore_id = removed["value"]["restore_id"].as_str().unwrap().to_owned();
    let listed = state_cli(&server, None, &["history", "list", "--kind", "page"]);
    assert_eq!(titles(&listed), ["Other"]);
    let restored = state_cli(&server, None, &["history", "restore", &restore_id]);
    assert_eq!(restored["value"]["restored"], 1, "{restored}");
    let listed = state_cli(&server, None, &["history", "list", "--kind", "page"]);
    assert_eq!(titles(&listed).len(), 2, "the delete was undone");

    let site = state_cli(&server, None, &["history", "remove-site", "example.com"]);
    assert_eq!(site["value"]["removed"], 1, "{site}");
    let cleared =
        state_cli(&server, None, &["history", "clear-range", "--range", "all", "--kind", "page"]);
    assert_eq!(cleared["value"]["removed"], 1, "{cleared}");
    let listed = state_cli(&server, None, &["history", "list", "--kind", "page"]);
    assert_eq!(titles(&listed), Vec::<String>::new());

    let missing = history_cli(&server, &["history", "search"]);
    assert_eq!(missing.status.code(), Some(2));
    let stderr = String::from_utf8_lossy(&missing.stderr);
    assert!(stderr.contains("cmux history search <text>"), "{stderr}");
}

#[test]
fn only_the_verified_app_may_purge_record_or_import_page_history() {
    let server = HeadlessServer::start("history-origin");
    seed(&server, "default", &[("https://example.com/", "Example", 1_000)]);
    let legacy = server.dir.join("History.sqlite");
    fs::copy(history_dir(&server).join("default.sqlite"), &legacy).unwrap();
    let restore_id = format!("history:{}", "0".repeat(32));
    for (operation, params) in [
        ("history.backups.purge", json!({"restore_id": restore_id})),
        (
            "history.visit.record",
            json!({"profile": "default", "url": "https://forged.test/", "at_ms": "1"}),
        ),
        (
            "history.visit.title",
            json!({"profile": "default", "url": "https://example.com/", "title": "T"}),
        ),
        ("history.visit.import", json!({"profile": "default", "path": legacy.to_str().unwrap()})),
    ] {
        let refused = v2(&server, operation, params, Some(&format!("k-{operation}")));
        assert_eq!(refused["ok"], false, "{operation}: {refused}");
        assert_eq!(refused["error"]["code"], "origin.forbidden", "{operation}: {refused}");
    }
    let listed = state_cli(&server, None, &["history", "list", "--kind", "page"]);
    assert_eq!(titles(&listed), ["Example"], "no forged, retitled or imported visit");
}

#[test]
fn reads_and_removals_of_an_unknown_profile_create_no_page_store() {
    let server = HeadlessServer::start("history-ghost");
    seed(&server, "default", &[("https://example.com/", "Example", 1_000)]);
    state_cli(&server, None, &["history", "remove", "page:ghost:1"]);
    state_cli(&server, None, &["history", "remove-site", "example.com", "--profile", "ghost"]);
    state_cli(
        &server,
        None,
        &["history", "clear-range", "--range", "all", "--kind", "page", "--profile", "ghost"],
    );
    let summaries = v2(&server, "history.visit.summaries", json!({"profile": "ghost"}), None);
    assert_eq!(summaries["result"], json!([]), "{summaries}");
    let mut files: Vec<String> = fs::read_dir(history_dir(&server))
        .unwrap()
        .map(|entry| entry.unwrap().file_name().to_string_lossy().into_owned())
        .filter(|name| name.ends_with(".sqlite"))
        .collect();
    files.sort();
    assert_eq!(files, ["default.sqlite"]);
    let listed = state_cli(&server, None, &["history", "list", "--kind", "page"]);
    assert_eq!(titles(&listed), ["Example"], "the other profile kept its visit");
}

#[test]
fn a_page_url_over_1024_bytes_is_removed_by_its_exact_url() {
    let server = HeadlessServer::start("history-long-url");
    let long = format!("https://example.com/{}", "x".repeat(2_000));
    seed(
        &server,
        "default",
        &[(&long, "Long", 2_000), ("https://example.com/short", "Short", 1_000)],
    );
    let removed = v2(&server, "history.visit.remove", json!({"urls": [long]}), Some("rm-long"));
    assert_eq!(removed["result"]["value"]["removed"], 1, "{removed}");
    assert!(removed["result"]["value"]["restore_id"].is_string(), "{removed}");
    let listed = state_cli(&server, None, &["history", "list", "--kind", "page"]);
    assert_eq!(titles(&listed), ["Short"]);
}
