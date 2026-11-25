//! The switch kit's five fixtures (cmuxterm-hq#23822): duplicate names, uncommitted state,
//! history, unsupported fields and a secret canary. Every fixture also checks that the T3 home is
//! byte-for-byte what it was before the read.

use std::collections::BTreeMap;
use std::fs;
use std::path::{Path, PathBuf};

use rusqlite::Connection;

use super::*;
use crate::sources::laptop::Work;

const CANARY: &str = "sk-ant-CANARY-23822-do-not-carry";

/// The tables and columns T3 Code 0.1.11 has (read from a real `t3 serve` home), trimmed to
/// what the reader looks at plus the ones it must never read.
const SCHEMA: &str = "
CREATE TABLE projection_projects (project_id TEXT PRIMARY KEY, title TEXT NOT NULL,
  workspace_root TEXT NOT NULL, scripts_json TEXT NOT NULL, created_at TEXT, updated_at TEXT,
  deleted_at TEXT, default_model_selection_json TEXT, archived_at TEXT);
CREATE TABLE orchestration_v2_projection_threads (thread_id TEXT PRIMARY KEY, project_id TEXT,
  title TEXT, default_provider TEXT, active_provider_thread_id TEXT, archived_at TEXT,
  deleted_at TEXT, payload_json TEXT);
CREATE TABLE orchestration_v2_projection_provider_threads (provider_thread_id TEXT PRIMARY KEY,
  thread_id TEXT, provider TEXT, payload_json TEXT);
CREATE TABLE orchestration_v2_projection_messages (message_id TEXT PRIMARY KEY, thread_id TEXT,
  role TEXT, payload_json TEXT, search_text TEXT);
CREATE TABLE auth_sessions (id TEXT, token TEXT);
CREATE TABLE peer_environment_links (id TEXT, url TEXT, secret TEXT);
";

struct Fixture {
    _dir: tempfile::TempDir,
    home: PathBuf,
    t3: PathBuf,
    db: Connection,
}

impl Fixture {
    fn new() -> Self {
        let dir = tempfile::tempdir().unwrap();
        let home = dir.path().join("home");
        let t3 = home.join(".t3");
        fs::create_dir_all(t3.join("userdata/secrets")).unwrap();
        fs::write(t3.join("userdata/secrets/cloud-link-ed25519-key-pair.bin"), CANARY).unwrap();
        let db = Connection::open(t3.join(DATABASE)).unwrap();
        db.execute_batch(SCHEMA).unwrap();
        db.execute("INSERT INTO auth_sessions VALUES ('s', ?1)", [CANARY]).unwrap();
        db.execute("INSERT INTO peer_environment_links VALUES ('p', 'https://peer', ?1)", [CANARY])
            .unwrap();
        Self { _dir: dir, home, t3, db }
    }

    fn checkout(&self, rel: &str, remote: &str) -> PathBuf {
        let path = self.home.join(rel);
        fs::create_dir_all(path.join(".git/refs/heads")).unwrap();
        fs::write(path.join(".git/HEAD"), "ref: refs/heads/main\n").unwrap();
        fs::write(path.join(".git/refs/heads/main"), format!("{}\n", "a".repeat(40))).unwrap();
        fs::write(
            path.join(".git/config"),
            format!("[remote \"origin\"]\n\turl = {remote}\n\tfetch = +refs/heads/*:refs/remotes/origin/*\n"),
        )
        .unwrap();
        path
    }

    fn project(&self, id: &str, title: &str, root: &Path, scripts: &str) {
        self.db
            .execute(
                "INSERT INTO projection_projects (project_id, title, workspace_root, scripts_json) VALUES (?1, ?2, ?3, ?4)",
                rusqlite::params![id, title, root.to_string_lossy(), scripts],
            )
            .unwrap();
    }

