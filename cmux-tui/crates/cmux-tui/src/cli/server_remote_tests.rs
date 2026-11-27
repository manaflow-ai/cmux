use super::*;

fn words(s: &str) -> Vec<String> {
    s.split_whitespace().map(str::to_owned).collect()
}

fn ep(destination: &str, port: Option<u16>) -> Endpoint {
    Endpoint { destination: destination.to_owned(), port }
}

#[test]
fn endpoints_parse_like_ssh_destinations() {
    let ok = |text: &str| parse_endpoint(text).unwrap().unwrap();
    assert_eq!(ok("ssh://build"), ep("build", None));
    assert_eq!(ok("ssh://ana@build.example.com"), ep("ana@build.example.com", None));
    assert_eq!(ok("ssh://ana@build:2222"), ep("ana@build", Some(2222)));
    assert_eq!(ok("ssh://build/"), ep("build", None));
    assert_eq!(ok("ssh://[::1]:22"), ep("::1", Some(22)));
    assert_eq!(ok("ssh://ana@[fe80::1]"), ep("ana@fe80::1", None));
    assert_eq!(ok("ssh://fe80::1"), ep("fe80::1", None));
    assert!(parse_endpoint("build").is_none());
    assert!(parse_endpoint("unix:///tmp/x").is_none());
    for bad in [
        "ssh://",
        "ssh://-oProxyCommand=x",
        "ssh://ana@-x",
        "ssh://build:0",
        "ssh://build:99999",
        "ssh://build:port",
        "ssh://bu ild",
        "ssh://build;rm",
        "ssh://a'b@build",
        "ssh://build/path",
        "ssh://[::1",
        "ssh://a:b@build",
    ] {
        assert!(parse_endpoint(bad).unwrap().is_err(), "{bad}");
    }
}

#[test]
fn requests_come_from_the_server_words() {
    let req = request(&words("install ssh://ana@build --yes --json")).unwrap().unwrap();
    assert!(req.install && req.yes && req.json && !req.nightly);
    assert_eq!(req.endpoint, ep("ana@build", None));
    let req = request(&words("uninstall ssh://build:2200")).unwrap().unwrap();
    assert!(!req.install && !req.yes);
    assert_eq!(req.endpoint.port, Some(2200));
    assert!(request(&words("install --nightly ssh://b")).unwrap().unwrap().nightly);
    // Local verbs are not remote requests.
    assert!(request(&words("install")).is_none());
    assert!(request(&words("install --binary")).is_none());
    assert!(request(&words("status")).is_none());
    // Flags that only mean something here are refused with an endpoint.
    assert!(request(&words("install ssh://b --binary")).unwrap().is_err());
    // A flag the verb does not take is the local parser's usage error.
    assert!(request(&words("uninstall ssh://b --nightly")).is_none());
    assert!(request(&words("install ssh://-x")).unwrap().is_err());
}

#[test]
fn the_remote_commands_are_fixed_words() {
    let argv = ssh_argv(&ep("ana@build", Some(2222)), "true", false);
    assert_eq!(&argv[..2], ["ssh", "-T"]);
    assert_eq!(&argv[argv.len() - 5..], ["-p", "2222", "--", "ana@build", "true"]);
    let commit = "0123456789abcdef0123456789abcdef01234567";
    assert_eq!(
        installer_command(Build::Commit(commit), false),
        format!("sh -s -- --commit {commit} --server")
    );
    assert_eq!(installer_command(Build::Nightly, false), "sh -s -- --channel nightly --server");
    assert_eq!(installer_command(Build::Stable, true), "sh -s -- --channel stable --server --user");
    assert_eq!(status_command(), "\"$HOME/.local/bin/cmux-tui\" daemon status --session main");
    assert!(uninstall_command().contains("server uninstall"));
    assert_eq!(
        connect_action(&ep("ana@build", None), None),
        ["action", "run", "remote.connect", "--destination", "ana@build"]
    );
    assert_eq!(connect_action(&ep("b", Some(2200)), None)[4], "ssh://b:2200");
    assert_eq!(
        connect_action(&ep("b", None), Some("studio box")),
        ["action", "run", "remote.connect", "--destination", "b", "--name", "studio box"]
    );
}

