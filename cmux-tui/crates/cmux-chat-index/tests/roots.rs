mod common;

use std::collections::HashMap;
use std::fs;
use std::path::{Path, PathBuf};

use cmux_chat_index::{AdapterKind, DiscoveryInput, RecordedRoots, RootSource, RootSpec, discover};

fn mkdir(path: &Path) -> PathBuf {
    fs::create_dir_all(path).unwrap();
    path.to_path_buf()
}

#[cfg(unix)]
#[test]
fn defaults_env_and_subrouter_homes_merge_by_real_path() {
    use std::os::unix::fs::symlink;
    let dir = tempfile::tempdir().unwrap();
    let home = fs::canonicalize(dir.path()).unwrap();
    let shared = mkdir(&home.join(".claude/projects"));
    mkdir(&home.join(".codex"));
    let custom = mkdir(&home.join("alt-claude/projects"));
    let profiles = mkdir(&home.join(".subrouter/codex/claude"));
    for profile in ["_p1", "_p2"] {
        mkdir(&profiles.join(profile));
        symlink(&shared, profiles.join(profile).join("projects")).unwrap();
    }
    let own = mkdir(&profiles.join("work-acct/projects"));
    mkdir(&profiles.join("_p3")); // no projects dir: no root

    let env: HashMap<&str, String> =
        [("CLAUDE_CONFIG_DIR", home.join("alt-claude").display().to_string())].into();
    let found = discover(&DiscoveryInput {
        home: &home,
        env: &|key| env.get(key).cloned(),
        refuse: &|_| None,
        recorded: &[],
        user: &[],
    });
    let claude: Vec<_> =
        found.roots.iter().filter(|root| root.harness == AdapterKind::ClaudeCode).collect();
    assert_eq!(claude.len(), 3, "{claude:#?}");
    assert_eq!((claude[0].path.clone(), claude[0].source), (custom, RootSource::Env));
    assert_eq!((claude[1].path.clone(), claude[1].source), (shared, RootSource::Default));
    assert_eq!(
        claude[1].aliases,
        vec![profiles.join("_p1/projects"), profiles.join("_p2/projects")]
    );
    assert_eq!(claude[1].accounts, vec!["_p1".to_owned(), "_p2".to_owned()]);
    assert_eq!(
        (claude[2].path.clone(), claude[2].accounts.clone()),
        (own, vec!["work-acct".to_owned()])
    );
    let codex: Vec<_> =
        found.roots.iter().filter(|root| root.harness == AdapterKind::Codex).collect();
    assert_eq!(codex.len(), 1);
    assert!(
        found.roots.iter().all(|root| root.harness != AdapterKind::OpenCode),
        "missing dirs are not roots"
    );
}

#[test]
fn guarded_roots_are_refused_with_a_reason() {
    let dir = tempfile::tempdir().unwrap();
    let home = fs::canonicalize(dir.path()).unwrap();
    let guarded = mkdir(&home.join("Documents/chats"));
    let fine = mkdir(&home.join("work/chats"));
    let user = [
        RootSpec { harness: AdapterKind::Pi, path: guarded.clone(), label: None },
        RootSpec { harness: AdapterKind::Pi, path: fine.clone(), label: Some("mine".into()) },
    ];
    let documents = home.join("Documents");
    let found = discover(&DiscoveryInput {
        home: &home,
        env: &|_| None,
        refuse: &|path| path.starts_with(&documents).then(|| "inside Documents".to_owned()),
        recorded: &[],
        user: &user,
    });
    assert_eq!(found.refused.len(), 1);
    assert_eq!(
        (found.refused[0].path.clone(), found.refused[0].reason.as_str()),
        (guarded, "inside Documents")
    );
    let pi: Vec<_> = found.roots.iter().filter(|root| root.harness == AdapterKind::Pi).collect();
    assert_eq!(pi.len(), 1);
    assert_eq!(
        (pi[0].path.clone(), pi[0].source, pi[0].accounts.clone()),
        (fine, RootSource::User, vec!["mine".to_owned()])
    );
}

#[test]
fn recorded_roots_persist_through_the_file() {
    let dir = tempfile::tempdir().unwrap();
    let file = dir.path().join("acpmux/chat-roots.json");
    let spec = RootSpec {
        harness: AdapterKind::ClaudeCode,
        path: dir.path().join("odd-home/projects"),
        label: None,
    };
    let mut roots = RecordedRoots::load(&file);
    assert!(roots.record(spec.clone()).unwrap());
    assert!(!roots.record(spec.clone()).unwrap(), "a known root is not recorded twice");
    let reloaded = RecordedRoots::load(&file);
    assert_eq!(reloaded.roots(), &[spec]);
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        assert_eq!(fs::metadata(&file).unwrap().permissions().mode() & 0o777, 0o600);
    }
}

#[test]
fn transcript_paths_name_their_store_root() {
    let claude = Path::new("/u/.claude/projects/-work-app/abc.jsonl");
    let spec = RootSpec::from_transcript(AdapterKind::ClaudeCode, claude).unwrap();
    assert_eq!(spec.path, Path::new("/u/.claude/projects"));
    let codex = Path::new("/u/.codex/sessions/2026/10/01/rollout-2026-10-01T10-00-00-x.jsonl");
    assert_eq!(
        RootSpec::from_transcript(AdapterKind::Codex, codex).unwrap().path,
        Path::new("/u/.codex")
    );
    assert_eq!(RootSpec::from_transcript(AdapterKind::Amp, codex), None);
}
