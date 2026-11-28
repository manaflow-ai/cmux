//! LAUNCH-NO-TCC-PROMPTS: when the home folder is a git repository (a dotfiles repository,
//! `~/.git`), the model probes that acpmux runs at daemon start never start an agent in a folder
//! that repository holds. acpmux's own folder is under the home folder, and its unattended folder
//! has no repository of its own, so git there names the home folder as its top level: Claude
//! Code's `git status` at start then lists every untracked file of the home folder. On a test
//! Mac that walk read the Photos library, and macOS asked "cmux would like to access your Photos
//! library" at launch, with three Full Disk Access requests, all attributed to cmux.
//!
//! The probe's folder is checked the way the agent's git sees it: `git rev-parse
//! --show-toplevel` there never names the home folder.
//!
//! One test per process: ACPMUX_HOME is process-wide.

#[path = "support/daemon_env.rs"]
mod daemon_env;
// This process runs stand-in agents (the fake agents under tests/); `git` makes the home
// folder a repository and answers what the agent's git would see.
const HERMETIC: daemon_env::Process = daemon_env::Process::stand_in().tools(&["git"]);

use acpmux::config::{Config, HarnessProfile, StoreMode};
use acpmux::hub::Hub;
use std::collections::BTreeMap;
use std::path::{Path, PathBuf};
use std::process::Command;

/// The top level git names for `folder`, or `None` when it is in no repository.
fn top_level(folder: &Path) -> Option<PathBuf> {
    let output = Command::new("git")
        .arg("-C")
        .arg(folder)
        .args(["rev-parse", "--show-toplevel"])
        .env("GIT_CONFIG_NOSYSTEM", "1")
        .env("GIT_CONFIG_GLOBAL", "/dev/null")
        .output()
        .expect("git runs");
    output.status.success().then(|| PathBuf::from(String::from_utf8_lossy(&output.stdout).trim()))
}

#[tokio::test]
async fn model_probes_never_start_an_agent_in_the_home_folders_repository() {
    // The hermetic process's own home folder, kept in git.
    let home = std::fs::canonicalize(dirs::home_dir().expect("a home folder")).unwrap();
    let made = Command::new("git")
        .args(["init", "--quiet"])
        .arg(&home)
        .env("GIT_CONFIG_NOSYSTEM", "1")
        .env("GIT_CONFIG_GLOBAL", "/dev/null")
        .status()
        .unwrap();
    assert!(made.success(), "git init of the home folder");
    std::fs::create_dir_all(home.join("Pictures/Photos Library.photoslibrary")).unwrap();
    // acpmux's own folder, under the home folder as `~/.acpmux` is.
    let acpmux_home = home.join(".acpmux");
    std::fs::create_dir_all(&acpmux_home).unwrap();
    // SAFETY: set before any thread of this test process reads the environment.
    unsafe { std::env::set_var("ACPMUX_HOME", &acpmux_home) };
    let log = home.join("cwd.log");

    let fake = concat!(env!("CARGO_MANIFEST_DIR"), "/tests/fake_agent.py");
    let mut env = BTreeMap::new();
    env.insert("FAKE_CWD_LOG".to_owned(), log.to_string_lossy().into_owned());
    let profile = HarnessProfile {
        kind: Default::default(),
        argv: vec!["python3".into(), fake.into()],
        env,
        description: None,
        fallback: None,
        family: None,
        models: vec![],
        model: None,
        effort: None,
        policy: None,
    };
    let mut cfg = Config {
        harnesses: BTreeMap::from([("fake".to_owned(), profile)]),
        default_harness: Some("fake".into()),
        ..Default::default()
    };
    cfg.store.mode = StoreMode::Memory;
    let store = acpmux::store::open(&cfg.store, Path::new("/nonexistent")).unwrap();
    let hub = Hub::new(cfg, store);

    hub.refresh_models().await;

    let text = std::fs::read_to_string(&log).expect("the probe started the fake agent");
    let mut probes = 0;
    for line in text.lines() {
        probes += 1;
        let entry: serde_json::Value = serde_json::from_str(line).unwrap();
        for key in ["process", "session"] {
            let dir = PathBuf::from(entry[key].as_str().unwrap());
            let top = top_level(&dir).map(|top| std::fs::canonicalize(&top).unwrap_or(top));
            assert_ne!(
                top.as_deref(),
                Some(home.as_path()),
                "the {key} folder {} of a model probe is in the home folder's repository: the \
                 agent's git would list the whole home folder",
                dir.display()
            );
            assert!(
                acpmux::protected_folders::unasked_refusal(&dir).is_none(),
                "{key} folder {} of a model probe is refused for an unasked agent",
                dir.display()
            );
        }
    }
    assert!(probes >= 1, "no model probe ran");
    // A folder the home folder's repository holds is refused for every agent no person asked
    // for (warming, the session pool, restored work), as the home folder itself is.
    let project = home.join("itp-rs/tools");
    std::fs::create_dir_all(&project).unwrap();
    assert!(
        acpmux::protected_folders::unasked_refusal(&project).is_some(),
        "{} is in the home folder's repository",
        project.display()
    );
    // A repository of its own below the home folder is not.
    let app = home.join("code/app");
    std::fs::create_dir_all(app.join(".git")).unwrap();
    assert_eq!(acpmux::protected_folders::unasked_refusal(&app), None);
}
