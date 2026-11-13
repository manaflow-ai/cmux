//! `--from-folder` (a folder on this Mac the chat starts in a copy of) and what `parse` refuses beside it. A child of
//! `tests`, so its fakes and helpers are in scope.

use super::*;

#[test]
fn parse_refuses_what_start_session_would() {
    for words in [
        vec!["--prompt", ""],
        vec!["--prompt", "  "],
        vec!["--prompt", "x", "--cwd", "relative"],
        vec!["--prompt", "x", "--agent", "Claude Code"],
        vec!["--prompt", "x", "--name", "a", "--target", "machine:vm-b"],
        vec!["--prompt", "x", "--timeout", "soon"],
        vec!["--prompt", "x", "--bogus"],
        vec!["--prompt"],
        vec!["--prompt", "x", "--login", "github"],
        vec!["--prompt", "x", "--login", ""],
        vec!["--prompt", "x", "--login"],
        vec!["--prompt", "x", "--environment", " "],
        vec!["--prompt", "x", "--environment"],
        vec!["--environment", "env_1", "--target", "machine:vm-1"],
        vec!["--prompt", "x", "--", "y"],
        vec!["--", "two", "words"],
        vec!["--"],
    ] {
        assert!(parse(&strings(&words), || Ok(String::new())).is_err(), "{words:?}");
    }
    assert_eq!(parse(&strings(&["--help"]), || Ok(String::new())), Ok(Parsed::Help));
}

#[test]
fn from_folder_is_an_existing_folder_of_this_mac_answered_canonical() {
    let dir = tempfile::tempdir().unwrap();
    let canonical = std::fs::canonicalize(dir.path()).unwrap().to_string_lossy().into_owned();
    // A spelling with `.` and `..` parts is the folder's canonical path.
    let spelled = format!("{}/./sub/..", dir.path().display());
    std::fs::create_dir(dir.path().join("sub")).unwrap();
    let parsed = request(&["--prompt", "x", "--from-folder", spelled.as_str()]);
    assert_eq!(parsed.from_folder.as_deref(), Some(canonical.as_str()));
    assert_eq!(parsed.cwd, None);
    let inline = format!("--from-folder={canonical}");
    assert_eq!(
        request(&["--prompt", "x", inline.as_str()]).from_folder.as_deref(),
        Some(canonical.as_str())
    );
    let file = dir.path().join("file.txt");
    std::fs::write(&file, "x").unwrap();
    let missing = dir.path().join("gone");
    for words in [
        // `~` is the shell's to expand: quoted, it is no folder of this shell's.
        vec!["--prompt", "x", "--from-folder", "~/app"],
        vec!["--prompt", "x", "--from-folder", missing.to_str().unwrap()],
        vec!["--prompt", "x", "--from-folder", file.to_str().unwrap()],
        vec!["--prompt", "x", "--from-folder"],
        // `--cwd` is a folder on the machine; `--from-folder` already names where the chat starts.
        vec!["--prompt", "x", "--from-folder", canonical.as_str(), "--cwd", "/home/cmux/work"],
        vec!["--prompt", "x", "--cwd", "/home/cmux/work", "--from-folder", canonical.as_str()],
    ] {
        assert!(parse(&strings(&words), || Ok(String::new())).is_err(), "{words:?}");
    }
    // `--from-folder --json`: the output flag is never taken as its value.
    let mut output = OutputMode::Human;
    let words = lift_output(&strings(&["--from-folder", "--json"]), &mut output);
    assert_eq!((words.len(), output), (2, OutputMode::Human));
}

/// A relative `--from-folder` is a folder of this shell's working directory, answered canonical, as
/// `cloud start-session --from-folder` sends it (`app::run_action`).
#[test]
fn relative_from_folder_of_start_chat_is_of_the_working_directory() {
    let folder = std::fs::canonicalize("src").unwrap().to_string_lossy().into_owned();
    for spelled in ["src", "./src/../src"] {
        let parsed = request(&["--prompt", "x", "--from-folder", spelled]);
        assert_eq!(parsed.from_folder.as_deref(), Some(folder.as_str()), "{spelled}");
    }
    assert!(
        parse(&strings(&["--prompt", "x", "--from-folder", "relative/app"]), || Ok(String::new()))
            .is_err()
    );
}