    fn thread(&self, id: &str, project: &str, branch: &str, worktree: &Path, native: Option<&str>) {
        let provider_thread = format!("pt:{id}");
        let payload = serde_json::json!({
            "branch": branch,
            "worktreePath": worktree,
            "modelSelection": {"instanceId": "claudeAgent", "model": "claude-sonnet-5-5"},
        });
        self.db
            .execute(
                "INSERT INTO orchestration_v2_projection_threads VALUES (?1, ?2, ?3, 'claudeAgent', ?4, NULL, NULL, ?5)",
                rusqlite::params![id, project, format!("thread {id}"), provider_thread, payload.to_string()],
            )
            .unwrap();
        if let Some(native) = native {
            let payload = serde_json::json!({
                "driver": "claudeAgent",
                "nativeThreadRef": {"driver": "claudeAgent", "nativeId": native, "strength": "strong"},
            });
            self.db
                .execute(
                    "INSERT INTO orchestration_v2_projection_provider_threads VALUES (?1, ?2, 'claudeAgent', ?3)",
                    rusqlite::params![provider_thread, id, payload.to_string()],
                )
                .unwrap();
        }
    }

    fn message(&self, thread: &str, n: usize, text: &str) {
        let payload = serde_json::json!({"text": text});
        self.db
            .execute(
                "INSERT INTO orchestration_v2_projection_messages VALUES (?1, ?2, 'user', ?3, ?4)",
                rusqlite::params![format!("m{thread}{n}"), thread, payload.to_string(), text],
            )
            .unwrap();
    }

    /// Every file under the T3 home with its bytes.
    fn snapshot(&self) -> BTreeMap<PathBuf, Vec<u8>> {
        let mut out = BTreeMap::new();
        let mut stack = vec![self.t3.clone()];
        while let Some(dir) = stack.pop() {
            for entry in fs::read_dir(&dir).unwrap().filter_map(Result::ok) {
                let path = entry.path();
                if path.is_dir() {
                    stack.push(path);
                } else {
                    out.insert(path.clone(), fs::read(&path).unwrap());
                }
            }
        }
        out
    }

    /// Reads and plans, checking the T3 home did not change.
    fn plan(&self, git: &dyn GitFacts) -> Plan {
        let before = self.snapshot();
        let catalog = read(&self.t3.join(DATABASE)).unwrap();
        let plan = plan(&self.home, &self.t3, &catalog, git);
        assert_eq!(before, self.snapshot(), "the T3 home changed");
        plan
    }
}

fn clean(_: &Path) -> Work {
    Work::default()
}

#[test]
fn home_dir_prefers_an_absolute_t3code_home() {
    let home = Path::new("/u/me");
    assert_eq!(home_dir(home, None), PathBuf::from("/u/me/.t3"));
    assert_eq!(home_dir(home, Some("relative")), PathBuf::from("/u/me/.t3"));
    assert_eq!(home_dir(home, Some("/data/t3")), PathBuf::from("/data/t3"));
}

#[test]
fn missing_database_says_so() {
    let err = read(Path::new("/nonexistent/statev2.sqlite")).unwrap_err();
    assert!(err.to_string().contains("no T3 Code database"));
}

/// Fixture 1: two projects with one title, one folder listed twice.
#[test]
fn duplicate_names_and_folders() {
    let f = Fixture::new();
    let a = f.checkout("code/app", "https://github.com/acme/app.git");
    let b = f.checkout("work/app", "https://github.com/acme/app-fork.git");
    f.project("p1", "app", &a, "[]");
    f.project("p2", "app", &b, "[]");
    f.project("p3", "app again", &a, "[]");
    let plan = f.plan(&clean);
    let names: Vec<&str> = plan.projects.iter().map(|p| p.name.as_str()).collect();
    assert_eq!(names, ["app", "app-2"]);
    assert!(plan.warnings.iter().any(|w| w.contains("more than once")), "{:?}", plan.warnings);
    assert_eq!(plan.source.kind, SourceKind::AgentClient);
}

