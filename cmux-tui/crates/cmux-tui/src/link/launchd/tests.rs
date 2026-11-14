use super::*;

const FLAG: &str = "--key-lock-dir";

fn command_of(path: &Path) -> Vec<String> {
    plist::Value::from_file(path).unwrap().as_dictionary().unwrap()["ProgramArguments"]
        .as_array()
        .unwrap()
        .iter()
        .map(|item| item.as_string().unwrap().to_owned())
        .collect()
}

/// An agent installed before `--key-lock-dir` gets it once; a plist that
/// has it, another state directory's agent and no agent stay untouched.
#[test]
fn an_old_agent_plist_gets_the_key_lock_dir_once() {
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join("agent.plist");
    let program = Path::new("/Applications/cmux.app/Contents/MacOS/cmux");
    let (state, lock) = (Path::new("/s/link"), Path::new("/lock/dir"));
    assert!(!rewrite_key_lock_dir(&path, state, FLAG, lock).unwrap(), "no agent");
    let old: Vec<String> =
        ["link", "serve", "--state-dir", "/s/link", "--session-socket", "/s.sock"]
            .map(str::to_owned)
            .to_vec();
    std::fs::write(&path, plist(program, &old).unwrap()).unwrap();
    assert!(!rewrite_key_lock_dir(&path, Path::new("/other/link"), FLAG, lock).unwrap());
    assert!(rewrite_key_lock_dir(&path, state, FLAG, lock).unwrap());
    let mut wanted = vec![program.to_string_lossy().into_owned()];
    wanted.extend(old.iter().cloned());
    wanted.extend([FLAG.to_owned(), "/lock/dir".to_owned()]);
    assert_eq!(command_of(&path), wanted);
    let written = std::fs::read(&path).unwrap();
    assert!(!rewrite_key_lock_dir(&path, state, FLAG, lock).unwrap(), "rewrote a matching plist");
    assert_eq!(std::fs::read(&path).unwrap(), written);
    // A stale directory is replaced, never doubled.
    assert!(rewrite_key_lock_dir(&path, state, FLAG, Path::new("/new")).unwrap());
    let command = command_of(&path);
    assert_eq!(command.iter().filter(|argument| *argument == FLAG).count(), 1);
    assert_eq!(command.last().map(String::as_str), Some("/new"));
}

#[test]
fn the_agent_plist_runs_link_serve_and_keeps_it_alive() {
    let arguments = vec![
        "link".to_string(),
        "serve".to_string(),
        "--state-dir".to_string(),
        "/a b/<x>".to_string(),
    ];
    let bytes = plist(Path::new("/Applications/cmux.app/Contents/MacOS/cmux"), &arguments).unwrap();
    let value = plist::Value::from_reader_xml(bytes.as_slice()).unwrap();
    let dictionary = value.as_dictionary().unwrap();
    assert_eq!(dictionary["Label"].as_string(), Some(LABEL));
    let environment = dictionary["EnvironmentVariables"].as_dictionary().unwrap();
    assert_eq!(environment[crate::launchd_refresh::AGENT_ENV].as_string(), Some(LABEL));
    let command: Vec<&str> = dictionary["ProgramArguments"]
        .as_array()
        .unwrap()
        .iter()
        .map(|item| item.as_string().unwrap())
        .collect();
    assert_eq!(
        command,
        ["/Applications/cmux.app/Contents/MacOS/cmux", "link", "serve", "--state-dir", "/a b/<x>"]
    );
    assert_eq!(dictionary["KeepAlive"].as_boolean(), Some(true));
    assert_eq!(dictionary["RunAtLoad"].as_boolean(), Some(true));
}