#[test]
fn from_folder_goes_to_start_session_and_skips_the_relay_chat() {
    let dir = tempfile::tempdir().unwrap();
    let folder = std::fs::canonicalize(dir.path()).unwrap().to_string_lossy().into_owned();
    let mut fake = Fake::new(vec![
        signed_in(),
        started(),
        exec_out("@@history\n{\"turns\":[]}\n@@send\ndelivery-1\n@@exit 0\n"),
        exec_out(
            "@@wait 0\n@@history\n{\"turns\":[{\"seq\":1,\"status\":\"completed\",\"endedAt\":9}]}\n\
             @@last\n{\"sessionId\":\"sess-1\",\"replies\":[\"done\"]}\n@@lastexit 0\n",
        ),
    ]);
    let asked = request(&[
        "--prompt",
        "Run the tests",
        "--from-folder",
        folder.as_str(),
        "--name",
        "dev",
        "--wait",
    ]);
    let Outcome::Done(answer) = run(&mut fake, &asked) else { panic!("{:?}", fake.ran) };
    assert_eq!(answer["reply"], "done");
    // No relay chat: it copies no folder. The start names the folder as its own argument.
    assert!(fake.ran.iter().all(|step| step.get(1).map(String::as_str) != Some("relay-chat")));
    assert_eq!(
        fake.ran[1],
        strings(&[
            "cloud",
            "start-session",
            "--name",
            "dev",
            "--agent",
            "claude",
            "--from-folder",
            folder.as_str(),
            "--json"
        ])
    );
    // The prompt may be private: the command names where it goes, not what it says.
    assert_eq!(
        again_command(&asked, &asked.machine),
        format!(
            "cmux cloud start-chat --name dev --from-folder {} --prompt TEXT --wait --json",
            shell_quote(&folder)
        )
    );
}

#[test]
fn a_pending_start_from_a_folder_says_the_copy_may_still_run() {
    let dir = tempfile::tempdir().unwrap();
    let folder = std::fs::canonicalize(dir.path()).unwrap().to_string_lossy().into_owned();
    let mut fake = Fake::new(vec![
        signed_in(),
        ok(json!({"pending": true, "machine_id": "vm-9", "text": "still starting"})),
        ok(json!({"machines": [{"title": "dev", "machine_id": "vm-9", "status": "running"}]})),
    ]);
    let asked =
        request(&["--prompt", "x", "--target", "machine:vm-9", "--from-folder", folder.as_str()]);
    let Outcome::Failed { error, exit } = run(&mut fake, &asked) else { panic!() };
    assert_eq!(exit, 75);
    assert!(error["message"].as_str().unwrap().contains(&format!("or copying {folder} to it")));
    assert!(error["details"]["again"].as_str().unwrap().contains("--from-folder"));
}

/// `--from-folder` keeps the one deadline (`--wait` with a prompt): the copy runs inside start-session, so with no
/// time left after the list no start (and no copy) begins, and the answer is the typed out-of-time one that asks
/// again with the folder.
#[test]
fn a_from_folder_start_never_begins_past_the_deadline() {
    let dir = tempfile::tempdir().unwrap();
    let folder = std::fs::canonicalize(dir.path()).unwrap().to_string_lossy().into_owned();
    let mut fake = Fake::new(vec![signed_in()]);
    fake.costs.push(("list-machines", Duration::from_secs(30)));
    let asked = request(&[
        "--prompt",
        "x",
        "--name",
        "dev",
        "--from-folder",
        folder.as_str(),
        "--wait",
        "--timeout",
        "30",
    ]);
    let Outcome::Failed { error, exit } = run(&mut fake, &asked) else { panic!("{:?}", fake.ran) };
    assert_eq!((error["code"].as_str(), exit), (Some("cloud.start_pending"), 75), "{error}");
    assert_eq!(fake.ran.len(), 1, "{:?}", fake.ran);
    assert!(error["details"]["again"].as_str().unwrap().contains("--from-folder"), "{error}");
}

