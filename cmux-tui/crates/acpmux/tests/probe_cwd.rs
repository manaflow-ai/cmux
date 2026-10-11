//! LAUNCH-NO-TCC-PROMPTS: the model probes that acpmux runs at daemon start
//! never start an agent in the home folder. An agent started in `~` scans
//! it (project files, context files, file search) and walks into Desktop,
//! Documents and iCloud Drive, and macOS then asks the person for access on
//! behalf of cmux. The probes run in an empty folder that acpmux owns.
//!
//! One test per process: ACPMUX_HOME is process-wide.

use acpmux::config::{Config, HarnessProfile, StoreMode};
use acpmux::hub::Hub;
use std::collections::BTreeMap;
use std::path::PathBuf;

#[tokio::test]
async fn model_probes_start_agents_in_an_empty_acpmux_folder_never_in_home() {
    let root = std::env::temp_dir().join(format!("acpmux-probe-cwd-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&root);
    let acpmux_home = root.join("acpmux");
    std::fs::create_dir_all(&acpmux_home).unwrap();
    // SAFETY: set before any thread of this test process reads the environment.
    unsafe { std::env::set_var("ACPMUX_HOME", &acpmux_home) };
    let log = root.join("cwd.log");

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
    let store = acpmux::store::open(&cfg.store, std::path::Path::new("/nonexistent")).unwrap();
    let hub = Hub::new(cfg, store);

    hub.refresh_models().await;

    let text = std::fs::read_to_string(&log).expect("the probe started the fake agent");
    let home = dirs::home_dir().unwrap();
    let mut probes = 0;
    for line in text.lines() {
        probes += 1;
        let entry: serde_json::Value = serde_json::from_str(line).unwrap();
        for key in ["process", "session"] {
            let dir = PathBuf::from(entry[key].as_str().unwrap());
            assert_ne!(
                std::fs::canonicalize(&dir).unwrap(),
                std::fs::canonicalize(&home).unwrap(),
                "{key} folder of a model probe is the home folder"
            );
            assert!(
                acpmux::protected_folders::unasked_refusal(&dir).is_none(),
                "{key} folder {} of a model probe is guarded",
                dir.display()
            );
            assert!(
                std::fs::canonicalize(&dir)
                    .unwrap()
                    .starts_with(std::fs::canonicalize(&acpmux_home).unwrap()),
                "{key} folder {} of a model probe is not acpmux's own",
                dir.display()
            );
        }
    }
    assert!(probes >= 1, "no model probe ran");
    let _ = std::fs::remove_dir_all(&root);
}
