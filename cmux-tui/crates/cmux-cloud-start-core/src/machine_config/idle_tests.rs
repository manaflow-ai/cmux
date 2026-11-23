use super::*;

fn window(text: &str) -> Result<Option<u64>, String> {
    parse(text).map(|p| p.window_seconds())
}

#[test]
fn a_lane_pauses_five_minutes_after_its_last_activity() {
    assert_eq!(window("version = 1\nrole = \"lane\"\n"), Ok(Some(300)));
    assert_eq!(LANE_IDLE_SECONDS, 300);
}

#[test]
fn a_file_without_a_lane_role_or_idle_declares_nothing() {
    // The plan default (1,800 s) is the Cloud's, a product default: never written here.
    assert_eq!(window("version = 1\n"), Ok(None));
    assert_eq!(window("version = 1\nrole = \"builder\"\n"), Ok(None));
    assert_eq!(window("version = 1\n[env]\nA = \"b\"\n"), Ok(None));
    assert_eq!(window("version = 1\n[idle]\n"), Ok(None));
}

#[test]
fn idle_minutes_overrides_the_role() {
    assert_eq!(window("version = 1\nrole = \"lane\"\n[idle]\nminutes = 10\n"), Ok(Some(600)));
    assert_eq!(window("version = 1\n[idle]\nminutes = 1\n"), Ok(Some(60)));
    assert_eq!(window("version = 1\n[idle]\nminutes = 1439\n"), Ok(Some(1439 * 60)));
}

#[test]
fn bad_values_are_refused() {
    for (text, why) in [
        ("version = 1\n[idle]\nminutes = 0\n", "idle.minutes must be 1 to 1439"),
        ("version = 1\n[idle]\nminutes = 1440\n", "idle.minutes must be 1 to 1439"),
        ("version = 1\n[idle]\nminutes = \"5\"\n", "idle.minutes must be 1 to 1439"),
        ("version = 1\n[idle]\nminutes = 5.0\n", "idle.minutes must be 1 to 1439"),
        ("version = 1\n[idle]\nseconds = 300\n", "[idle] takes only minutes"),
        ("version = 1\nidle = 5\n", "idle must be a table"),
        ("version = 1\nrole = \"Lane\"\n", "role must match [a-z][a-z0-9-]{0,31}"),
        ("version = 1\nrole = 1\n", "role must match [a-z][a-z0-9-]{0,31}"),
    ] {
        assert_eq!(parse(text), Err(why.to_owned()), "{text}");
    }
    assert!(parse("version = = 1").unwrap_err().starts_with("not TOML"));
}

#[test]
fn read_takes_the_applied_file_and_nothing_else() {
    let root = std::env::temp_dir().join(format!("cmux-idle-read-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&root);
    let path = root.join(applied_path().trim_start_matches('/'));
    std::fs::create_dir_all(path.parent().unwrap()).unwrap();
    assert_eq!(read(&root), None, "no file: no window");
    std::fs::write(&path, "version = 1\nrole = \"lane\"\n").unwrap();
    assert_eq!(read(&root), Some(300));
    std::fs::write(&path, "version = 1\n[idle]\nminutes = 0\n").unwrap();
    assert_eq!(read(&root), None, "a refused file declares nothing");
    std::fs::remove_file(&path).unwrap();
    #[cfg(unix)]
    {
        let target = root.join("elsewhere.toml");
        std::fs::write(&target, "version = 1\nrole = \"lane\"\n").unwrap();
        std::os::unix::fs::symlink(&target, &path).unwrap();
        assert_eq!(read(&root), None, "never through a link");
    }
    let _ = std::fs::remove_dir_all(&root);
}

/// The applier (Python, on the machine) takes and refuses what this parser does, so a file it applies is one
/// cmux-host reads the same window from.
#[cfg(unix)]
#[test]
fn the_applier_agrees_with_this_parser() {
    let cases = [
        "version = 1\nrole = \"lane\"\n",
        "version = 1\nrole = \"lane\"\n[idle]\nminutes = 10\n",
        "version = 1\n[idle]\nminutes = 0\n",
        "version = 1\n[idle]\nminutes = 1440\n",
        "version = 1\n[idle]\nseconds = 1\n",
        "version = 1\nidle = 5\n",
        "version = 1\nrole = \"Lane\"\n",
        "version = 1\n[idle]\nminutes = true\n",
        "version = 1\n",
    ];
    let call = "import importlib.machinery, importlib.util, json, sys\n\
                l = importlib.machinery.SourceFileLoader('applier', sys.argv[1])\n\
                m = importlib.util.module_from_spec(importlib.util.spec_from_loader('applier', l))\n\
                l.exec_module(m)\n\
                for text in json.loads(sys.argv[2]):\n\
                \x20   try:\n\
                \x20       c = m.parse(text); print(json.dumps(c['idle_seconds']))\n\
                \x20   except m.Refused as e:\n\
                \x20       print(json.dumps('refused: ' + str(e)))\n";
    let dir = std::env::temp_dir().join(format!("cmux-idle-applier-{}", std::process::id()));
    std::fs::create_dir_all(&dir).unwrap();
    let applier_path = dir.join("apply");
    std::fs::write(&applier_path, super::super::applier()).unwrap();
    let out = std::process::Command::new("python3")
        .args(["-I", "-c", call])
        .arg(&applier_path)
        .arg(serde_json::to_string(&cases).unwrap())
        .output();
    let _ = std::fs::remove_dir_all(&dir);
    // A host without python3 3.11 (tomllib) cannot load the applier.
    let Ok(out) = out else { return };
    if !out.status.success() {
        assert!(
            String::from_utf8_lossy(&out.stderr).contains("tomllib"),
            "{}",
            String::from_utf8_lossy(&out.stderr)
        );
        return;
    }
    let said: Vec<serde_json::Value> = String::from_utf8_lossy(&out.stdout)
        .lines()
        .map(|l| serde_json::from_str(l).unwrap())
        .collect();
    assert_eq!(said.len(), cases.len());
    for (text, py) in cases.iter().zip(said) {
        match parse(text) {
            Ok(p) => assert_eq!(py, serde_json::json!(p.window_seconds()), "{text}"),
            Err(why) => assert_eq!(py, serde_json::json!(format!("refused: {why}")), "{text}"),
        }
    }
}