/// The app's refusals are checked before any step runs, so `--environment` never makes a machine for a folder
/// the start refuses: home, a folder above it, the disk's root, and a folder in or holding one of home's
/// credential folders, in any case.
#[test]
fn from_folder_refuses_home_above_it_and_credential_folders_before_any_step() {
    use super::super::folder::local_folder_in;
    let root = tempfile::tempdir().unwrap();
    let home = root.path().join("me");
    for dir in ["proj/src", ".ssh/keys", ".config/gh", "Code/.Cargo", "backup/.aws/sub"] {
        std::fs::create_dir_all(home.join(dir)).unwrap();
    }
    let at = |dir: &str| home.join(dir).to_string_lossy().into_owned();
    let above = root.path().to_string_lossy().into_owned();
    // A credential folder anywhere is refused too: its copy would hold only bare names (`credentials`).
    let refused = [String::from("/"), above, at(""), at(".ssh/keys"), at(".config")]
        .into_iter()
        .chain([at("Code/.Cargo"), at("backup/.aws"), at("backup/.aws/sub")]);
    for dir in refused {
        assert!(local_folder_in(&dir, false, Some(&home)).is_err(), "{dir}");
    }
    let project = std::fs::canonicalize(home.join("proj")).unwrap().to_string_lossy().into_owned();
    assert_eq!(local_folder_in(&at("proj"), false, Some(&home)).ok(), Some(project));
    // A folder holding a project's own `.cargo` goes: the copy leaves that out instead.
    assert!(local_folder_in(&at("Code"), false, Some(&home)).is_ok());
    assert!(local_folder_in(&at("proj/src"), false, None).is_ok());
    let control = format!("{}\n", at("proj"));
    assert!(local_folder_in(&control, false, None).is_err());
    assert!(local_folder_in(&format!("/{}", "a".repeat(4096)), false, None).is_err());
}

/// A folder refused for what it is prints its reason and what to do, coded
/// `cloud_start_chat.folder_refused`, never the whole start-chat help; other usage errors keep it.
#[test]
fn a_folder_refusal_is_its_reason_not_the_help() {
    use super::super::folder::{REFUSED_CODE, local_folder_in, refusal};
    let root = tempfile::tempdir().unwrap();
    let home = std::fs::canonicalize(root.path()).unwrap();
    let error = local_folder_in(&home.to_string_lossy(), false, Some(&home)).unwrap_err();
    let reason = refusal(&error).expect("a folder refusal");
    assert!(reason.contains("Pick the project folder inside it"), "{reason}");
    assert!(!reason.contains("usage:") && !reason.contains('\u{1}'), "{reason}");
    assert_eq!(REFUSED_CODE, "cloud_start_chat.folder_refused");
    let both = local_folder_in(&home.to_string_lossy(), true, Some(&home)).unwrap_err();
    assert_eq!(refusal(&both), None, "--cwd with --from-folder is a usage error");
    let parsed = parse(&strings(&["--prompt", "x", "--bogus"]), || Ok(String::new()));
    assert_eq!(parsed.map_err(|error| refusal(&error).is_none()), Err(true));
}

/// `--allow-large` is a flag of the start, never taken out of a prompt: `--prompt --allow-large`
/// and `-- --allow-large` send that text.
#[test]
fn allow_large_is_a_flag_never_a_prompt() {
    assert!(request(&["--prompt", "x", "--allow-large"]).allow_large);
    let asked = request(&["--prompt", "--allow-large"]);
    assert_eq!((asked.prompt.as_deref(), asked.allow_large), (Some("--allow-large"), false));
    let literal = request(&["--", "--allow-large"]);
    assert_eq!((literal.prompt.as_deref(), literal.allow_large), (Some("--allow-large"), false));
}