/// Fixture 2: a thread worktree with uncommitted and unpushed work becomes its own machine and
/// carries that work.
#[test]
fn uncommitted_worktree_rides_along() {
    let f = Fixture::new();
    let root = f.checkout("code/app", "https://github.com/acme/app.git");
    let wt = f.checkout(".t3/worktrees/app/t3-fix", "https://github.com/acme/app.git");
    f.project("p1", "app", &root, "[]");
    f.thread("t1", "p1", "t3/fix", &wt, None);
    let git = |p: &Path| {
        if p == wt { Work { dirty_files: 3, unpushed_commits: 1 } } else { Work::default() }
    };
    let plan = f.plan(&git);
    assert_eq!(plan.projects.len(), 2);
    let thread = &plan.projects[1];
    assert_eq!(thread.name, "app-t3-fix");
    let repo = thread.repo.as_ref().unwrap();
    assert_eq!((repo.dirty_files, repo.unpushed_commits), (3, 1));
    assert!(repo.carry_worktree());
    assert!(plan.steps().iter().any(|s| matches!(s, crate::Step::CarryWorktree { .. })));
}

/// Fixture 3: the thread's native Claude Code transcript is linked by its session id.
#[test]
fn native_history_is_linked_by_session_id() {
    let f = Fixture::new();
    let root = f.checkout("code/app", "https://github.com/acme/app.git");
    let wt = f.checkout(".t3/worktrees/app/t3-a", "https://github.com/acme/app.git");
    f.project("p1", "app", &root, "[]");
    f.thread("t1", "p1", "t3/a", &wt, Some("078eef12-cdc9-4bff-801d-fb2a04b0cb61"));
    f.thread("t2", "p1", "t3/b", &root, Some("missing-session"));
    for n in 0..4 {
        f.message("t1", n, "hello");
    }
    let folder = f.home.join(".claude/projects").join(laptop::claude_slug(&wt));
    fs::create_dir_all(&folder).unwrap();
    fs::write(folder.join("078eef12-cdc9-4bff-801d-fb2a04b0cb61.jsonl"), "{}\n").unwrap();
    let plan = f.plan(&clean);
    let thread = plan.projects.iter().find(|p| p.name == "app-t3-a").unwrap();
    // The thread's session file rides in the worktree's Claude session folder.
    let slug = laptop::claude_slug(&wt);
    assert!(
        thread.chats.iter().any(|c| c.agent == Agent::Claude && c.path.ends_with(&slug)),
        "{:?}",
        thread.chats
    );
    assert_eq!(
        thread.chats.iter().filter(|c| c.path.contains(&slug)).count(),
        1,
        "the session folder and its file are one carry: {:?}",
        thread.chats
    );
    assert!(thread.notes.iter().any(|n| n.contains("4 messages")));
    assert!(thread.notes.iter().any(|n| n.contains("resumes Claude Code session 078eef12")));
    assert!(plan.warnings.iter().any(|w| w.contains("1 T3 threads name a native session")));
}

/// Fixture 4: scripts, archived and deleted rows, an older schema's threads table, a session id
/// shaped like a path.
#[test]
fn unsupported_fields_are_listed_not_carried() {
    let f = Fixture::new();
    let root = f.checkout("code/app", "https://github.com/acme/app.git");
    let old = f.checkout("code/old", "https://github.com/acme/old.git");
    f.project("p1", "app", &root, r#"[{"name":"dev","command":"npm run dev"}]"#);
    f.project("p2", "old", &old, "[]");
    f.db.execute("UPDATE projection_projects SET archived_at = 'x' WHERE project_id = 'p2'", [])
        .unwrap();
    f.project("p3", "gone", &f.home.join("nowhere"), "[]");
    f.db.execute_batch(
        "CREATE TABLE projection_threads (thread_id TEXT, project_id TEXT, title TEXT, model TEXT,
           branch TEXT, worktree_path TEXT, deleted_at TEXT);",
    )
    .unwrap();
    let legacy = f.checkout(".t3/worktrees/app/legacy", "https://github.com/acme/app.git");
    f.db.execute(
        "INSERT INTO projection_threads VALUES ('t9', 'p1', 'legacy', 'gpt-6', 'legacy', ?1, NULL)",
        [legacy.to_string_lossy()],
    )
    .unwrap();
    f.thread("t2", "p1", "evil", &root, Some("../../etc/passwd"));
    let plan = f.plan(&clean);
    let app = plan.projects.iter().find(|p| p.name == "app").unwrap();
    assert!(app.machine.setup.iter().all(|s| !s.contains("npm run dev")));
    assert!(app.notes.iter().any(|n| n.contains("T3 scripts not carried") && n.contains("dev")));
    assert!(!plan.projects.iter().find(|p| p.name == "old").unwrap().checked);
    assert!(plan.warnings.iter().any(|w| w.contains("is gone")));
    let legacy = plan.projects.iter().find(|p| p.name == "app-legacy").unwrap();
    assert!(legacy.notes.iter().any(|n| n.contains("gpt-6")));
    assert!(app.chats.iter().all(|c| !c.path.contains("passwd")));
    let what: Vec<&str> = plan.unsupported.iter().map(|u| u.what.as_str()).collect();
    assert!(what.contains(&"table auth_sessions"), "{what:?}");
    assert!(what.contains(&"table peer_environment_links"));
    assert!(what.iter().any(|w| w.contains("script commands")));
}

