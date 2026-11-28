use super::*;
use std::cell::Cell;
use std::collections::BTreeMap;

use serde_json::json;

use crate::store::SessionMeta;

fn meta(cwd: &str) -> SessionMeta {
    serde_json::from_value(json!({
        "schema": crate::store::META_SCHEMA, "id": "s1", "name": "lane", "harness": "claude",
        "cwd": cwd, "createdAt": 1, "updatedAt": 1, "status": "idle",
    }))
    .unwrap()
}

/// One start of `meta`'s agent: its tool listing read (or derived, counted in `derives`), and
/// what it recorded kept on the meta, as `note_launch` keeps it.
fn start(on: bool, meta: &mut SessionMeta, derives: &Cell<u32>) {
    let cwd = meta.cwd.clone();
    let all = all_tools_with(on, meta.manifest.as_ref(), &cwd, || {
        derives.set(derives.get() + 1);
        true
    });
    let servers = json!([{"name": "cmux"}, {"name": "cmux-agent-memory"}]);
    if let Some(m) = to_record(on, meta.manifest.as_ref(), &cwd, all, Some(&servers)) {
        meta.manifest = Some(m);
    }
}

/// A move: the bundle carries `session.json`, and the target writes the chat's folder there
/// into it (`transfer_in.rs`), rebinding the manifest.
fn moved(meta: &SessionMeta, there: &str) -> SessionMeta {
    let mut value = serde_json::to_value(meta).unwrap();
    value["cwd"] = json!(there);
    rebind(&mut value, there);
    serde_json::from_value(value).unwrap()
}

/// A fork in `cwd`: its meta copies its parent's manifest (`hub/fork.rs`).
fn forked(parent: &SessionMeta, cwd: &str) -> SessionMeta {
    let mut fork = meta(cwd);
    fork.manifest = for_fork(parent.manifest.as_ref(), std::path::Path::new(cwd));
    fork
}

/// Start, move, start there, fork there, start the fork: how many starts derived the tools.
fn lifecycle(on: bool) -> (u32, u32, u32) {
    let derives = Cell::new(0);
    let mut chat = meta("/home/a/repo");
    start(on, &mut chat, &derives);
    let first = derives.get();
    let mut there = moved(&chat, "/home/b/checkouts/repo");
    start(on, &mut there, &derives);
    let after_move = derives.get() - first;
    let mut fork = forked(&there, "/home/b/checkouts/repo");
    start(on, &mut fork, &derives);
    let after_fork = derives.get() - first - after_move;
    (first, after_move, after_fork)
}

#[test]
fn moves_and_forks_re_deriving_the_tools_before_and_after() {
    // Off (today): every start derives, the first and each one after a move or a fork.
    assert_eq!(lifecycle(false), (1, 1, 1));
    // On: the first start derives and records; the move and the fork read the record.
    assert_eq!(lifecycle(true), (1, 0, 0));
}

#[test]
fn off_records_nothing_and_an_old_session_json_reads_without_one() {
    let derives = Cell::new(0);
    let mut chat = meta("/r");
    start(false, &mut chat, &derives);
    assert_eq!(chat.manifest, None);
    let saved = serde_json::to_value(&chat).unwrap();
    assert!(saved.get("manifest").is_none(), "an off daemon writes the same session.json");
}

#[test]
fn the_record_holds_what_the_first_start_used_and_is_kept_once() {
    let derives = Cell::new(0);
    let mut chat = meta("/r");
    start(true, &mut chat, &derives);
    let m = chat.manifest.clone().unwrap();
    assert_eq!(m.folder, std::path::PathBuf::from("/r"));
    assert!(m.all_tools);
    assert_eq!(m.servers, vec!["cmux".to_owned(), "cmux-agent-memory".to_owned()]);
    start(true, &mut chat, &derives);
    assert_eq!(derives.get(), 1);
    assert_eq!(chat.manifest, Some(m));
}

