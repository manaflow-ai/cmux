use super::*;

fn clone_of(repo: &str, dir: Option<&str>) -> GithubActionParams {
    GithubActionParams {
        session_id: None,
        action: GithubAction::Clone,
        repo: repo.into(),
        branch: None,
        base: None,
        issue: None,
        title: None,
        body: None,
        dir: dir.map(str::to_owned),
        deadline_ms: None,
    }
}

/// `DIR` is one new plain name: nothing that leaves the chat's folder, names `.git`, or reads
/// as a flag.
#[test]
fn a_dir_that_escapes_or_is_not_one_name_is_refused() {
    for bad in ["", "..", ".", ".git", "a/b", "/tmp/x", "../x", "-x", "a\\b", "a b", "x\n", "é"] {
        assert!(valid_dir(bad).is_err(), "{bad:?}");
        let r = clone_of("o/r", Some(bad));
        assert_eq!(crate::github_broker::validate(&r).unwrap_err().code, -32602, "{bad:?}");
    }
    assert!(valid_dir(&"a".repeat(101)).is_err());
    for good in ["r", "my-repo", "repo.v2", "a_b"] {
        assert!(valid_dir(good).is_ok(), "{good}");
    }
    assert_eq!(dir_name(&clone_of("o/r.git", None)), "r");
    assert_eq!(dir_name(&clone_of("o/r", Some("x"))), "x");
    // A clone takes only its own fields.
    let mut r = clone_of("o/r", None);
    r.title = Some("t".into());
    assert!(crate::github_broker::validate(&r).is_err());
}

/// A file, a folder or a link (a dangling one too) already there is refused.
#[cfg(unix)]
#[test]
fn a_dir_that_exists_is_refused() {
    let d = tempfile::tempdir().unwrap();
    std::fs::write(d.path().join("file"), "x").unwrap();
    std::fs::create_dir(d.path().join("folder")).unwrap();
    std::os::unix::fs::symlink("/nonexistent-target", d.path().join("link")).unwrap();
    for name in ["file", "folder", "link"] {
        let e = check_target(d.path(), &clone_of("o/r", Some(name))).unwrap_err();
        assert_eq!(e.data.unwrap()["reason"], "github.clone_exists", "{name}");
    }
    assert_eq!(check_target(d.path(), &clone_of("o/r", None)).unwrap(), d.path().join("r"));
}

/// The Mac's credential is taken out of its answer before anything else reads it.
#[test]
fn the_lent_credential_leaves_the_answer() {
    let (v, lent) = take_lent(json!({"output": "", "source": "app", LENT_KEY: "ghs_abc"}));
    assert_eq!(lent.as_deref().map(String::as_str), Some("ghs_abc"));
    assert!(!v.to_string().contains("ghs_abc"), "{v}");
    let (_, none) = take_lent(json!({"output": "", LENT_KEY: ""}));
    assert!(none.is_none());
}

/// With no cmux sign-in lent, the Mac lends no credential (never its keyring login).
#[tokio::test]
async fn the_mac_lends_no_keyring_login_for_a_clone() {
    let mut r = clone_of("o/r", None);
    r.deadline_ms = Some(crate::github_broker::deadline_from(crate::store::now_ms()));
    let v = crate::github_broker::serve_owner("box", serde_json::to_value(&r).unwrap(), None)
        .await
        .unwrap();
    assert!(v.get(LENT_KEY).is_none(), "{v}");
    assert_eq!(v["source"], Value::Null);
}

/// The helper answers only `get` for its one host, from fd 3.
#[cfg(unix)]
#[test]
fn the_helper_answers_only_its_host() {
    let script = helper("github.com");
    let body = script.strip_prefix('!').unwrap();
    let run = |op: &str, input: &str| {
        use std::io::Write as _;
        let mut child = std::process::Command::new("sh")
            .arg("-c")
            .arg(format!("{body} \"$@\" 3<<EOF\npassword=secret\nEOF"))
            .arg("sh")
            .arg(op)
            .stdin(std::process::Stdio::piped())
            .stdout(std::process::Stdio::piped())
            .spawn()
            .unwrap();
        child.stdin.take().unwrap().write_all(input.as_bytes()).unwrap();
        String::from_utf8(child.wait_with_output().unwrap().stdout).unwrap()
    };
    assert_eq!(run("get", "protocol=https\nhost=github.com\n"), "password=secret\n");
    assert_eq!(run("get", "protocol=https\nhost=evil.example\n"), "");
    assert_eq!(run("store", "protocol=https\nhost=github.com\n"), "");
}
