//! Synthetic chat-index rows exercise the shared import plan and ledger.
//! No real harness store, credential, or home directory is inspected.

use std::collections::BTreeSet;
use std::path::{Path, PathBuf};
use std::process::Command;

use cmux_chat_index::{AdapterKind, ChatEntry, IndexedChat, Resume, TitleSource};
use cmux_conductor_import::catalog::{Catalog, MAX_ROWS, Repo, Workspace};
use cmux_conductor_import::inspect;
use cmux_conductor_import::ledger::{Ledger, Load};
use cmux_conductor_import::plan::{self, Disposition};
use cmux_conductor_import::tools;

const PRIVATE_TITLE: &str = "private-chat-title-must-not-leave-index";
const PRIVATE_ENV: &str = "private-env-value-must-not-leave-settings";

fn git(dir: &Path, args: &[&str]) {
    let output = Command::new("git")
        .args([
            "-c",
            "user.name=fixture",
            "-c",
            "user.email=fixture@example.invalid",
            "-c",
            "init.defaultBranch=main",
            "-c",
            "commit.gpgsign=false",
        ])
        .args(args)
        .current_dir(dir)
        .output()
        .expect("fixture git runs");
    assert!(output.status.success(), "git {args:?}: {}", String::from_utf8_lossy(&output.stderr));
}

struct Fixture {
    _dir: tempfile::TempDir,
    home: PathBuf,
    repo: PathBuf,
    worktree: PathBuf,
}

impl Fixture {
    fn new() -> Self {
        let dir = tempfile::tempdir().unwrap();
        let home = dir.path().canonicalize().unwrap();
        let repo = home.join("app");
        let worktree = home.join("linked");
        std::fs::create_dir(&repo).unwrap();
        git(&repo, &["init", "-q"]);
        std::fs::write(repo.join("README"), "synthetic repository\n").unwrap();
        git(&repo, &["add", "README"]);
        git(&repo, &["commit", "-qm", "fixture"]);
        git(&repo, &["worktree", "add", "-q", "-b", "feature", worktree.to_str().unwrap()]);
        Self { _dir: dir, home, repo, worktree }
    }

    fn chat(&self, tool: AdapterKind, cwd: &Path) -> IndexedChat {
        IndexedChat {
            entry: ChatEntry {
                harness: tool,
                session_id: "shared-session-id".into(),
                title: Some(PRIVATE_TITLE.into()),
                title_source: Some(TitleSource::Custom),
                cwd: Some(cwd.to_string_lossy().into_owned()),
                created_ms: Some(1),
                updated_ms: 2,
                message_count: Some(2),
                source_path: self.home.join("stores").join(tool.id()).join("chat.jsonl"),
                originator: None,
                archived: false,
                resume: Resume::Adopt,
            },
            accounts: vec!["private-account-label".into()],
            roots: vec!["synthetic-root".into()],
        }
    }

    fn conductor(&self) -> Catalog {
        Catalog {
            database: self.home.join("conductor.db"),
            repos: vec![Repo {
                id: "conductor-repo".into(),
                name: "Existing project".into(),
                root_path: Some(self.repo.clone()),
                setup_script: Some("npm ci".into()),
                archive_script: Some("npm run teardown".into()),
                ..Repo::default()
            }],
            workspaces: vec![Workspace {
                id: "conductor-workspace".into(),
                repo_id: "conductor-repo".into(),
                branch: Some("feature".into()),
                state: "ready".into(),
                path: Some(self.worktree.clone()),
                ..Workspace::default()
            }],
        }
    }
}

#[test]
fn tools_share_one_worktree_but_keep_distinct_session_namespaces() {
    let f = Fixture::new();
    let chats = [AdapterKind::ClaudeCode, AdapterKind::Codex, AdapterKind::OpenCode]
        .map(|tool| f.chat(tool, &f.worktree));
    let rows = chats.iter().chain(std::iter::once(&chats[0]));
    let found = tools::catalog(Catalog::default(), rows, &|_| true).unwrap();

    assert_eq!(found.catalog.repos.len(), 1);
    assert_eq!(found.catalog.repos[0].root_path.as_ref(), Some(&f.repo));
    assert_eq!(found.catalog.workspaces.len(), 1);
    let workspace = &found.catalog.workspaces[0];
    assert_eq!(workspace.path.as_ref(), Some(&f.worktree));
    assert_eq!(workspace.branch.as_deref(), Some("feature"));
    let sources = &found.chats[&workspace.id];
    assert_eq!(sources.len(), 3, "repeated index rows must not duplicate a chat");
    let tools: BTreeSet<_> = sources.iter().map(|source| source.tool).collect();
    assert_eq!(tools, [AdapterKind::ClaudeCode, AdapterKind::Codex, AdapterKind::OpenCode].into());
    for source in sources {
        assert_eq!(source.session_id, "shared-session-id");
        assert_eq!(source.path, f.home.join("stores").join(source.tool.id()).join("chat.jsonl"));
    }
    assert!(found.unreadable.is_empty());
}

