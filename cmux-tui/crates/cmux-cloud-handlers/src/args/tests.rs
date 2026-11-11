//! The cases of the Swift tests these checks came from (CloudNewMachineTests,
//! CloudIdlePauseTests, CloudTerminalTests, CloudBrowserActionTests, CloudMachineConfigTests).

use super::*;
use serde_json::json;

fn args(value: Value) -> Args {
    value.as_object().cloned().unwrap()
}

const HOME: &str = "/Users/me";

#[test]
fn no_options_is_the_default_create() {
    let request = new_machine(&args(json!({})), HOME).unwrap();
    assert_eq!(request, NewMachine::default());
}

#[test]
fn the_lane_options_parse_into_one_request() {
    let request = new_machine(
        &args(json!({"name": "lane-vm-1", "size": "medium", "persistent": true,
                     "bootstrap": "lane", "bootstrapScript": "/tmp/lane-vm-bootstrap"})),
        HOME,
    )
    .unwrap();
    assert_eq!(request.name.as_deref(), Some("lane-vm-1"));
    assert_eq!(request.size.as_deref(), Some("medium"));
    assert_eq!(request.memory_mb, Some(8192), "medium is 4 vCPU / 8 GiB, the lane VM size");
    assert!(request.persistent);
    assert_eq!(request.bootstrap_kind, BootstrapKind::Lane);
    assert_eq!(request.bootstrap_path.as_deref(), Some("/tmp/lane-vm-bootstrap"));
}

#[test]
fn persistent_as_text_and_xlarge_memory() {
    let request =
        new_machine(&args(json!({"persistent": "true", "size": "xlarge"})), HOME).unwrap();
    assert!(request.persistent);
    assert_eq!(request.memory_mb, Some(24_576));
    assert_eq!(
        create_size("xlarge"),
        Some((12, 24_576)),
        "24 GiB is the 12 vCPU row, not resize's 16"
    );
}

#[test]
fn an_unknown_size_is_refused_with_the_choices() {
    let refused = new_machine(&args(json!({"size": "huge"})), HOME).unwrap_err();
    assert_eq!(refused, Said::with("sizeMustBeOneOf", ["large, medium, small, xlarge"]));
}

#[test]
fn a_lane_bootstrap_needs_its_script_and_a_name() {
    let refused = |value| new_machine(&args(value), HOME).unwrap_err().key;
    assert_eq!(
        refused(json!({"bootstrap": "lane", "name": "lane-vm-1"})),
        "bootstrapScriptRequired"
    );
    assert_eq!(refused(json!({"bootstrap": "lane", "bootstrapScript": "/tmp/x"})), "laneNeedsName");
    assert_eq!(
        refused(json!({"bootstrap": "other", "bootstrapScript": "/tmp/x"})),
        "bootstrapScriptRequired"
    );
}

#[test]
fn a_script_without_a_lane_is_a_plain_bootstrap() {
    let request = new_machine(&args(json!({"bootstrapScript": "/tmp/setup.sh"})), HOME).unwrap();
    assert_eq!(request.bootstrap_kind, BootstrapKind::Plain);
    assert_eq!(request.bootstrap_path.as_deref(), Some("/tmp/setup.sh"));
}

#[test]
fn a_text_flag_with_no_value_is_refused_not_ignored() {
    for (name, key) in [
        ("bootstrapScript", "bootstrapScriptRequired"),
        ("bootstrap", "bootstrapScriptRequired"),
        ("size", "sizeMustBeOneOf"),
        ("name", "laneNeedsName"),
        ("repo", "repoUnrecognized"),
        ("machineConfig", "machineConfigUnreadable"),
    ] {
        let mut given = Args::new();
        given.insert(name.into(), json!(true));
        assert_eq!(new_machine(&given, HOME).unwrap_err().key, key, "{name}");
    }
}

#[test]
fn a_name_is_a_plain_word_and_a_bare_flag_is_not_one() {
    for bad in ["true", "a b", "it's", "-x", "lane;vm", &"a".repeat(65), "é"] {
        assert_eq!(
            new_machine(&args(json!({"name": bad})), HOME).unwrap_err().key,
            "machineNameInvalid",
            "{bad}"
        );
    }
    let named = new_machine(&args(json!({"name": " lane-vm-7\n"})), HOME).unwrap();
    assert_eq!(named.name.as_deref(), Some("lane-vm-7"));
}

