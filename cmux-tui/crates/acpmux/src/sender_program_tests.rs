use super::*;

fn info(pid: u32, ppid: u32, exe: &str, argv: &[&str]) -> ProcInfo {
    ProcInfo {
        pid,
        ppid,
        exe: exe.to_owned(),
        argv: argv.iter().map(|a| (*a).to_owned()).collect(),
        cwd: Some("/work".to_owned()),
    }
}

fn of(table: &[ProcInfo]) -> impl Fn(u32) -> Option<ProcInfo> + '_ {
    move |pid| table.iter().find(|p| p.pid == pid).cloned()
}

/// Resolves a script argument as a file that exists: absolute as given, else under `cwd`.
fn exists(arg: &str, cwd: Option<&str>) -> Option<String> {
    if arg.starts_with('/') { Some(arg.to_owned()) } else { Some(format!("{}/{arg}", cwd?)) }
}

const XCODE_PYTHON: &str = "/Applications/Xcode.app/Contents/Developer/Library/Frameworks/Python3.framework/Versions/3.9/Resources/Python.app/Contents/MacOS/Python";
const RELAY: &str = "/Users/leoli/.local/share/ws-sync/deploy/tools/outbox_relay.py";

#[test]
fn the_outbox_relay_is_its_script_not_its_python() {
    let table = [
        info(50, 40, "/usr/local/bin/acpmux", &["acpmux", "send", "lane", "-"]),
        info(40, 1, XCODE_PYTHON, &["/usr/bin/python3", RELAY, "run"]),
    ];
    let found = programs(of(&table), exists, 50);
    assert_eq!(
        found.nearest,
        Some(Program {
            name: "outbox_relay.py".into(),
            path: Some(RELAY.into()),
            interpreter: Some("Python".into()),
        })
    );
    assert_eq!(found.paths, vec![XCODE_PYTHON.to_owned(), RELAY.to_owned()]);
}

#[test]
fn interpreters_name_their_script_and_inline_code_names_the_interpreter() {
    let cases: &[(&str, &[&str], &str)] = &[
        ("/usr/bin/python3.11", &["python3", "-u", "tools/x.py"], "x.py"),
        ("/usr/bin/python3", &["python3", "-W", "ignore", "/t/y.py"], "y.py"),
        ("/usr/bin/python3", &["python3", "-c", "import os"], "python3"),
        ("/usr/bin/python3", &["python3", "-m", "tools.x"], "python3"),
        ("/usr/local/bin/node", &["node", "--require", "ts-node", "/t/a.js"], "a.js"),
        ("/usr/local/bin/node", &["node", "-e", "1"], "node"),
        ("/usr/local/bin/bun", &["bun", "run", "/t/b.ts"], "b.ts"),
        ("/usr/local/bin/deno", &["deno", "run", "-A", "/t/d.ts"], "d.ts"),
        ("/usr/bin/ruby", &["ruby", "/t/r.rb"], "r.rb"),
        ("/usr/bin/perl", &["perl", "-e", "print 1"], "perl"),
        ("/bin/bash", &["/bin/bash", "/t/hook.sh", "arg"], "hook.sh"),
        ("/bin/zsh", &["-zsh"], "zsh"),
        ("/usr/local/bin/glaeda-gh", &["glaeda-gh", "watch"], "glaeda-gh"),
    ];
    for (exe, argv, want) in cases {
        let table = [info(9, 8, "acpmux", &["acpmux"]), info(8, 1, exe, argv)];
        let found = programs(of(&table), exists, 9);
        assert_eq!(found.nearest.map(|p| p.name).as_deref(), Some(*want), "{exe} {argv:?}");
    }
}

#[test]
fn a_shell_that_only_passes_a_command_on_is_walked_past() {
    let table = [
        info(9, 8, "/usr/local/bin/acpmux", &["acpmux", "send"]),
        info(8, 7, "/bin/sh", &["sh", "-c", "acpmux send lane hi"]),
        info(7, 1, "/usr/bin/python3", &["python3", "/t/relay.py"]),
    ];
    let found = programs(of(&table), exists, 9);
    assert_eq!(found.nearest.unwrap().name, "relay.py");
    // With nothing above it, the shell is the program.
    let alone = [info(9, 8, "acpmux", &["acpmux"]), info(8, 1, "/bin/sh", &["sh", "-c", "x"])];
    assert_eq!(programs(of(&alone), exists, 9).nearest.unwrap().name, "sh");
}

