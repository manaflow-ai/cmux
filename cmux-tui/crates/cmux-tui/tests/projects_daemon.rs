//! The device project list (`project-list-v1`, plans/cmux-next/projects.md)
//! on a real headless daemon over its socket: a source's report, the user's
//! overlay, refusals, hiding on remove, replay, and the app's disk facts.
#![cfg(unix)]

use std::fs;
use std::io::{BufRead, BufReader, Write};
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Stdio};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use cmux_tui_core::platform::transport;
use serde_json::{Value, json};

struct Daemon {
    child: Child,
    socket: PathBuf,
    dir: PathBuf,
}

impl Daemon {
    fn start(name: &str) -> Self {
        let stamp = SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos();
        let dir = PathBuf::from("/tmp")
            .join(format!("cmux-projects-{name}-{}-{stamp}", std::process::id()));
        // The Codex home exists at start, so the daemon watches it.
        fs::create_dir_all(dir.join("home/.codex")).unwrap();
        let socket = dir.join("mux.sock");
        let child = Command::new(env!("CARGO_BIN_EXE_cmux-tui"))
            .args(["--headless", "--socket"])
            .arg(&socket)
            .arg("--state")
            .arg(dir.join("state"))
            .env("CMUX_TUI_CONFIG", dir.join("config.json"))
            // The editor sources read under HOME: an empty one has none.
            .env("HOME", dir.join("home"))
            .env_remove("XDG_CONFIG_HOME")
            .env_remove("XDG_DATA_HOME")
            .env_remove("CODEX_HOME")
            .stdout(Stdio::null())
            .stderr(Stdio::null())
            .spawn()
            .unwrap();
        let scale = std::env::var("CMUX_TEST_TIMEOUT_SCALE")
            .ok()
            .and_then(|value| value.parse::<u32>().ok())
            .unwrap_or(1)
            .clamp(1, 16);
        let deadline = Instant::now() + Duration::from_secs(15) * scale;
        while transport::connect(&socket).is_err() {
            assert!(Instant::now() < deadline, "daemon did not create {}", socket.display());
            std::thread::sleep(Duration::from_millis(25));
        }
        Self { child, socket, dir }
    }

    /// One `cmux.protocol/2` request; the reply's `result`, or its `error`.
    fn send(&self, operation: &str, mut params: Value, key: Option<&str>) -> Result<Value, Value> {
        params["machine"] = json!("current");
        params["session"] = json!("current");
        let mut request = json!({"protocol": "cmux.protocol/2", "type": "request", "id": "1",
                                 "operation": operation, "params": params});
        if let Some(key) = key {
            request["idempotency_key"] = json!(key);
        }
        let stream = transport::connect(&self.socket).unwrap();
        let mut writer = stream.try_clone_box().unwrap();
        let mut reader = BufReader::new(stream);
        writeln!(writer, "{request}").unwrap();
        let mut line = String::new();
        loop {
            line.clear();
            assert!(reader.read_line(&mut line).unwrap() > 0, "{operation}: connection closed");
            let reply: Value = serde_json::from_str(line.trim()).unwrap();
            if reply["id"] == "1" {
                return if reply["ok"] == true {
                    Ok(reply["result"].clone())
                } else {
                    Err(reply["error"].clone())
                };
            }
        }
    }

    fn mutate(&self, operation: &str, params: Value, key: &str) -> Value {
        self.send(operation, params, Some(key))
            .unwrap_or_else(|error| panic!("{operation}: {error}"))
    }

    fn list(&self, params: Value) -> Vec<Value> {
        let list = self.send("project.list", params, None).unwrap();
        list["projects"].as_array().cloned().unwrap_or_default()
    }
}

impl Drop for Daemon {
    fn drop(&mut self) {
        let _ = self.child.kill();
        let _ = self.child.wait();
        let _ = fs::remove_dir_all(&self.dir);
    }
}

fn find<'a>(projects: &'a [Value], path: &str) -> &'a Value {
    projects
        .iter()
        .find(|project| project["path"] == path)
        .unwrap_or_else(|| panic!("{path} not listed"))
}