#[test]
fn a_quoted_tilde_is_the_home_folders() {
    let request =
        new_machine(&args(json!({"bootstrapScript": "~/boot.sh", "machineConfig": "~"})), HOME)
            .unwrap();
    assert_eq!(request.bootstrap_path.as_deref(), Some("/Users/me/boot.sh"));
    assert_eq!(request.machine_config_path.as_deref(), Some("/Users/me"));
    assert_eq!(expanding_home("~other/x", HOME), "~other/x");
}

#[test]
fn an_empty_machine_config_is_refused_and_a_repo_is_parsed() {
    assert_eq!(
        new_machine(&args(json!({"machineConfig": ""})), HOME).unwrap_err(),
        Said::with("machineConfigUnreadable", [""])
    );
    let request = new_machine(&args(json!({"repo": "manaflow-ai/cmux"})), HOME).unwrap();
    assert_eq!(
        request.repo.map(|repo| repo.url).as_deref(),
        Some("https://github.com/manaflow-ai/cmux.git")
    );
    let refused =
        new_machine(&args(json!({"repo": "https://ghp_x@github.com/o/n"})), HOME).unwrap_err();
    assert_eq!(refused.key, "repoCredentialsInURL");
}

#[test]
fn apply_machine_config_refuses_a_bare_flag() {
    assert_eq!(apply_machine_config(&args(json!({})), HOME), Ok(None));
    assert_eq!(
        apply_machine_config(&args(json!({"machineConfig": "~/m.toml"})), HOME),
        Ok(Some("/Users/me/m.toml".into()))
    );
    for bare in [json!(true), json!("")] {
        assert_eq!(
            apply_machine_config(&args(json!({"machineConfig": bare})), HOME),
            Err(Said::with("machineConfigUnreadable", ["--machine-config"]))
        );
    }
}

#[test]
fn idle_pause_takes_off_or_a_choice_as_text_or_number() {
    let choices = [0, 15, 30, 60, 120];
    assert_eq!(idle_pause_minutes(&args(json!({"minutes": "off"})), &choices), Ok(0));
    assert_eq!(idle_pause_minutes(&args(json!({"minutes": " OFF "})), &choices), Ok(0));
    assert_eq!(idle_pause_minutes(&args(json!({"minutes": "30"})), &choices), Ok(30));
    assert_eq!(idle_pause_minutes(&args(json!({"minutes": 120})), &choices), Ok(120));
    for bad in [json!("45"), json!(true), json!("never"), json!(7)] {
        assert_eq!(
            idle_pause_minutes(&args(json!({"minutes": bad})), &choices),
            Err(Said::with("idlePauseMustBeOneOf", ["off, 15, 30, 60, 120"]))
        );
    }
    assert!(idle_pause_minutes(&args(json!({})), &choices).is_err());
}

#[test]
fn file_paths_are_absolute_and_never_climb() {
    assert_eq!(
        file_path(&args(json!({"path": " /home/cmux/a.txt\n"}))),
        Ok("/home/cmux/a.txt".into())
    );
    for bad in [
        json!("relative"),
        json!("/a/../b"),
        json!("/a\u{0}b"),
        json!(true),
        json!(format!("/{}", "a".repeat(4096))),
    ] {
        assert_eq!(file_path(&args(json!({"path": bad}))), Err(Said::key("filePathRequired")));
    }
    assert_eq!(file_path(&args(json!({"path": "/a/..b"}))), Ok("/a/..b".into()));
}

#[test]
fn a_port_is_one_through_65535() {
    assert_eq!(port(&args(json!({"port": 3000}))), Ok(3000));
    for bad in [json!(0), json!(65_536), json!("3000"), json!(3000.5)] {
        assert_eq!(port(&args(json!({"port": bad}))), Err(Said::key("invalidPort")));
    }
    let names = PortNames { name: "dev box".into(), id: "vm-1".into(), port: None };
    assert_eq!(
        named_port(&args(json!({})), "open-browser", &names),
        Err(Said::with("portInvalid", ["dev box", "vm-1", "open-browser"]))
    );
}

#[test]
fn a_machine_workspace_flag_needs_its_id() {
    assert_eq!(machine_workspace(&args(json!({})), "vm-1"), Ok(None));
    assert_eq!(
        machine_workspace(&args(json!({"workspace": " ws_1 "})), "vm-1"),
        Ok(Some("ws_1".into()))
    );
    for bad in [json!(true), json!("  ")] {
        assert_eq!(
            machine_workspace(&args(json!({"workspace": bad})), "vm-1"),
            Err(Said::with("machineWorkspaceRequired", ["vm-1"]))
        );
    }
}

