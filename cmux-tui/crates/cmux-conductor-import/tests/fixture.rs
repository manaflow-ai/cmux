//! Import from Conductor against a fixture: a git repository with
//! Conductor-style worktrees under `~/conductor/workspaces`, a
//! `conductor.db` built the way Conductor lays it out (schema read by
//! getpaseo/import at `user_version` 112), its `.conductor/settings.toml`
//! and a Claude Code transcript. Conductor itself is not needed.

use std::collections::BTreeSet;
use std::path::{Path, PathBuf};
use std::process::Command;

use cmux_conductor_import::catalog::{self, ReadError};
use cmux_conductor_import::detect;
use cmux_conductor_import::inspect;
use cmux_conductor_import::ledger::Ledger;
use cmux_conductor_import::plan::{self, Disposition, Plan, SkipReason};

fn git(dir: &Path, args: &[&str]) -> String {
    let output = Command::new("git")
        .args(["-c", "user.name=t", "-c", "user.email=t@t", "-c", "init.defaultBranch=main"])
        .args(args)
        .current_dir(dir)
        .output()
        .expect("git runs");
    assert!(output.status.success(), "git {args:?}: {}", String::from_utf8_lossy(&output.stderr));
    String::from_utf8_lossy(&output.stdout).trim().to_string()
}

struct Fixture {
    _dir: tempfile::TempDir,
    home: PathBuf,
    repo: PathBuf,
    workspaces: PathBuf,
    archived_commit: String,
}

fn fixture() -> Fixture {
    let dir = tempfile::tempdir().unwrap();
    let home = dir.path().canonicalize().unwrap();
    let repo = home.join("src").join("app");
    std::fs::create_dir_all(&repo).unwrap();
    git(&repo, &["init", "-q"]);
    std::fs::write(repo.join("README"), "app\n").unwrap();
    git(&repo, &["add", "."]);
    git(&repo, &["commit", "-qm", "init"]);
    std::fs::create_dir_all(repo.join(".conductor")).unwrap();
    std::fs::write(
        repo.join(".conductor/settings.toml"),
        r#"
file_include_globs = [".env", ".env.local"]

[scripts]
setup = "bun install && cp \"$CONDUCTOR_ROOT_PATH/.env\" ."

[scripts.run.web]
command = "PORT=$CONDUCTOR_PORT bun dev"

[scripts.run.cloudonly]
command = "deploy"
available_in = "cloud"

[environment_variables]
API_KEY = "sk-live-do-not-copy"

[spotlight_testing]
enabled = true
"#,
    )
    .unwrap();

    let workspaces = home.join("conductor").join("workspaces").join("app");
    std::fs::create_dir_all(&workspaces).unwrap();
    let lima = workspaces.join("lima");
    git(&repo, &["worktree", "add", "-q", "-b", "leo/lima", lima.to_str().unwrap()]);
    // Archived in Conductor: its folder deleted, its commit kept.
    let oslo = workspaces.join("oslo");
    git(&repo, &["worktree", "add", "-q", "-b", "leo/oslo", oslo.to_str().unwrap()]);
    std::fs::write(oslo.join("work"), "w\n").unwrap();
    git(&oslo, &["add", "."]);
    git(&oslo, &["commit", "-qm", "oslo work"]);
    let archived_commit = git(&oslo, &["rev-parse", "HEAD"]);
    git(&repo, &["worktree", "remove", "--force", oslo.to_str().unwrap()]);
    git(&repo, &["branch", "-D", "leo/oslo"]);
    // A folder Conductor lists that is not a worktree of the repository.
    std::fs::create_dir_all(workspaces.join("plain")).unwrap();

    // Claude Code's transcripts for the live workspace.
    let slug = cmux_conductor_import::chats::claude_slug(&lima);
    let claude = home.join(".claude").join("projects").join(slug);
    std::fs::create_dir_all(&claude).unwrap();
    std::fs::write(claude.join("a.jsonl"), "{}\n").unwrap();

    let db = detect::database_path(&home);
    std::fs::create_dir_all(db.parent().unwrap()).unwrap();
    let connection = rusqlite::Connection::open(&db).unwrap();
    connection
        .execute_batch(&format!(
            "PRAGMA user_version = 112;
             CREATE TABLE repos (id TEXT PRIMARY KEY, root_path TEXT, name TEXT, is_hidden INTEGER,
                 setup_script TEXT, archive_script TEXT, run_scripts_json TEXT, updated_at TEXT);
             CREATE TABLE workspaces (id TEXT PRIMARY KEY, repo_id TEXT, branch TEXT, state TEXT,
                 path TEXT, archive_commit TEXT, directory_name TEXT);
             INSERT INTO repos VALUES ('r1', '{repo}', 'app', 0, 'npm ci', 'rm -rf node_modules', NULL, NULL);
             INSERT INTO repos VALUES ('r2', '/nowhere/gone', 'gone', 0, NULL, NULL, NULL, NULL);
             INSERT INTO repos VALUES ('r3', '{repo}', 'hidden', 1, NULL, NULL, NULL, NULL);
             INSERT INTO workspaces VALUES ('w-lima', 'r1', 'refs/heads/leo/lima', 'ready', '{lima}', NULL, 'lima');
             INSERT INTO workspaces VALUES ('w-oslo', 'r1', 'leo/oslo', 'archived', '{oslo}', '{archived_commit}', 'oslo');
             INSERT INTO workspaces VALUES ('w-plain', 'r1', 'leo/plain', 'ready', '{plain}', NULL, 'plain');
             INSERT INTO workspaces VALUES ('w-lost', 'r1', 'leo/lost', 'archived', '/nowhere/lost', 'deadbeef', 'lost');
             INSERT INTO workspaces VALUES ('w-cloud', 'r1', 'leo/c', 'ready', '{cloud}', NULL, 'c');
             INSERT INTO workspaces VALUES ('w-orphan', 'r9', 'x', 'ready', '/x', NULL, 'x');",
            repo = repo.display(),
            lima = lima.display(),
            oslo = oslo.display(),
            plain = workspaces.join("plain").display(),
            cloud = home.join("conductor/cloud-workspaces/app/c").display(),
        ))
        .unwrap();
    drop(connection);
    Fixture { _dir: dir, home, repo, workspaces, archived_commit }
}

