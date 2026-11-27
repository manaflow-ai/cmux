use super::*;

fn words(text: &str) -> Vec<String> {
    text.split_whitespace().map(str::to_owned).collect()
}

#[test]
fn secret_help_forms_parse_and_succeed_without_a_secret_operation() {
    for suffix in ["", "--help", "-h", "help"] {
        assert_eq!(parse(&words(suffix)), Ok(Command::Help), "{suffix:?} should be help");
        assert_eq!(run_if_requested(&words(&format!("cloud secret {suffix}"))), Some(0));
    }
    for bad in ["help extra", "--help extra", "-h extra", "set", "rm", "unknown"] {
        assert!(parse(&words(bad)).is_err(), "{bad:?} is still invalid");
    }
}

#[test]
fn a_value_is_long_enough_to_mask_and_small_enough_to_deliver() {
    assert!(value_size("1234567").is_err(), "under 8 characters");
    assert!(
        value_size("🔒🔑🔒🔑").is_err(),
        "16 bytes, but 4 characters: never under the mask's floor"
    );
    assert!(value_size("12345678").is_ok());
    assert!(value_size(&"x".repeat(16 * 1024)).is_ok());
    assert!(value_size(&"x".repeat(16 * 1024 + 1)).is_err(), "over 16 KiB");
}

#[test]
fn a_secret_is_named_with_its_scope_and_never_takes_a_value_argument() {
    assert_eq!(
        parse(&words("set DATABASE_URL")),
        Ok(Command::Set { account: "*/DATABASE_URL".into() })
    );
    assert_eq!(
        parse(&words("set API_KEY --repo Manaflow-AI/cmux")),
        Ok(Command::Set { account: "manaflow-ai/cmux/API_KEY".into() })
    );
    assert_eq!(parse(&words("rm API_KEY")), Ok(Command::Rm { account: "*/API_KEY".into() }));
    assert_eq!(parse(&words("ls")), Ok(Command::Ls));
    // A value on the command line would be in argv for every process to read.
    assert!(parse(&words("set API_KEY sk-live-123")).is_err());
    for bad in [
        "set 1BAD",
        "set PATH",
        "set CMUX_TOKEN",
        "set ld_preload",
        "set OPTIND",
        "set PS1",
        "set BASH_FUNC_x",
        "set LC_ALL",
        "set TZ",
        // The gateway's endpoints for Gemini and Grok: the platform withholds them (hq#11225).
        "set GOOGLE_GEMINI_BASE_URL",
        "set GROK_MODELS_BASE_URL",
        "set grok_models_list_url",
        "set GROK_XAI_API_BASE_URL",
        "set A-B",
        "set API_KEY --repo ../x",
        "set API_KEY --repo owner",
        "ls extra",
        "get X",
    ] {
        assert!(parse(&words(bad)).is_err(), "{bad}");
    }
}

#[test]
fn a_dev_builds_keychain_service_is_its_own() {
    let dev = |key: &str| {
        (key == SERVICE_OVERRIDE).then(|| "cmux-cloud-secret.com.cmuxterm.app.debug.dev".to_owned())
    };
    assert_eq!(service_from(dev, false), "cmux-cloud-secret.com.cmuxterm.app.debug.dev");
    assert_eq!(service_from(dev, true), SERVICE, "another app's service in its terminal");
    assert_eq!(service_from(|_| None, false), SERVICE);
}

#[test]
fn a_dev_builds_index_is_its_own() {
    let env = |pairs: &'static [(&'static str, &'static str)]| {
        move |key: &str| {
            pairs.iter().find(|(k, _)| *k == key).map(|(_, v)| std::ffi::OsString::from(*v))
        }
    };
    let dev: &[(&str, &str)] =
        &[("HOME", "/h"), (INDEX_OVERRIDE, "/s/builds/dev/config/cloud-secrets.json")];
    assert_eq!(
        index_path_from(env(dev), false),
        Some(PathBuf::from("/s/builds/dev/config/cloud-secrets.json"))
    );
    assert_eq!(
        index_path_from(env(dev), true),
        Some(PathBuf::from("/h/.config").join(cmux_config::NEXT_DIR).join("cloud-secrets.json")),
        "another app's index in its terminal"
    );
    assert_eq!(
        index_path_from(env(&[("HOME", "/h")]), false),
        Some(PathBuf::from("/h/.config").join(cmux_config::NEXT_DIR).join("cloud-secrets.json"))
    );
}

#[test]
fn the_index_holds_accounts_and_times_only_and_is_owner_only() {
    use std::os::unix::fs::PermissionsExt as _;
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("cmux/cloud-secrets.json");
    assert!(read_index(&path).unwrap().is_empty(), "no file: nothing set yet");
    let mut secrets = Map::new();
    secrets.insert("*/API_KEY".into(), json!(1));
    write_index(&path, secrets).unwrap();
    assert_eq!(std::fs::metadata(&path).unwrap().permissions().mode() & 0o777, 0o600);
    assert_eq!(read_index(&path).unwrap().get("*/API_KEY"), Some(&json!(1)));
    std::fs::write(&path, b"{broken").unwrap();
    assert!(read_index(&path).is_err(), "a damaged index is an error, never empty");
    for bad in [
        r#"{"secrets":{"*/API_KEY":"sk-live-123"}}"#,
        r#"{"secrets":{"*/API_KEY":true}}"#,
        r#"{"secrets":{"*/API_KEY":1.5}}"#,
        r#"{"secrets":{"*/API_KEY":-1}}"#,
        r#"{"secrets":{"API_KEY":1}}"#,
        r#"{"secrets":{"Acme/App/API_KEY":1}}"#,
        r#"{"secrets":{"*/PATH":1}}"#,
        r#"{"secrets":{"*/API_KEY":9223372036854775808}}"#,
        r#"{"secrets":{"*/API_KEY":18446744073709551615}}"#,
    ] {
        std::fs::write(&path, bad).unwrap();
        assert!(read_index(&path).is_err(), "{bad}");
    }
    std::fs::write(&path, r#"{"secrets":{"*/API_KEY":9223372036854775807}}"#).unwrap();
    assert!(read_index(&path).is_ok(), "i64::MAX is the largest mark the app reads");
    std::fs::write(&path, r#"{"secrets":{"acme/app/API_KEY":2,"*/DATABASE_URL":3}}"#).unwrap();
    assert_eq!(read_index(&path).unwrap().len(), 2);
}
