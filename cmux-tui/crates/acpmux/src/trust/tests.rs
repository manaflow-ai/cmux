use super::*;

fn paths(dir: &Path) -> Paths {
    Paths {
        claude_json: dir.join("claude.json"),
        codex_config: dir.join("config.toml"),
        record: dir.join("acpmux").join("trust.json"),
    }
}

fn scratch(name: &str) -> PathBuf {
    let dir = std::env::temp_dir().join(format!("acpmux-trust-{name}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&dir);
    std::fs::create_dir_all(&dir).unwrap();
    dir
}

#[test]
fn levels_order_untrusted_over_unknown_over_trusted() {
    assert_eq!(Level::Trusted.stricter(Level::Unknown), Level::Unknown);
    assert_eq!(Level::Unknown.stricter(Level::Untrusted), Level::Untrusted);
    assert_eq!(Level::Trusted.stricter(Level::Trusted), Level::Trusted);
}

#[test]
fn claude_trusts_a_folder_whose_dialog_was_accepted() {
    let json = r#"{"projects":{"/repo":{"hasTrustDialogAccepted":true},"/other":{"hasTrustDialogAccepted":false}}}"#;
    assert_eq!(claude_level(json, "/repo"), Level::Trusted);
    assert_eq!(claude_level(json, "/other"), Level::Unknown);
    assert_eq!(claude_level(json, "/missing"), Level::Unknown);
    assert_eq!(claude_level("not json", "/repo"), Level::Unknown);
}

#[test]
fn codex_reads_the_trust_level_of_the_folders_project_table() {
    let toml = "model = \"x\"\n[projects.\"/repo\"]\ntrust_level = \"trusted\"\n\n[projects.'/bad']\ntrust_level = 'untrusted' # no\n[other]\ntrust_level = \"trusted\"\n";
    assert_eq!(codex_level(toml, "/repo"), Level::Trusted);
    assert_eq!(codex_level(toml, "/bad"), Level::Untrusted);
    assert_eq!(codex_level(toml, "/missing"), Level::Unknown);
}

#[test]
fn get_projects_the_agents_levels_and_acpmux_decision_answers_first() {
    let dir = scratch("get");
    let p = paths(&dir);
    std::fs::write(&p.claude_json, r#"{"projects":{"/repo":{"hasTrustDialogAccepted":true}}}"#)
        .unwrap();
    std::fs::write(&p.codex_config, "[projects.\"/repo\"]\ntrust_level = \"untrusted\"\n").unwrap();
    let reply = get(&p, "/repo/").unwrap();
    assert_eq!(reply["cwd"], "/repo");
    assert_eq!(reply["level"], "untrusted");
    assert_eq!(reply["harnesses"]["claude"], "trusted");
    assert_eq!(reply["harnesses"]["codex"], "untrusted");
    assert_eq!(reply["decided"], false);

    assert_eq!(set(&p, "/repo", "trusted").unwrap()["level"], "trusted");
    let reply = get(&p, "/repo").unwrap();
    assert_eq!(reply["level"], "trusted");
    assert_eq!(reply["decided"], true);

    // unknown forgets the decision; the agents' levels answer again.
    assert_eq!(set(&p, "/repo", "unknown").unwrap()["level"], "unknown");
    assert_eq!(get(&p, "/repo").unwrap()["level"], "untrusted");
    let _ = std::fs::remove_dir_all(dir);
}

#[test]
fn set_never_writes_the_agents_files() {
    let dir = scratch("own");
    let p = paths(&dir);
    std::fs::write(&p.claude_json, "{}").unwrap();
    std::fs::write(&p.codex_config, "").unwrap();
    set(&p, "/repo", "untrusted").unwrap();
    assert_eq!(std::fs::read_to_string(&p.claude_json).unwrap(), "{}");
    assert_eq!(std::fs::read_to_string(&p.codex_config).unwrap(), "");
    assert!(p.record.exists());
    let _ = std::fs::remove_dir_all(dir);
}

#[test]
fn a_relative_cwd_or_an_unknown_level_is_refused() {
    let dir = scratch("refuse");
    let p = paths(&dir);
    assert!(get(&p, "repo").is_err());
    assert!(get(&p, "").is_err());
    assert!(set(&p, "/repo", "maybe").is_err());
    let _ = std::fs::remove_dir_all(dir);
}

#[test]
fn a_trusted_parent_folder_trusts_the_folders_inside_it() {
    let json = r#"{"projects":{"/repo":{"hasTrustDialogAccepted":true}}}"#;
    assert_eq!(claude_level(json, "/repo/sub/dir"), Level::Trusted);
    assert_eq!(claude_level(json, "/repository"), Level::Unknown);
    let toml = "[projects.\"/repo\"] # main checkout\ntrust_level = \"trusted\"\n[projects.\"/repo/vendor\"]\ntrust_level = \"untrusted\"\n";
    assert_eq!(codex_level(toml, "/repo/src"), Level::Trusted);
    assert_eq!(codex_level(toml, "/repo/vendor/lib"), Level::Untrusted);
    assert_eq!(
        codex_level("[projects]\n\"/repo\".trust_level = \"trusted\"\n", "/repo"),
        Level::Trusted
    );
}

#[test]
fn a_damaged_record_is_refused_not_overwritten() {
    let dir = scratch("damaged");
    let p = paths(&dir);
    std::fs::create_dir_all(p.record.parent().unwrap()).unwrap();
    std::fs::write(&p.record, "{not json").unwrap();
    assert!(matches!(set(&p, "/repo", "trusted"), Err(Failure::Record(_))));
    assert!(matches!(get(&p, "/repo"), Err(Failure::Record(_))));
    assert_eq!(std::fs::read_to_string(&p.record).unwrap(), "{not json");
    assert!(matches!(get(&p, "repo"), Err(Failure::Invalid(_))));
    let _ = std::fs::remove_dir_all(dir);
}

#[test]
fn concurrent_decisions_are_all_kept() {
    let dir = scratch("concurrent");
    let p = paths(&dir);
    let threads: Vec<_> = (0..16)
        .map(|index| {
            let p = p.clone();
            std::thread::spawn(move || set(&p, &format!("/repo{index}"), "trusted").unwrap())
        })
        .collect();
    for thread in threads {
        thread.join().unwrap();
    }
    for index in 0..16 {
        assert_eq!(get(&p, &format!("/repo{index}")).unwrap()["decided"], true);
    }
    let _ = std::fs::remove_dir_all(dir);
}