#[test]
fn projects_daemon_observe_edit_remove_and_sync_over_the_socket() {
    let daemon = Daemon::start("list");
    let app = "/srv/cx-m0p7-fixture/app";
    let observe = json!({"source": "codex", "entries": [{"path": app, "last_used_ms": "50"}], "complete": true});
    let observed = daemon.mutate("project.observe", observe.clone(), "p-1");
    assert_eq!(observed["value"]["changed"], json!([app]), "{observed}");
    assert_eq!(
        daemon.mutate("project.observe", observe, "p-1")["replayed"],
        true,
        "same key replays"
    );

    let projects = daemon.list(json!({}));
    let project = find(&projects, app);
    assert_eq!(project["name"], "app");
    assert_eq!(project["last_used_ms"], "50", "wire times are decimal strings");
    assert_eq!(project["sources"]["codex"]["last_used_ms"], "50");
    assert_eq!(project["state"], "present");

    // The user's rename and pin survive the source's next report.
    daemon.mutate(
        "project.update",
        json!({"path": app, "rename": "The App", "pinned": true}),
        "p-2",
    );
    daemon.mutate(
        "project.observe",
        json!({"source": "codex", "entries": [{"path": app, "last_used_ms": "90"}]}),
        "p-3",
    );
    // A folder the user picks (temporary folders are never projects).
    let picked = Path::new(env!("CARGO_MANIFEST_DIR")).canonicalize().unwrap();
    let picked = picked.to_string_lossy().into_owned();
    daemon.mutate("project.add", json!({"path": picked}), "p-4");
    let projects = daemon.list(json!({}));
    assert_eq!(projects.len(), 2, "{projects:?}");
    assert_eq!(projects[0]["name"], "The App", "pinned first");
    assert_eq!(find(&projects, app)["last_used_ms"], "90");
    assert_eq!(daemon.list(json!({"query": "the app"})).len(), 1);

    // JSON null clears the rename.
    daemon.mutate("project.update", json!({"path": app, "rename": null}), "p-5");
    assert_eq!(find(&daemon.list(json!({})), app)["name"], "app");

    // The home folder and the root are never projects; an unknown path is refused.
    let refused = daemon.send("project.add", json!({"path": "/"}), Some("p-6")).unwrap_err();
    assert_eq!(refused["code"], "validation.invalid", "{refused}");
    let home = daemon.dir.join("home").canonicalize().unwrap().to_string_lossy().into_owned();
    let skipped = daemon.mutate(
        "project.observe",
        json!({"source": "claude", "entries": [{"path": home, "last_used_ms": "1"}, {"path": "/", "last_used_ms": "1"}]}),
        "p-7",
    );
    assert_eq!(skipped["value"]["changed"], json!([]), "refused paths are skipped: {skipped}");
    let unknown =
        daemon.send("project.update", json!({"path": "/srv/none", "pinned": true}), Some("p-8"));
    assert_eq!(unknown.unwrap_err()["code"], "validation.invalid");

    // Removed while a source still reports it: hidden, and a resync keeps it hidden.
    daemon.mutate("project.remove", json!({"path": app}), "p-9");
    daemon.mutate(
        "project.observe",
        json!({"source": "codex", "entries": [{"path": app, "last_used_ms": "99"}], "complete": true}),
        "p-10",
    );
    assert_eq!(daemon.list(json!({})).len(), 1);
    let all = daemon.list(json!({"include_hidden": true}));
    assert_eq!(all.len(), 2);
    assert_eq!(find(&all, app)["overlay"]["hidden"], true);

    // The app found both gone: the reported one stays present, the user's own goes missing.
    daemon.mutate("project.sync", json!({"existing": [], "gone": [app, picked]}), "p-11");
    let all = daemon.list(json!({"include_hidden": true}));
    assert_eq!(find(&all, app)["state"], "present");
    assert_eq!(find(&all, &picked)["state"], "missing");

    // Removing the user's own folder deletes it. A source that no longer
    // lists a path leaves it, and the user's edits keep the project.
    daemon.mutate("project.remove", json!({"path": picked}), "p-12");
    daemon.mutate(
        "project.observe",
        json!({"source": "codex", "entries": [], "complete": true}),
        "p-13",
    );
    let left = daemon.list(json!({"include_hidden": true}));
    assert!(left.iter().all(|project| project["path"] != picked), "{left:?}");
    assert_eq!(find(&left, app)["sources"], json!({}), "{left:?}");
}