#[test]
fn a_fork_into_another_folder_derives_its_own() {
    let derives = Cell::new(0);
    let mut chat = meta("/r");
    start(true, &mut chat, &derives);
    let mut fork = forked(&chat, "/elsewhere");
    assert_eq!(fork.manifest, None);
    start(true, &mut fork, &derives);
    assert_eq!(derives.get(), 2);
    assert_eq!(fork.manifest.unwrap().folder, std::path::PathBuf::from("/elsewhere"));
}

#[test]
fn a_folder_that_changed_under_the_record_is_derived_again() {
    let calls = Cell::new(0);
    let kept = SessionManifest {
        folder: "/old".into(),
        all_tools: true,
        servers: Vec::new(),
        codex: None,
    };
    let all = all_tools_with(true, Some(&kept), std::path::Path::new("/new"), || {
        calls.set(calls.get() + 1);
        false
    });
    assert!(!all);
    assert_eq!(calls.get(), 1);
}

/// One Claude Code start of `meta`'s agent through its command build: the hub marks the profile
/// env, the build reads the mark or derives (counted in `derives`), and the first start records.
fn claude_start(on: bool, meta: &mut SessionMeta, derives: &Cell<u32>) {
    let cwd = meta.cwd.clone();
    let mut env = BTreeMap::new();
    mark_with(on, &mut env, meta.manifest.as_ref(), &cwd);
    let all = claude_all_tools(&env, || {
        derives.set(derives.get() + 1);
        true
    });
    if let Some(m) = to_record(on, meta.manifest.as_ref(), &cwd, all, None) {
        meta.manifest = Some(m);
    }
}

#[test]
fn claude_stdio_moves_and_forks_re_deriving_before_and_after() {
    for (on, want) in [(false, (1, 1, 1)), (true, (1, 0, 0))] {
        let derives = Cell::new(0);
        let mut chat = meta("/home/a/repo");
        claude_start(on, &mut chat, &derives);
        let first = derives.get();
        let mut there = moved(&chat, "/home/b/checkouts/repo");
        claude_start(on, &mut there, &derives);
        let after_move = derives.get() - first;
        let mut fork = forked(&there, "/home/b/checkouts/repo");
        claude_start(on, &mut fork, &derives);
        let after_fork = derives.get() - first - after_move;
        assert_eq!((first, after_move, after_fork), want, "switch on: {on}");
    }
}

#[test]
fn the_mark_holds_only_for_its_folder_and_replaces_a_profiles_own() {
    let m = SessionManifest {
        folder: "/repo".into(),
        all_tools: false,
        servers: Vec::new(),
        codex: None,
    };
    let mut env = BTreeMap::from([(RECORDED_ENV.to_owned(), "1".to_owned())]);
    mark_with(true, &mut env, Some(&m), std::path::Path::new("/repo"));
    assert_eq!(env.get(RECORDED_ENV).map(String::as_str), Some("0"));
    // The recorded answer wins without reading settings.
    assert!(!claude_all_tools(&env, || panic!("derived although marked")));
    mark_with(true, &mut env, Some(&m), std::path::Path::new("/elsewhere"));
    assert!(env.get(RECORDED_ENV).is_none());
    mark_with(false, &mut env, Some(&m), std::path::Path::new("/repo"));
    assert!(env.get(RECORDED_ENV).is_none());
}

/// A Codex chat's folder and its fake Codex (`agent_tools_tests.rs`), with its own `CODEX_HOME`.
#[cfg(unix)]
struct CodexChat {
    root: tempfile::TempDir,
    codex: std::path::PathBuf,
    env: BTreeMap<String, String>,
}

#[cfg(unix)]
impl CodexChat {
    fn new() -> Self {
        let root = tempfile::tempdir().unwrap();
        for dir in ["work", "there", "codex-home"] {
            std::fs::create_dir_all(root.path().join(dir)).unwrap();
        }
        std::fs::write(root.path().join("codex-home/config.toml"), "model = \"a\"\n").unwrap();
        let codex = crate::agent_tools::tests_support::fake_codex(root.path());
        crate::agent_tools::tests_support::codex_answers(root.path(), Some("/opt/x"));
        let home = root.path().join("codex-home").to_string_lossy().into_owned();
        let env = BTreeMap::from([("CODEX_HOME".to_owned(), home)]);
        CodexChat { root, codex, env }
    }