#[test]
fn an_id_argument_names_what_is_missing() {
    assert_eq!(
        id_argument(&args(json!({"path": " pub-1 "})), "publicationRequired"),
        Ok("pub-1".into())
    );
    assert_eq!(
        id_argument(&args(json!({"path": ""})), "publicationRequired"),
        Err(Said::key("publicationRequired"))
    );
}

#[test]
fn a_browser_path_is_slash_when_absent_and_never_has_spaces() {
    let names = PortNames { name: "dev box".into(), id: "vm-1".into(), port: Some(3000) };
    assert_eq!(browser_path(&args(json!({})), &names), Ok("/".into()));
    assert_eq!(browser_path(&args(json!({"path": "  "})), &names), Ok("/".into()));
    assert_eq!(browser_path(&args(json!({"path": "/docs?x=1"})), &names), Ok("/docs?x=1".into()));
    for bad in ["docs", "/a b", "/a\u{7}", &format!("/{}", "a".repeat(2048))] {
        assert_eq!(
            browser_path(&args(json!({"path": bad})), &names),
            Err(Said::with("portPathInvalid", ["dev box", "vm-1", "3000"])),
            "{bad}"
        );
    }
}

#[test]
fn the_needed_text_arguments() {
    assert_eq!(
        needed(
            &args(json!({"publicKey": " ssh-ed25519 AAA "})),
            "publicKey",
            &PortNames::default()
        ),
        Ok(" ssh-ed25519 AAA ".into())
    );
    assert_eq!(
        needed(&args(json!({"publicKey": " "})), "publicKey", &PortNames::default()),
        Err(Said::key("publicKeyRequired"))
    );
    assert_eq!(
        needed(&args(json!({"contents": ""})), "contents", &PortNames::default()),
        Ok(String::new())
    );
    assert_eq!(
        needed(&args(json!({})), "contents", &PortNames::default()),
        Err(Said::key("fileContentsRequired"))
    );
    assert_eq!(
        needed(&args(json!({"snapshot": ""})), "snapshot", &PortNames::default()),
        Err(Said::key("snapshotRequired"))
    );
    assert_eq!(
        needed(&args(json!({"key": " k1 "})), "key", &PortNames::default()),
        Ok("k1".into())
    );
    assert_eq!(
        needed(
            &args(json!({})),
            "linkId",
            &PortNames { name: "box".into(), id: "vm-1".into(), port: Some(3000) }
        ),
        Err(Said::with("portFailed", ["box", "vm-1", "3000", "linkId is required"]))
    );
}

#[test]
fn provision_api_takes_a_port_and_an_optional_key_name() {
    assert_eq!(
        provision_api(&args(json!({"port": 8080, "name": " "}))),
        Ok(ProvisionAPI { port: 8080, name: None })
    );
    assert_eq!(
        provision_api(&args(json!({"port": 8080, "name": " ci "}))),
        Ok(ProvisionAPI { port: 8080, name: Some("ci".into()) })
    );
    assert_eq!(provision_api(&args(json!({}))), Err(Said::key("invalidPort")));
}

#[test]
fn the_command_is_trimmed_and_required() {
    assert_eq!(command(&args(json!({"command": " ls -la\n"}))), Ok("ls -la".into()));
    assert_eq!(command(&args(json!({"command": "\n"}))), Err(Said::key("commandRequired")));
}

#[test]
fn a_resize_takes_a_size_or_a_disk_in_four_gib_steps() {
    let names = "large, medium, small, xlarge";
    let resized = resize(&args(json!({"size": "xlarge", "disk": " 64 "}))).unwrap();
    assert_eq!(
        resized,
        Resize {
            size: Some("xlarge".into()),
            cpu: Some(16),
            memory_mb: Some(24_576),
            disk_gib: Some(64),
            storage_mb: Some(65_536),
        }
    );
    assert_eq!(resize(&args(json!({"disk": 8}))).unwrap().size, None);
    assert_eq!(resize(&args(json!({"size": "huge"}))), Err(Said::with("sizeMustBeOneOf", [names])));
    assert_eq!(resize(&args(json!({"size": true}))), Err(Said::with("sizeMustBeOneOf", [names])));
    for bad in [json!(true), json!(2), json!(6), json!(260), json!("x"), json!(8.5)] {
        assert_eq!(
            resize(&args(json!({"disk": bad}))),
            Err(Said::with("resizeNeedsSizeOrDisk", [names])),
            "{bad}"
        );
    }
    assert_eq!(resize(&args(json!({}))), Err(Said::with("resizeNeedsSizeOrDisk", [names])));
}