fn dry_run(f: &Fixture, ledger: &Ledger, live: &BTreeSet<String>) -> Plan {
    let found = detect::detect_with_apps(&f.home, &[]);
    let catalog = catalog::read(found.database.as_deref().expect("conductor.db found")).unwrap();
    let facts = inspect::inspect(&catalog, &f.home);
    plan::plan(&catalog, &facts, ledger, live)
}

fn workspace<'a>(plan: &'a Plan, id: &str) -> &'a plan::WorkspacePlan {
    plan.projects.iter().flat_map(|p| &p.workspaces).find(|w| w.id == id).unwrap()
}

#[test]
fn detects_database_and_workspaces_folder() {
    let f = fixture();
    let found = detect::detect_with_apps(&f.home, &[]);
    assert!(found.any());
    assert!(found.database.is_some());
    assert_eq!(found.workspaces.as_deref(), Some(f.home.join("conductor/workspaces").as_path()));
    assert!(found.app.is_none());
    assert!(!detect::detect_with_apps(&f.home.join("empty"), &[]).any());
}

#[test]
fn plan_adopts_live_lists_archived_and_skips_the_rest() {
    let f = fixture();
    let plan = dry_run(&f, &Ledger::new(), &BTreeSet::new());

    let app = &plan.projects[0];
    assert_eq!(app.path.as_deref(), Some(f.repo.as_path()));
    assert_eq!(app.skipped, None);
    assert_eq!(
        plan.projects[1].skipped.as_deref().map(|s| s.contains("no longer exists")),
        Some(true)
    );
    assert_eq!(plan.projects[2].skipped.as_deref(), Some("hidden in Conductor"));

    let lima = workspace(&plan, "w-lima");
    assert_eq!(lima.disposition, Disposition::Adopt);
    assert!(lima.checked);
    assert_eq!(lima.branch.as_deref(), Some("leo/lima"));
    assert_eq!(lima.path.as_deref(), Some(f.workspaces.join("lima").as_path()));
    assert_eq!(lima.chats.as_ref().map(|c| c.transcripts), Some(1));

    let oslo = workspace(&plan, "w-oslo");
    assert_eq!(oslo.disposition, Disposition::Recoverable { from: f.archived_commit });
    assert!(!oslo.checked);

    let skip = |id| workspace(&plan, id).disposition.clone();
    assert_eq!(skip("w-plain"), Disposition::Skip { reason: SkipReason::NotAWorktree });
    assert_eq!(skip("w-lost"), Disposition::Skip { reason: SkipReason::Gone });
    assert_eq!(skip("w-cloud"), Disposition::Skip { reason: SkipReason::Cloud });

    assert!(plan.warnings.iter().any(|w| w.code == plan::ARCHIVE_DELETES_FOLDER));
    assert!(plan.warnings.iter().any(|w| w.code == plan::ORPHAN_WORKSPACE));
    assert_eq!(plan.cloud_shutdown, "2026-11-20");
}