#[test]
fn tools_keep_conductor_identity_and_recipe_without_copying_private_values() {
    let f = Fixture::new();
    std::fs::create_dir(f.repo.join(".conductor")).unwrap();
    let settings = format!(
        "[scripts]\nsetup = \"npm install\"\n[scripts.run.web]\ncommand = \"npm run dev\"\n\
         [environment_variables]\nAPI_TOKEN = \"{PRIVATE_ENV}\"\n"
    );
    std::fs::write(f.repo.join(".conductor/settings.toml"), &settings).unwrap();
    let existing = f.conductor();
    let chat = f.chat(AdapterKind::Codex, &f.worktree);
    let found = tools::catalog(existing.clone(), [&chat], &|_| true).unwrap();
    assert_eq!(found.catalog, existing);
    assert_eq!(found.chats.keys().cloned().collect::<Vec<_>>(), ["conductor-workspace"]);

    let facts = inspect::inspect(&found.catalog, &f.home);
    let plan = plan::plan(&found.catalog, &facts, &Ledger::new(), &BTreeSet::new());
    let project = &plan.projects[0];
    assert_eq!(project.repo_id, "conductor-repo");
    assert_eq!(project.env_names, ["API_TOKEN"]);
    let recipe = project.recipe.as_ref().expect("existing scripts still make a recipe");
    assert_eq!(recipe.setup.as_deref(), Some("npm install"));
    assert_eq!(recipe.teardown.as_deref(), Some("npm run teardown"));
    assert_eq!(recipe.run.as_deref(), Some("npm run dev"));
    for json in [serde_json::to_string(&found).unwrap(), serde_json::to_string(&plan).unwrap()] {
        assert!(!json.contains(PRIVATE_TITLE));
        assert!(!json.contains(PRIVATE_ENV));
        assert!(!json.contains("private-account-label"));
    }
    assert_eq!(std::fs::read_to_string(f.repo.join(".conductor/settings.toml")).unwrap(), settings);
    assert!(!chat.entry.source_path.exists(), "a source reference must not create a transcript");
}

#[test]
fn tools_ignore_main_checkouts_nonrepos_missing_and_relative_folders() {
    let f = Fixture::new();
    let plain = f.home.join("plain");
    std::fs::create_dir(&plain).unwrap();
    let paths = [f.repo.clone(), plain.clone(), f.home.join("missing"), PathBuf::from("relative")];
    let chats = paths.map(|path| f.chat(AdapterKind::ClaudeCode, &path));
    let found = tools::catalog(Catalog::default(), &chats, &|_| true).unwrap();
    assert!(found.catalog.repos.is_empty());
    assert!(found.catalog.workspaces.is_empty());
    assert!(found.chats.is_empty());
    assert_eq!(found.unreadable, [plain]);
}

#[test]
fn tools_map_child_cwd_to_the_linked_worktree() {
    let f = Fixture::new();
    let child = f.worktree.join("packages/app");
    std::fs::create_dir_all(&child).unwrap();
    let chats = [f.chat(AdapterKind::ClaudeCode, &child), f.chat(AdapterKind::Codex, &f.worktree)];
    let found = tools::catalog(Catalog::default(), &chats, &|_| true).unwrap();
    assert_eq!(found.catalog.workspaces.len(), 1);
    let workspace = &found.catalog.workspaces[0];
    assert_eq!(workspace.path.as_ref(), Some(&f.worktree));
    assert_eq!(found.chats[&workspace.id].len(), 2);
}