#[test]
fn acpmux_itself_and_an_unfound_script_path_are_handled() {
    // The first process is acpmux whatever its file is called; an acpmux above it is skipped too.
    let table = [
        info(9, 8, "/Applications/cmux.app/Contents/Resources/bin/cmux", &["cmux", "acp"]),
        info(8, 7, "/usr/local/bin/acpmux", &["acpmux", "run"]),
        info(7, 1, "/usr/local/bin/glaeda-gh", &["glaeda-gh"]),
    ];
    let found = programs(of(&table), exists, 9);
    assert_eq!(found.nearest.unwrap().path.as_deref(), Some("/usr/local/bin/glaeda-gh"));
    // A relative script with no working directory read (macOS) keeps its name and no path.
    let mut relay = info(8, 1, "/usr/bin/python3", &["python3", "tools/relay.py"]);
    relay.cwd = None;
    let table = [info(9, 8, "acpmux", &["acpmux"]), relay];
    let resolve = |arg: &str, cwd: Option<&str>| exists(arg, cwd);
    let found = programs(of(&table), resolve, 9);
    let nearest = found.nearest.unwrap();
    assert_eq!((nearest.name.as_str(), nearest.path), ("relay.py", None));
    assert_eq!(nearest.interpreter.as_deref(), Some("python3"));
}

#[test]
fn a_script_speaking_to_the_socket_itself_is_the_program() {
    let table = [
        info(9, 8, "/usr/bin/python3", &["python3", "/t/notify.py", "--to", "lane"]),
        info(8, 1, "/bin/zsh", &["-zsh"]),
    ];
    let found = programs(of(&table), exists, 9);
    assert_eq!(found.nearest.unwrap().name, "notify.py");
    assert_eq!(found.paths, vec!["/usr/bin/python3", "/t/notify.py", "/bin/zsh"]);
}

#[test]
fn procargs_parse_argc_then_argv() {
    let mut buf = 3i32.to_ne_bytes().to_vec();
    buf.extend_from_slice(b"/usr/bin/python3\0\0\0\0python3\0/t/relay.py\0run\0PATH=/bin\0");
    assert_eq!(parse_procargs(&buf).unwrap(), vec!["python3", "/t/relay.py", "run"]);
    assert_eq!(parse_procargs(b"\x01"), None);
    assert_eq!(split_args(b"a\0\0b\0c", 2), vec!["a", "b"]);
}

fn registry() -> Registry {
    let text = format!(
        r#"{{"senders": {{"outbox-relay": {{"programs": ["{RELAY}", "relative/x.py", 7]}},
                          "glaeda-gh": {{"programs": ["/usr/local/bin/glaeda-gh"]}},
                          " bad name": {{"programs": ["/x"]}},
                          "empty": {{"programs": []}}}}}}"#
    );
    Registry::parse(&text, |p| (p == RELAY).then(|| "/real/outbox_relay.py".to_owned())).unwrap()
}

#[test]
fn the_registry_keeps_named_absolute_programs_and_their_canonical_paths() {
    let r = registry();
    assert_eq!(r.names_for(&[RELAY.to_owned()]), vec!["outbox-relay"]);
    assert_eq!(r.names_for(&["/real/outbox_relay.py".to_owned()]), vec!["outbox-relay"]);
    assert!(r.names_for(&["relative/x.py".to_owned()]).is_empty(), "absolute paths only");
    assert!(r.names_for(&["/x".to_owned()]).is_empty(), "a name that does not fit is skipped");
    // A tool run under a registered wrapper: any path in the chain matches.
    let chain = ["/usr/bin/python3".to_owned(), "/usr/local/bin/glaeda-gh".to_owned()];
    assert_eq!(r.names_for(&chain), vec!["glaeda-gh"]);
    assert_eq!(Registry::parse("[]", |_| None), None);
    assert_eq!(Registry::parse("not json", |_| None), None);
}

#[cfg(unix)]
#[test]
fn only_an_owner_only_registry_file_is_read() {
    use std::os::unix::fs::PermissionsExt;
    let dir = tempfile::tempdir().unwrap();
    let path = dir.path().join(REGISTRY_FILE);
    std::fs::write(&path, r#"{"senders": {"relay": {"programs": ["/t/relay.py"]}}}"#).unwrap();
    std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o600)).unwrap();
    assert_eq!(load(&path).names_for(&["/t/relay.py".to_owned()]), vec!["relay"]);
    // Group or other may write (or read) it: ignored.
    std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o644)).unwrap();
    assert!(load(&path).names_for(&["/t/relay.py".to_owned()]).is_empty());
    // A link to an owner-only file is no registry either.
    std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o600)).unwrap();
    let link = dir.path().join("link.json");
    std::os::unix::fs::symlink(&path, &link).unwrap();
    assert!(load(&link).names_for(&["/t/relay.py".to_owned()]).is_empty());
    assert_eq!(load(&dir.path().join("missing.json")), Registry::default());
}