/// The options between `ssh` and `--`, as `-o` values.
fn ssh_options(argv: &[String]) -> Vec<&str> {
    let end = argv.iter().position(|a| a == "--").unwrap();
    argv[..end].windows(2).filter(|w| w[0] == "-o").map(|w| w[1].as_str()).collect()
}

#[test]
fn ssh_forwards_nothing_and_never_weakens_host_key_checks() {
    for batch in [false, true] {
        let argv = ssh_argv(&ep("ana@build", None), "true", batch);
        let options = ssh_options(&argv);
        for wanted in [
            "ForwardAgent=no",
            "ForwardX11=no",
            "ClearAllForwardings=yes",
            "PermitLocalCommand=no",
            "RemoteCommand=none",
        ] {
            assert!(options.contains(&wanted), "{wanted} missing: {argv:?}");
        }
        assert_eq!(options.contains(&"BatchMode=yes"), batch, "{argv:?}");
        for word in &argv {
            let lower = word.to_ascii_lowercase();
            assert!(!lower.contains("stricthostkeychecking"), "{argv:?}");
            assert!(!lower.contains("userknownhostsfile"), "{argv:?}");
            assert!(!lower.starts_with("-a") || word == "-T", "{argv:?}");
        }
        assert!(!argv.iter().any(|a| a == "-A" || a == "-X" || a == "-Y"), "{argv:?}");
        // The destination is one word after `--`, so it can never be an option.
        let at = argv.iter().position(|a| a == "--").unwrap();
        assert_eq!(argv[at + 1], "ana@build");
    }
}

#[test]
fn remote_install_takes_user_and_channel() {
    let req = request(&words("install ssh://b --user --channel stable")).unwrap().unwrap();
    assert!(req.user && req.stable && !req.nightly);
    let req = request(&words("install ssh://b --channel nightly")).unwrap().unwrap();
    assert!(req.nightly && !req.stable && !req.user);
    assert!(request(&words("uninstall ssh://b --user")).unwrap().unwrap().user);
    let req = request(&words("install ssh://b --label studio")).unwrap().unwrap();
    assert_eq!(req.label.as_deref(), Some("studio"));
    assert_eq!(request(&words("install ssh://b")).unwrap().unwrap().label, None);
    for bad in [
        "install ssh://b --channel beta",
        "install ssh://b --channel stable --nightly",
        "install ssh://b --channel",
        "install ssh://b --label",
        "uninstall ssh://b --label studio",
    ] {
        assert!(request(&words(bad)).is_none_or(|r| r.is_err()), "{bad}");
    }
}

#[test]
fn only_published_commits_are_pinned() {
    let commit = "0123456789abcdef0123456789abcdef01234567";
    assert_eq!(install_commit(commit), Some(commit));
    assert_eq!(install_commit(&format!("{commit}-dirty.abc")), None);
    assert_eq!(install_commit("0123456789ABCDEF0123456789abcdef01234567"), None);
    assert_eq!(install_commit("abc"), None);
}

#[test]
fn the_built_in_installer_is_the_served_one_with_the_server_step() {
    assert!(INSTALLER.starts_with("#!/bin/sh\n"));
    assert!(INSTALLER.contains("--server) want_server=1"));
    assert!(INSTALLER.contains("\"$bin_dir/cmux\" server install \"$@\""));
    assert!(INSTALLER.contains("--channel | --channel=*)"));
    // One `{ ... }` group: a cut-short stdin runs nothing.
    assert!(INSTALLER.ends_with("|| true\n}\n"));
    assert!(INSTALLER.contains("checksum verification failed"));
}