    fn dir(&self, name: &str) -> String {
        self.root.path().join(name).to_string_lossy().into_owned()
    }

    /// How many times Codex was asked.
    fn asks(&self) -> usize {
        std::fs::read_to_string(self.root.path().join("calls")).unwrap_or_default().lines().count()
    }

    /// One start (or wake) of `meta`'s Codex agent: the hub marks its profile env, the start asks
    /// Codex or reads the mark, and `note_launch` keeps what it asked.
    fn start(&self, on: bool, meta: &mut SessionMeta) -> crate::codex_cmux_entry::CmuxEntry {
        let cwd = meta.cwd.clone();
        let mut env = self.env.clone();
        mark_with(on, &mut env, meta.manifest.as_ref(), &cwd);
        let argv = vec![self.codex.to_string_lossy().into_owned(), "app-server".to_owned()];
        let answer = crate::agent_tools::CodexAnswer::default();
        let launch =
            crate::agent_tools::CodexLaunch { cwd: &cwd, argv: &argv, answer: Some(&answer) };
        let entry = crate::agent_tools::persons_cmux_entry_under(on, launch, &env);
        if let Some(m) = to_record(on, meta.manifest.as_ref(), &cwd, false, None) {
            meta.manifest = Some(m);
        }
        keep_codex(on, &mut meta.manifest, &cwd, answer.get().and_then(|a| a.record.clone()));
        entry
    }
}

/// Start, wake (an idle chat's agent started again), fork in the same folder: how many of them
/// asked Codex (`codex mcp get cmux`, up to 2 s each).
#[cfg(unix)]
#[test]
fn codex_starts_wakes_and_forks_asking_codex_before_and_after() {
    for (on, want) in [(false, (1, 1, 1)), (true, (1, 0, 0))] {
        let chat = CodexChat::new();
        let mut meta = meta(&chat.dir("work"));
        chat.start(on, &mut meta);
        let first = chat.asks();
        chat.start(on, &mut meta);
        let wake = chat.asks() - first;
        let mut fork = forked(&meta, &chat.dir("work"));
        chat.start(on, &mut fork);
        let after_fork = chat.asks() - first - wake;
        assert_eq!((first, wake, after_fork), want, "switch on: {on}");
    }
}

/// A move to another folder asks once there (the folder is in the digest: Codex's trust and
/// project files are the folder's), and a fork there reads that answer.
#[cfg(unix)]
#[test]
fn a_moved_codex_chat_asks_once_in_its_new_folder() {
    let chat = CodexChat::new();
    let mut meta = meta(&chat.dir("work"));
    chat.start(true, &mut meta);
    let mut there = moved(&meta, &chat.dir("there"));
    chat.start(true, &mut there);
    assert_eq!(chat.asks(), 2);
    let mut fork = forked(&there, &chat.dir("there"));
    chat.start(true, &mut fork);
    assert_eq!(chat.asks(), 2);
}