/// Where the editors keep their state under `home` on this OS.
fn editor_dirs(home: &Path) -> (PathBuf, PathBuf) {
    if cfg!(target_os = "macos") {
        let support = home.join("Library/Application Support");
        (support.clone(), support.join("Zed"))
    } else {
        (home.join(".config"), home.join(".local/share/zed"))
    }
}

#[test]
fn projects_daemon_sync_imports_vscode_family_and_zed_recents() {
    let daemon = Daemon::start("editors");
    let (config, zed) = editor_dirs(&daemon.dir.join("home"));

    // Cursor's Open Recent list (newest first): a remote, a file and a
    // .code-workspace are not projects.
    let cursor = config.join("Cursor/User/globalStorage");
    fs::create_dir_all(&cursor).unwrap();
    let db = rusqlite::Connection::open(cursor.join("state.vscdb")).unwrap();
    db.execute_batch("CREATE TABLE ItemTable (key TEXT UNIQUE ON CONFLICT REPLACE, value BLOB);")
        .unwrap();
    db.execute(
        "INSERT INTO ItemTable(key, value) VALUES('history.recentlyOpenedPathsList', ?1)",
        [r#"{"entries":[
            {"folderUri":"file:///srv/cx-m0p7-editors/app"},
            {"folderUri":"vscode-remote://ssh-remote%2Bbox/home/me/x"},
            {"fileUri":"file:///srv/cx-m0p7-editors/notes.md"},
            {"folderUri":"file:///srv/cx-m0p7-editors/My%20Web"},
            {"workspace":{"id":"1","configPath":"file:///srv/cx-m0p7-editors/w.code-workspace"}}
        ]}"#],
    )
    .unwrap();
    drop(db);
    // VS Code without state.vscdb: its profile's workspace folders.
    let code = config.join("Code/User/globalStorage");
    fs::create_dir_all(&code).unwrap();
    fs::write(
        code.join("storage.json"),
        r#"{"profileAssociations":{"workspaces":{"file:///srv/cx-m0p7-editors/api":"__default__profile__"}}}"#,
    )
    .unwrap();
    // Windsurf with an unreadable database reports nothing (never its smaller list).
    let windsurf = config.join("Windsurf/User/globalStorage");
    fs::create_dir_all(&windsurf).unwrap();
    fs::write(windsurf.join("state.vscdb"), "not a database").unwrap();
    fs::write(
        windsurf.join("storage.json"),
        r#"{"profileAssociations":{"workspaces":{"file:///srv/cx-m0p7-editors/wind":"x"}}}"#,
    )
    .unwrap();
    // Zed: local rows only, one root per line, a file root left out.
    let zed_db = zed.join("db/0-stable");
    fs::create_dir_all(&zed_db).unwrap();
    let db = rusqlite::Connection::open(zed_db.join("db.sqlite")).unwrap();
    db.execute_batch(
        "CREATE TABLE workspaces (workspace_id INTEGER PRIMARY KEY, paths TEXT, paths_order TEXT,
           remote_connection_id INTEGER, timestamp TEXT DEFAULT CURRENT_TIMESTAMP NOT NULL);
         INSERT INTO workspaces VALUES (1, '/srv/cx-m0p7-editors/app', '0', NULL, '2026-10-02 00:31:29');
         INSERT INTO workspaces VALUES (2, '/srv/cx-m0p7-editors/one' || char(10) || '/srv/cx-m0p7-editors/two/main.rs', '0,1', NULL, '2026-09-28 05:53:28');
         INSERT INTO workspaces VALUES (3, '/home/me/remote', '0', 7, '2026-10-03 00:00:00');
         INSERT INTO workspaces VALUES (4, '/srv/cx-m0p7-editors/three.js', '0', NULL, '2026-09-01 00:00:00');",
    )
    .unwrap();
    drop(db);

    daemon.mutate("project.sync", json!({"existing": [], "gone": []}), "s-1");
    let projects = daemon.list(json!({}));
    let mut paths: Vec<&str> =
        projects.iter().filter_map(|project| project["path"].as_str()).collect();
    paths.sort_unstable();
    assert_eq!(
        paths,
        vec![
            "/srv/cx-m0p7-editors/My Web",
            "/srv/cx-m0p7-editors/api",
            "/srv/cx-m0p7-editors/app",
            "/srv/cx-m0p7-editors/one",
            "/srv/cx-m0p7-editors/three.js",
        ],
        "{projects:?}"
    );
    let app = find(&projects, "/srv/cx-m0p7-editors/app");
    assert!(app["sources"]["cursor"].is_object() && app["sources"]["zed"].is_object(), "{app}");
    assert_eq!(app["sources"]["zed"]["last_used_ms"], "1790901089000", "Zed's UTC time");
    let web = find(&projects, "/srv/cx-m0p7-editors/My Web");
    assert_eq!(
        web["sources"]["cursor"]["last_used_ms"], "1",
        "a later recent entry gets only its rank"
    );
    assert!(find(&projects, "/srv/cx-m0p7-editors/api")["sources"]["vscode"].is_object());

    // Cursor forgets one: the next sync drops Cursor from it.
    let db = rusqlite::Connection::open(cursor.join("state.vscdb")).unwrap();
    db.execute(
        "INSERT INTO ItemTable(key, value) VALUES('history.recentlyOpenedPathsList', ?1)",
        [r#"{"entries":[{"folderUri":"file:///srv/cx-m0p7-editors/app"}]}"#],
    )
    .unwrap();
    drop(db);
    daemon.mutate("project.sync", json!({"existing": [], "gone": []}), "s-2");
    let projects = daemon.list(json!({"include_hidden": true}));
    let web = projects.iter().find(|project| project["path"] == "/srv/cx-m0p7-editors/My Web");
    assert!(web.is_none_or(|web| web["sources"]["cursor"].is_null()), "{projects:?}");
    assert!(find(&projects, "/srv/cx-m0p7-editors/app")["sources"]["cursor"].is_object());
}