#[test]
fn scripts_files_and_env_names_never_values() {
    let f = fixture();
    let plan = dry_run(&f, &Ledger::new(), &BTreeSet::new());
    let app = &plan.projects[0];
    // settings.toml wins over the database's setup; the database's archive stays.
    assert_eq!(app.setup.as_deref(), Some("bun install && cp \"$CONDUCTOR_ROOT_PATH/.env\" ."));
    assert_eq!(app.teardown.as_deref(), Some("rm -rf node_modules"));
    assert_eq!(app.run.len(), 1, "the Cloud-only script stays behind");
    assert_eq!(app.run[0].command, "PORT=$CONDUCTOR_PORT bun dev");
    assert_eq!(
        app.aliases,
        [
            ("CONDUCTOR_ROOT_PATH".to_string(), "CMUX_ROOT_PATH".to_string()),
            ("CONDUCTOR_PORT".to_string(), "CMUX_PORT".to_string())
        ]
    );
    assert_eq!(app.worktreeinclude, [".env", ".env.local"]);
    assert_eq!(app.env_names, ["API_KEY"]);
    assert!(app.notes.iter().any(|n| n.code == "not-imported" && n.detail == "spotlight_testing"));
    let json = serde_json::to_string(&plan).unwrap();
    assert!(!json.contains("sk-live-do-not-copy"), "an env value leaked into the plan");
}

#[test]
fn existing_worktreeinclude_lines_are_not_repeated() {
    let f = fixture();
    std::fs::write(f.repo.join(".worktreeinclude"), ".env\n").unwrap();
    let plan = dry_run(&f, &Ledger::new(), &BTreeSet::new());
    assert_eq!(plan.projects[0].worktreeinclude, [".env.local"]);
}

#[test]
fn rerun_is_safe() {
    let f = fixture();
    let mut ledger = Ledger::new();
    ledger.mark_done("w-lima", "ws-1");
    let open: BTreeSet<String> = ["ws-1".to_string()].into();
    let plan = dry_run(&f, &ledger, &open);
    let lima = workspace(&plan, "w-lima");
    assert_eq!(lima.disposition, Disposition::AlreadyImported { cmux_workspace: "ws-1".into() });
    assert!(!lima.checked);

    // Closed in cmux since: offered again, unchecked.
    let plan = dry_run(&f, &ledger, &BTreeSet::new());
    let lima = workspace(&plan, "w-lima");
    assert_eq!(lima.disposition, Disposition::Adopt);
    assert!(!lima.checked);

    // Cut off mid-run: the half-made workspace is closed, then made again.
    let mut ledger = Ledger::new();
    ledger.mark_pending("w-lima");
    ledger.workspaces.get_mut("w-lima").unwrap().cmux_workspace = Some("ws-half".into());
    let plan = dry_run(&f, &ledger, &["ws-half".to_string()].into());
    assert_eq!(plan.cleanup, ["ws-half"]);
    assert!(workspace(&plan, "w-lima").checked);
}

#[test]
fn read_is_read_only() {
    let f = fixture();
    let db = detect::database_path(&f.home);
    let before = std::fs::read(&db).unwrap();
    let _ = dry_run(&f, &Ledger::new(), &BTreeSet::new());
    assert_eq!(std::fs::read(&db).unwrap(), before);
    assert!(!db.with_extension("db-journal").exists());
}

#[test]
fn unknown_layout_is_refused() {
    let dir = tempfile::tempdir().unwrap();
    let db = dir.path().join("conductor.db");
    let connection = rusqlite::Connection::open(&db).unwrap();
    connection.execute_batch("CREATE TABLE repos (id TEXT, name TEXT);").unwrap();
    drop(connection);
    assert!(matches!(catalog::read(&db), Err(ReadError::Schema(_))));
}

#[test]
fn folder_alone_gives_the_live_workspaces() {
    let f = fixture();
    let catalog = inspect::catalog_from_folder(&f.home.join("conductor/workspaces"));
    assert_eq!(catalog.repos.len(), 1);
    assert_eq!(catalog.repos[0].root_path.as_deref(), Some(f.repo.as_path()));
    assert_eq!(catalog.workspaces.len(), 1);
    assert_eq!(catalog.workspaces[0].branch.as_deref(), Some("leo/lima"));
    let facts = inspect::inspect(&catalog, &f.home);
    let plan = plan::plan(&catalog, &facts, &Ledger::new(), &BTreeSet::new());
    assert_eq!(plan.projects[0].workspaces[0].disposition, Disposition::Adopt);
}