/// The recorded answer is read only while nothing it depends on changed: the person's config,
/// a project file, the env Codex finds its config with.
#[cfg(unix)]
#[test]
fn a_changed_config_asks_codex_again() {
    let mut chat = CodexChat::new();
    let mut meta = meta(&chat.dir("work"));
    assert!(matches!(
        chat.start(true, &mut meta),
        crate::codex_cmux_entry::CmuxEntry::Stdio { .. }
    ));
    chat.start(true, &mut meta);
    assert_eq!(chat.asks(), 1);
    // The person's config changes: asked again, and the new answer is the one kept.
    std::fs::write(chat.root.path().join("codex-home/config.toml"), "model = \"b\"\n").unwrap();
    crate::agent_tools::tests_support::codex_answers(chat.root.path(), Some("http"));
    assert_eq!(chat.start(true, &mut meta), crate::codex_cmux_entry::CmuxEntry::Http);
    assert_eq!(chat.asks(), 2);
    assert_eq!(chat.start(true, &mut meta), crate::codex_cmux_entry::CmuxEntry::Http);
    assert_eq!(chat.asks(), 2);
    // A project file appears.
    std::fs::create_dir_all(chat.root.path().join("work/.codex")).unwrap();
    std::fs::write(chat.root.path().join("work/.codex/config.toml"), "model = \"c\"\n").unwrap();
    chat.start(true, &mut meta);
    assert_eq!(chat.asks(), 3);
    // The env Codex reads its config with; any other key is not in the digest.
    chat.env.insert("UNRELATED".to_owned(), "1".to_owned());
    chat.start(true, &mut meta);
    assert_eq!(chat.asks(), 3);
    chat.env.insert("CODEX_PROFILE".to_owned(), "work".to_owned());
    chat.start(true, &mut meta);
    assert_eq!(chat.asks(), 4);
}

/// No answer and doubt are never kept (skip on doubt, `codex_cmux_entry.rs`): the next start
/// asks again.
#[cfg(unix)]
#[test]
fn no_answer_and_doubt_are_never_recorded() {
    use crate::codex_cmux_entry::CmuxEntry;
    assert_eq!(CodexRecord::of("k".into(), &CmuxEntry::Unknown), None);
    assert_eq!(CodexRecord::of("k".into(), &CmuxEntry::Doubt("why".into())), None);
    for sure in [
        CmuxEntry::None,
        CmuxEntry::Http,
        CmuxEntry::Stdio { command: "c".into(), args: vec!["a".into()] },
    ] {
        assert_eq!(CodexRecord::of("k".into(), &sure).unwrap().entry(), sure);
    }
    let chat = CodexChat::new();
    // A project file defining `cmux` that the answer does not show it loads: doubt.
    crate::agent_tools::tests_support::codex_answers(chat.root.path(), Some("/opt/x"));
    std::fs::create_dir_all(chat.root.path().join("there/.codex")).unwrap();
    std::fs::write(
        chat.root.path().join("there/.codex/config.toml"),
        "[mcp_servers.cmux]\ncommand = \"/other\"\n",
    )
    .unwrap();
    let mut doubted = meta(&chat.dir("there"));
    assert!(matches!(chat.start(true, &mut doubted), CmuxEntry::Doubt(_)));
    assert_eq!(doubted.manifest.as_ref().and_then(|m| m.codex.clone()), None);
    let before = chat.asks();
    chat.start(true, &mut doubted);
    assert_eq!(chat.asks(), before + 1);
}

/// The marker never reaches the Codex agent or the question's env, and a profile's own is
/// replaced; it holds only for the manifest's folder.
#[test]
fn the_codex_mark_holds_only_for_its_folder() {
    let record = CodexRecord { key: "k".into(), entry: RecordedEntry::Http };
    let m = SessionManifest {
        folder: "/repo".into(),
        all_tools: false,
        servers: Vec::new(),
        codex: Some(record.clone()),
    };
    let mut env = BTreeMap::from([(CODEX_ENV.to_owned(), "forged".to_owned())]);
    mark_with(true, &mut env, Some(&m), std::path::Path::new("/repo"));
    assert_eq!(take_codex(&mut env), Some(record));
    assert!(!env.contains_key(CODEX_ENV));
    env.insert(CODEX_ENV.to_owned(), "forged".to_owned());
    mark_with(true, &mut env, Some(&m), std::path::Path::new("/elsewhere"));
    assert!(!env.contains_key(CODEX_ENV));
    env.insert(CODEX_ENV.to_owned(), "forged".to_owned());
    mark_with(false, &mut env, Some(&m), std::path::Path::new("/repo"));
    assert!(!env.contains_key(CODEX_ENV));
    // A forged marker that does not parse is no record.
    let mut forged = BTreeMap::from([(CODEX_ENV.to_owned(), "{".to_owned())]);
    assert_eq!(take_codex(&mut forged), None);
}