#[cfg(unix)]
#[test]
fn tools_check_alias_targets_and_preserve_existing_canonical_identity() {
    let f = Fixture::new();
    let alias = f.home.join("alias");
    std::os::unix::fs::symlink(&f.worktree, &alias).unwrap();
    let chat = f.chat(AdapterKind::OpenCode, &alias);
    let denied =
        tools::catalog(Catalog::default(), [&chat], &|path| path != f.worktree.as_path()).unwrap();
    assert!(denied.catalog.workspaces.is_empty());
    assert!(denied.chats.is_empty());
    assert!(denied.unreadable.is_empty(), "a refused target must not reach git inspection");

    let mut existing = f.conductor();
    existing.workspaces[0].path = Some(alias.clone());
    let direct = f.chat(AdapterKind::Codex, &f.worktree);
    let admitted = tools::catalog(existing.clone(), [&chat, &direct], &|_| true).unwrap();
    assert_eq!(admitted.catalog, existing);
    assert_eq!(admitted.chats["conductor-workspace"].len(), 2);
}

#[test]
fn tools_rerun_uses_the_existing_persistent_import_ledger() {
    let f = Fixture::new();
    let chat = f.chat(AdapterKind::Codex, &f.worktree);
    let first = tools::catalog(Catalog::default(), [&chat], &|_| true).unwrap();
    let facts = inspect::inspect(&first.catalog, &f.home);
    let plan = plan::plan(&first.catalog, &facts, &Ledger::new(), &BTreeSet::new());
    let workspace = &plan.projects[0].workspaces[0];
    assert_eq!(workspace.disposition, Disposition::Adopt);
    assert!(workspace.checked);

    let mut ledger = Ledger::new();
    ledger.mark_done(&workspace.id, "cmux-imported-workspace");
    let ledger_path = f.home.join("import-ledger.json");
    ledger.save(&ledger_path).unwrap();
    let Load::Ledger(ledger) = Ledger::load(&ledger_path) else { panic!("ledger round trip") };
    let rerun = tools::catalog(Catalog::default(), [&chat], &|_| true).unwrap();
    let facts = inspect::inspect(&rerun.catalog, &f.home);
    let live = ["cmux-imported-workspace".into()].into();
    let plan = plan::plan(&rerun.catalog, &facts, &ledger, &live);
    let again = &plan.projects[0].workspaces[0];
    assert_eq!(again.id, workspace.id);
    assert_eq!(
        again.disposition,
        Disposition::AlreadyImported { cmux_workspace: "cmux-imported-workspace".into() }
    );
    assert!(!again.checked);
}

#[test]
fn grouped_folders_share_tool_provenance_without_inventing_chats() {
    let f = Fixture::new();
    let child = f.worktree.join("package");
    std::fs::create_dir(&child).unwrap();
    let rows = [
        (AdapterKind::ClaudeCode, f.worktree.clone()),
        (AdapterKind::Codex, child),
        (AdapterKind::OpenCode, f.worktree.clone()),
        (AdapterKind::ClaudeCode, f.worktree.clone()),
    ];
    for existing in [Catalog::default(), f.conductor()] {
        let found = tools::folders(existing.clone(), &rows, &|_| true).unwrap();
        assert_eq!(found.catalog.repos.len(), 1);
        assert_eq!(found.catalog.workspaces.len(), 1);
        let workspace = &found.catalog.workspaces[0];
        assert_eq!(workspace.path.as_ref(), Some(&f.worktree));
        assert_eq!(workspace.repo_id, found.catalog.repos[0].id);
        assert_eq!(
            found.tools[&workspace.id],
            [AdapterKind::ClaudeCode, AdapterKind::Codex, AdapterKind::OpenCode].into()
        );
        assert_eq!(found.tools.len(), 1);
        assert!(found.chats.values().all(Vec::is_empty), "folder rows contain no session identity");
        assert!(found.unreadable.is_empty());
        if !existing.repos.is_empty() {
            assert_eq!(found.catalog, existing, "the Conductor IDs and scripts must survive");
        }
        let facts = inspect::inspect(&found.catalog, &f.home);
        let plan = plan::plan(&found.catalog, &facts, &Ledger::new(), &BTreeSet::new());
        assert_eq!(plan.projects[0].workspaces[0].disposition, Disposition::Adopt);
    }
}

#[test]
fn grouped_folders_count_distinct_paths_instead_of_duplicate_rows() {
    let f = Fixture::new();
    let row = (AdapterKind::Codex, f.worktree.clone());
    let rows = std::iter::repeat_n(&row, tools::MAX_FOLDERS + 1);
    let found = tools::folders(Catalog::default(), rows, &|_| true).unwrap();
    assert_eq!(found.catalog.workspaces.len(), 1);
    let id = &found.catalog.workspaces[0].id;
    assert_eq!(found.tools[id], [AdapterKind::Codex].into());
    assert!(found.chats.values().all(Vec::is_empty));
}