/// Fixture 5: a secret canary in every place T3 keeps one never reaches the plan.
#[test]
fn secret_canary_never_reaches_the_plan() {
    let f = Fixture::new();
    let root = f.checkout("code/app", "https://github.com/acme/app.git");
    let wt = f.checkout(".t3/worktrees/app/t3-a", "https://github.com/acme/app.git");
    f.project(
        "p1",
        "app",
        &root,
        &format!(r#"[{{"name":"deploy","command":"ANTHROPIC_API_KEY={CANARY} ./deploy"}}]"#),
    );
    f.thread("t1", "p1", "t3/a", &wt, None);
    f.message("t1", 0, &format!("my key is {CANARY}"));
    fs::write(f.t3.join("userdata/settings.json"), format!(r#"{{"apiKey":"{CANARY}"}}"#)).unwrap();
    let plan = f.plan(&clean);
    let json = serde_json::to_string(&plan).unwrap();
    assert!(!json.contains("CANARY"), "{json}");
    assert!(plan.projects.iter().all(|p| p.machine.secret_names.is_empty()));
}

/// A thread that ran in the project folder itself is that project's chat, not a second machine
/// for the same folder (which the duplicate check would drop, transcript and all).
#[test]
fn a_thread_in_the_project_folder_joins_the_project() {
    let f = Fixture::new();
    let root = f.checkout("code/app", "https://github.com/acme/app.git");
    f.project("p1", "app", &root, "[]");
    f.thread("t1", "p1", "main", &root, Some("5b1c0f6e-0000-4000-8000-000000000001"));
    let folder = f.home.join(".claude/projects").join(laptop::claude_slug(&root));
    fs::create_dir_all(&folder).unwrap();
    fs::write(folder.join("5b1c0f6e-0000-4000-8000-000000000001.jsonl"), "{}\n").unwrap();
    let plan = f.plan(&clean);
    assert_eq!(plan.projects.len(), 1, "{:?}", plan.projects);
    let slug = laptop::claude_slug(&root);
    assert!(
        plan.projects[0].chats.iter().any(|c| c.path.contains(&slug)),
        "{:?}",
        plan.projects[0]
    );
    assert!(!plan.warnings.iter().any(|w| w.contains("more than once")), "{:?}", plan.warnings);
}

/// A table past the row cap is said in the plan, never cut silently.
#[test]
fn a_table_past_the_row_cap_is_a_warning() {
    let f = Fixture::new();
    f.db.execute_batch(
        "WITH RECURSIVE n(i) AS (SELECT 1 UNION ALL SELECT i + 1 FROM n WHERE i <= 5000)
         INSERT INTO projection_projects (project_id, title, workspace_root, scripts_json, deleted_at)
         SELECT 'p' || i, 'p' || i, '/nowhere', '[]', 'x' FROM n;",
    )
    .unwrap();
    let plan = f.plan(&clean);
    assert!(
        plan.warnings.iter().any(|w| w.contains("projection_projects has more than 5000 rows")),
        "{:?}",
        plan.warnings
    );
}