#[test]
fn projects_daemon_sync_imports_codex_app_t3code_and_conductor_projects() {
    let daemon = Daemon::start("apps");
    let home = daemon.dir.join("home");
    let (config, _) = editor_dirs(&home);

    // The Codex desktop app: a project made there, and a folder opened without one.
    fs::create_dir_all(home.join(".codex")).unwrap();
    fs::write(
        home.join(".codex/.codex-global-state.json"),
        r#"{"local-projects":{"local-1":{"id":"local-1","name":"Site","rootPaths":["/srv/cx-m0p7-apps/site"],
            "createdAt":1784592037656,"updatedAt":1784592037656}},
            "electron-saved-workspace-roots":["/srv/cx-m0p7-apps/site","/srv/cx-m0p7-apps/loose"]}"#,
    )
    .unwrap();
    // t3code: a live project and a deleted one.
    fs::create_dir_all(home.join(".t3/userdata")).unwrap();
    let db = rusqlite::Connection::open(home.join(".t3/userdata/statev2.sqlite")).unwrap();
    db.execute_batch(
        "CREATE TABLE projection_projects (project_id TEXT PRIMARY KEY, title TEXT NOT NULL,
           workspace_root TEXT NOT NULL, scripts_json TEXT NOT NULL, created_at TEXT NOT NULL,
           updated_at TEXT NOT NULL, deleted_at TEXT);
         INSERT INTO projection_projects VALUES ('p1', 'T3', '/srv/cx-m0p7-apps/t3', '[]',
           '2026-03-25T03:56:09.344Z', '2026-10-06T09:20:40.009Z', NULL);
         INSERT INTO projection_projects VALUES ('p2', 'Old', '/srv/cx-m0p7-apps/old', '[]',
           '2026-03-25T03:56:09.344Z', '2026-03-25T03:56:09.344Z', '2026-04-01T00:00:00.000Z');",
    )
    .unwrap();
    drop(db);
    // Conductor: a shown repo and a hidden one.
    fs::create_dir_all(config.join("com.conductor.app")).unwrap();
    let db = rusqlite::Connection::open(config.join("com.conductor.app/conductor.db")).unwrap();
    db.execute_batch(
        "CREATE TABLE repos (id TEXT PRIMARY KEY, name TEXT, root_path TEXT,
           created_at TEXT NOT NULL, updated_at TEXT NOT NULL, hidden INTEGER DEFAULT 0);
         INSERT INTO repos VALUES ('r1', 'cond', '/srv/cx-m0p7-apps/cond', '2026-04-16 08:50:04', '2026-04-16 08:50:04', 0);
         INSERT INTO repos VALUES ('r2', 'hid', '/srv/cx-m0p7-apps/hid', '2026-04-16 08:50:04', '2026-04-16 08:50:04', 1);",
    )
    .unwrap();
    drop(db);

    daemon.mutate("project.sync", json!({"existing": [], "gone": []}), "a-1");
    let projects = daemon.list(json!({}));
    let mut paths: Vec<&str> =
        projects.iter().filter_map(|project| project["path"].as_str()).collect();
    paths.sort_unstable();
    assert_eq!(
        paths,
        vec![
            "/srv/cx-m0p7-apps/cond",
            "/srv/cx-m0p7-apps/loose",
            "/srv/cx-m0p7-apps/site",
            "/srv/cx-m0p7-apps/t3"
        ],
        "{projects:?}"
    );
    let site = find(&projects, "/srv/cx-m0p7-apps/site");
    assert_eq!(site["sources"]["codex-app"]["last_used_ms"], "1784592037656", "{site}");
    assert_eq!(
        find(&projects, "/srv/cx-m0p7-apps/t3")["sources"]["t3code"]["last_used_ms"],
        "1791278440009"
    );
    assert!(find(&projects, "/srv/cx-m0p7-apps/cond")["sources"]["conductor"].is_object());
}