#[test]
fn every_registered_detector_maps_into_the_same_worktree_plan() {
    let f = Fixture::new();
    let rows = AdapterKind::ALL.map(|tool| {
        assert_eq!(AdapterKind::from_id(tool.id()), Some(tool));
        (tool, f.worktree.clone())
    });
    let found = tools::folders(Catalog::default(), &rows, &|_| true).unwrap();
    assert_eq!(found.catalog.workspaces.len(), 1);
    assert_eq!(found.tools[&found.catalog.workspaces[0].id], AdapterKind::ALL.into());
}

#[test]
fn source_row_limit_fails_by_name_instead_of_returning_a_partial_catalog() {
    // Refused rows still consume the source-row budget, without filesystem or git work.
    let row = (AdapterKind::Codex, PathBuf::from("relative"));
    let boundary = tools::folders(Catalog::default(), std::iter::repeat_n(&row, MAX_ROWS), &|_| {
        panic!("relative paths must be rejected before path policy")
    })
    .unwrap();
    assert!(boundary.catalog.workspaces.is_empty());
    let error =
        tools::folders(Catalog::default(), std::iter::repeat_n(&row, MAX_ROWS + 1), &|_| {
            panic!("relative paths must be rejected before path policy")
        })
        .unwrap_err();
    assert_eq!(error, format!("agent import has more than {MAX_ROWS} source rows"));

    let f = Fixture::new();
    let chat = f.chat(AdapterKind::ClaudeCode, Path::new("relative"));
    let error =
        tools::catalog(Catalog::default(), std::iter::repeat_n(&chat, MAX_ROWS + 1), &|_| {
            panic!("relative paths must be rejected before path policy")
        })
        .unwrap_err();
    assert_eq!(error, format!("agent import has more than {MAX_ROWS} source rows"));
}

#[test]
fn distinct_folder_limit_fails_by_name_before_inspecting_git() {
    let dir = tempfile::tempdir().unwrap();
    let root = dir.path().canonicalize().unwrap();
    let rows: Vec<_> = (0..=tools::MAX_FOLDERS)
        .map(|index| {
            let path = root.join(format!("folder-{index}"));
            std::fs::create_dir(&path).unwrap();
            (AdapterKind::OpenCode, path)
        })
        .collect();
    let error = tools::folders(Catalog::default(), &rows, &|_| true).unwrap_err();
    assert_eq!(error, format!("agent import has more than {} folders", tools::MAX_FOLDERS));
}

#[test]
fn grouped_folder_inspection_reuses_verified_listings_and_branches() {
    let f = Fixture::new();
    let child = f.worktree.join("package");
    std::fs::create_dir(&child).unwrap();
    let rows = [(AdapterKind::ClaudeCode, f.worktree.clone()), (AdapterKind::Codex, child)];
    let found = tools::folders(f.conductor(), &rows, &|_| true).unwrap();
    let fresh = inspect::inspect(&found.catalog, &f.home);
    let cached = found.inspect(&f.home);
    assert_eq!(cached, fresh);
    assert!(cached.workspaces["conductor-workspace"].branch_exists);
    let ledger = Ledger::new();
    let live = BTreeSet::new();
    let expected = plan::plan(&found.catalog, &fresh, &ledger, &live);

    // Make a second Git read fail without changing either worktree's files.
    // The cached facts must still use the verified listing and listed branch.
    let saved_git = f.home.join("saved-git-metadata");
    std::fs::rename(f.repo.join(".git"), &saved_git).unwrap();
    let cached_without_git = found.inspect(&f.home);
    let uncached_without_git = inspect::inspect(&found.catalog, &f.home);
    std::fs::rename(&saved_git, f.repo.join(".git")).unwrap();

    assert_eq!(cached_without_git, fresh);
    assert!(uncached_without_git.repos["conductor-repo"].unusable.is_some());
    assert_eq!(plan::plan(&found.catalog, &cached_without_git, &ledger, &live), expected);
    let serialized = serde_json::to_value(&found).unwrap();
    assert!(serialized.get("listings").is_none(), "verified Git metadata is not import output");

    let fallback = tools::ToolCatalog::from(found.catalog.clone());
    assert_eq!(fallback.inspect(&f.home), fresh, "Conductor fallback retains uncached inspection");
}