fn checked(program: &str, registered: &[&str]) -> Value {
    json!({"peerPid": 9, "program": program, "programPath": format!("/t/{program}"),
           "interpreter": "python3", "registered": registered})
}

#[test]
fn a_named_sender_whose_program_is_registered_for_that_name_is_verified() {
    let notice = crate::prompt_provenance::notice(
        &json!({"sender": "outbox-relay", "severity": "warn", "title": "t"}),
        "s",
    );
    let notice = crate::prompt_provenance::observed(notice, "unix");
    let labelled = label(notice, Some(&checked("outbox_relay.py", &["outbox-relay"])));
    assert_eq!(labelled["verified"], true);
    assert_eq!(labelled["verifiedBy"], "program");
    assert_eq!(labelled["program"], "outbox_relay.py");
    assert_eq!(labelled["kind"], "notice", "the kind and its sender stay");
    assert!(labelled.get("identified").is_none());

    let named = crate::prompt_provenance::named_sender("outbox-relay", "s");
    let labelled = label(named, Some(&checked("outbox_relay.py", &["outbox-relay"])));
    assert_eq!(labelled["verified"], true);
}

#[test]
fn a_name_its_program_does_not_match_stays_unverified_and_says_what_was_identified() {
    let named = crate::prompt_provenance::named_sender("glaeda-gh", "s");
    let mut found = checked("evil.py", &["outbox-relay"]);
    found["app"] = json!("Xcode.app");
    let labelled = label(named, Some(&found));
    assert_eq!(labelled["verified"], false);
    assert!(labelled.get("verifiedBy").is_none());
    assert_eq!(labelled["identified"], json!({"program": "evil.py", "app": "Xcode.app"}));

    let unnamed =
        crate::prompt_provenance::unverified("s", "unix", serde_json::Map::new());
    let labelled = label(unnamed, Some(&checked("outbox_relay.py", &["outbox-relay"])));
    assert_eq!(labelled["verified"], false, "no name, nothing to verify");
    assert_eq!(labelled["identified"], json!({"program": "outbox_relay.py"}));
    // Nothing checked: as it was.
    let plain = crate::prompt_provenance::unverified("s", "unix", serde_json::Map::new());
    assert_eq!(label(plain.clone(), None), plain);
}

#[test]
fn a_session_the_daemon_bound_is_left_as_it_is() {
    let mut session = crate::prompt_provenance::session_message("acp:a", "lane", "s");
    session["verified"] = json!(true);
    assert_eq!(label(session.clone(), Some(&checked("x.py", &["lane"]))), session);
    // An agent message a client sent with its own `from` (no named sender) is not relabelled.
    let message = json!({"kind": "agent_message", "from": "acp:x", "fromName": "relay", "to": "s"});
    assert_eq!(label(message.clone(), Some(&checked("x.py", &["relay"]))), message);
}

#[test]
fn the_registrys_name_goes_to_an_unnamed_send_only_when_one_name_matches() {
    let with = |registered: &[&str]| {
        json!({"_meta": {"acpmux": {"senderHarnessChecked": checked("r.py", registered)}}})
    };
    assert_eq!(registered_name(&with(&["outbox-relay"])).as_deref(), Some("outbox-relay"));
    assert_eq!(registered_name(&with(&["a", "b"])), None);
    assert_eq!(registered_name(&with(&[])), None);
    assert_eq!(registered_name(&json!({})), None);
    assert!(scripted(&with(&[])));
    let typed = json!({"_meta": {"acpmux": {"senderHarnessChecked": {"program": "zsh"}}}});
    assert!(!scripted(&typed), "the person's interactive shell is no script");
}

#[test]
fn a_carried_check_keeps_only_bounded_program_fields() {
    let mut kept = Map::new();
    let found = json!({"program": "a\u{7}b", "programPath": "/t/a.py", "interpreter": "python3",
                       "registered": ["ok", " bad", 3], "extra": "dropped"});
    kept_fields(&found, &mut kept);
    assert_eq!(
        Value::Object(kept),
        json!({"program": "ab", "programPath": "/t/a.py", "interpreter": "python3",
               "registered": ["ok"]})
    );
}