#[test]
fn projects_daemon_watch_picks_up_a_new_codex_app_project_and_keeps_user_edits() {
    let daemon = Daemon::start("watch");
    let state = daemon.dir.join("home/.codex/.codex-global-state.json");
    let write_projects = |roots: &[&str]| {
        let projects: serde_json::Map<String, Value> = roots
            .iter()
            .enumerate()
            .map(|(index, root)| {
                (format!("local-{index}"), json!({"id": format!("local-{index}"), "name": "p",
                    "rootPaths": [root], "createdAt": 1_784_592_037_656_i64, "updatedAt": 1_784_592_037_656_i64}))
            })
            .collect();
        // The app writes a temporary file and renames it over the state file.
        let temporary = daemon.dir.join("home/.codex/..codex-global-state.json.tmp-1");
        fs::write(&temporary, json!({"local-projects": projects}).to_string()).unwrap();
        fs::rename(&temporary, &state).unwrap();
    };
    let wait_for = |what: &str, done: &dyn Fn(&[Value]) -> bool| {
        let deadline = Instant::now() + Duration::from_secs(20);
        loop {
            let projects = daemon.list(json!({"include_hidden": true}));
            if done(&projects) {
                return projects;
            }
            assert!(Instant::now() < deadline, "{what}: {projects:?}");
            std::thread::sleep(Duration::from_millis(50));
        }
    };

    // The chat index already reported the folder (source codex).
    let app = "/srv/cx-m0p7-watch/app";
    daemon.mutate(
        "project.observe",
        json!({"source": "codex", "entries": [{"path": app, "last_used_ms": "5"}], "complete": true}),
        "w-1",
    );
    // A project made in the app after the import: it appears, merged with the
    // chat index's row (no duplicate).
    write_projects(&[app, "/srv/cx-m0p7-watch/new"]);
    let projects = wait_for("the new project appears", &|projects| {
        projects.iter().any(|project| project["path"] == "/srv/cx-m0p7-watch/new")
    });
    assert_eq!(projects.iter().filter(|project| project["path"] == app).count(), 1, "{projects:?}");
    let merged = find(&projects, app);
    assert!(
        merged["sources"]["codex"].is_object() && merged["sources"]["codex-app"].is_object(),
        "{merged}"
    );

    // The user's rename and removal win over the next resync.
    daemon.mutate("project.update", json!({"path": app, "rename": "Mine"}), "w-2");
    daemon.mutate("project.remove", json!({"path": "/srv/cx-m0p7-watch/new"}), "w-3");
    write_projects(&[app, "/srv/cx-m0p7-watch/new", "/srv/cx-m0p7-watch/third"]);
    let projects = wait_for("the third project appears", &|projects| {
        projects.iter().any(|project| project["path"] == "/srv/cx-m0p7-watch/third")
    });
    assert_eq!(find(&projects, app)["name"], "Mine");
    assert_eq!(find(&projects, "/srv/cx-m0p7-watch/new")["overlay"]["hidden"], true);
    assert!(
        daemon.list(json!({})).iter().all(|project| project["path"] != "/srv/cx-m0p7-watch/new")
    );
}

