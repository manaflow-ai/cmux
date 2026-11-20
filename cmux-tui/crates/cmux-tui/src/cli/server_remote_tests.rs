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
    assert_eq!(
        ssh_argv(&ep("ana@build", Some(2222)), "true"),
        ["ssh", "-o", "ConnectTimeout=20", "-p", "2222", "--", "ana@build", "true"]
    );
    let commit = "0123456789abcdef0123456789abcdef01234567";
    assert_eq!(installer_command(Some(commit)), format!("sh -s -- --commit {commit} --server"));
    assert_eq!(installer_command(None), "sh -s -- --server");
    assert_eq!(status_command(), "\"$HOME/.local/bin/cmux-tui\" daemon status --session main");
    assert!(uninstall_command().contains("server uninstall"));
    assert_eq!(
        connect_action(&ep("ana@build", None)),
        ["action", "run", "remote.connect", "--destination", "ana@build"]
    );
    assert_eq!(connect_action(&ep("b", Some(2200)))[4], "ssh://b:2200");
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
    assert!(INSTALLER.contains("\"$bin_dir/cmux\" server install"));
    assert!(INSTALLER.contains("checksum verification failed"));
}