#[test]
fn projects_daemon_a_source_turned_off_leaves_and_is_ignored_until_turned_on() {
    let daemon = Daemon::start("toggles");
    let both = "/srv/cx-m0p7-toggles/both";
    let only = "/srv/cx-m0p7-toggles/only-claude";
    let edited = "/srv/cx-m0p7-toggles/edited";
    let report = |entries: Value, key: &str| {
        daemon.mutate(
            "project.observe",
            json!({"source": "claude-code", "entries": entries, "complete": true}),
            key,
        )
    };
    report(
        json!([{"path": both, "last_used_ms": "1"}, {"path": only, "last_used_ms": "1"}, {"path": edited, "last_used_ms": "1"}]),
        "t-1",
    );
    daemon.mutate(
        "project.observe",
        json!({"source": "codex", "entries": [{"path": both, "last_used_ms": "2"}]}),
        "t-2",
    );
    daemon.mutate("project.update", json!({"path": edited, "pinned": true}), "t-3");

    daemon.mutate(
        "project.source.update",
        json!({"source": "claude-code", "enabled": false}),
        "t-4",
    );
    let list = daemon.send("project.list", json!({"include_hidden": true}), None).unwrap();
    let projects = list["projects"].as_array().cloned().unwrap();
    assert!(
        projects.iter().all(|project| project["path"] != only),
        "only Claude listed it: it goes: {projects:?}"
    );
    assert_eq!(
        find(&projects, both)["sources"],
        json!({"codex": find(&projects, both)["sources"]["codex"]})
    );
    assert!(
        find(&projects, edited)["overlay"]["pinned"] == true,
        "an edited project keeps its edits"
    );
    let sources = list["sources"].as_array().cloned().unwrap();
    let claude = sources.iter().find(|source| source["id"] == "claude-code").unwrap();
    assert_eq!(claude["enabled"], false, "{sources:?}");
    assert_eq!(claude["projects"], 0);
    assert_eq!(sources.iter().find(|source| source["id"] == "codex").unwrap()["projects"], 1);

    // Its reports are ignored while it is off (the user wins), and count again once on.
    report(json!([{"path": only, "last_used_ms": "3"}]), "t-5");
    assert!(daemon.list(json!({})).iter().all(|project| project["path"] != only));
    daemon.mutate(
        "project.source.update",
        json!({"source": "claude-code", "enabled": true}),
        "t-6",
    );
    report(json!([{"path": only, "last_used_ms": "4"}]), "t-7");
    assert!(find(&daemon.list(json!({})), only)["sources"]["claude-code"].is_object());

    // The user source cannot be turned off.
    let refused = daemon.send(
        "project.source.update",
        json!({"source": "user", "enabled": false}),
        Some("t-8"),
    );
    assert_eq!(refused.unwrap_err()["code"], "validation.invalid");
}
