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

/// The folder a failed clone made, opened the way `clone_into` opens it.
#[cfg(unix)]
fn made(target: &Path) -> std::fs::File {
    use std::os::unix::fs::OpenOptionsExt as _;
    std::fs::create_dir(target).unwrap();
    std::fs::OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_DIRECTORY | libc::O_NOFOLLOW)
        .open(target)
        .unwrap()
}

/// Codex review F1 on #40513: the agent renames the clone's folder while git runs and puts
/// another folder at its name; a failed clone then removes only what is in the folder it made,
/// and nothing of the replacement.
#[cfg(unix)]
#[test]
fn a_failed_clone_removes_nothing_of_a_folder_put_in_its_place() {
    let d = tempfile::tempdir().unwrap();
    let target = d.path().join("r");
    let dir = made(&target);
    std::fs::create_dir_all(target.join(".git/objects")).unwrap();
    std::fs::write(target.join(".git/objects/pack"), "partial").unwrap();
    std::fs::write(target.join("README"), "partial").unwrap();
    std::fs::rename(&target, d.path().join("moved")).unwrap();
    std::fs::create_dir_all(target.join("work")).unwrap();
    std::fs::write(target.join("work/keep.txt"), "the agent's").unwrap();
    remove_failed(&dir, &target);
    assert_eq!(std::fs::read_to_string(target.join("work/keep.txt")).unwrap(), "the agent's");
    let moved = d.path().join("moved");
    assert!(moved.is_dir(), "the clone's own folder no longer at its name stays, empty");
    assert_eq!(std::fs::read_dir(&moved).unwrap().count(), 0, "what the clone wrote is gone");
}

/// A clone makes no `.git` below its own top folder (no submodules), so one found deeper was
/// moved in by someone else: it is left whole, with the folders above it.
#[cfg(unix)]
#[test]
fn a_failed_clone_leaves_a_repository_moved_into_it() {
    let d = tempfile::tempdir().unwrap();
    let target = d.path().join("r");
    let dir = made(&target);
    std::fs::create_dir_all(target.join("project/.git")).unwrap();
    std::fs::write(target.join("project/.git/config"), "theirs").unwrap();
    std::fs::write(target.join("partial"), "ours").unwrap();
    remove_failed(&dir, &target);
    assert_eq!(std::fs::read_to_string(target.join("project/.git/config")).unwrap(), "theirs");
    assert!(!target.join("partial").exists(), "the clone's own files go");
}

/// A failed clone nobody touched leaves nothing; a link in it is removed, never followed.
#[cfg(unix)]
#[test]
fn a_failed_clone_is_removed_and_its_links_are_not_followed() {
    let d = tempfile::tempdir().unwrap();
    let outside = d.path().join("outside");
    std::fs::create_dir(&outside).unwrap();
    std::fs::write(outside.join("keep"), "x").unwrap();
    let target = d.path().join("r");
    let dir = made(&target);
    std::fs::create_dir_all(target.join(".git/refs")).unwrap();
    std::fs::write(target.join(".git/HEAD"), "ref").unwrap();
    std::os::unix::fs::symlink(&outside, target.join("link")).unwrap();
    remove_failed(&dir, &target);
    assert!(!target.exists(), "the folder the clone made is gone");
    assert!(outside.join("keep").exists(), "a link's target stays");
}

/// Codex review round 4, F2: a clone leaves out every path `sandbox/remote-chain.sb` forbids
/// the agent to write, at any depth and in any case, and nothing else.
#[cfg(unix)]
#[test]
fn a_clone_leaves_out_the_paths_the_sandbox_forbids() {
    use super::checkout::{kept_out, sparse_patterns};
    for out in [
        "CLAUDE.md",
        "docs/agents.md",
        "Claude.local.md",
        "AGENTS.override.md",
        "GEMINI.md",
        ".claude/settings.json",
        "a/.codex/config.toml",
        ".vscode/tasks.json",
        ".zed/settings.json",
        ".idea/x.xml",
        ".husky/pre-commit",
        "sub/.githooks/pre-push",
        ".cursor/rules",
        ".windsurf/x",
        ".cursorrules",
        ".mcp.json",
        "deep/.envrc",
        ".pre-commit-config.yaml",
        "lefthook.yml",
        ".tool-versions",
        "mise.toml",
        ".mise.local.toml",
        "mise/config.toml",
        ".mise/config.toml",
        ".config/mise/config.toml",
        ".hg/hgrc",
        ".github/copilot-instructions.md",
        "fake/HEAD",
        "vendor/.git/config",
    ] {
        assert!(kept_out(out.as_bytes()), "{out} is left out");
    }
    for kept in [
        "README.md",
        "src/claude.rs",
        "docs/CLAUDE.md.txt",
        ".github/workflows/ci.yml",
        "config.toml",
        "HEADER",
        ".gitignore",
        ".gitattributes",
        "my.claude/x",
    ] {
        assert!(!kept_out(kept.as_bytes()), "{kept} is checked out");
    }
    let paths: [&[u8]; 3] = [b"CLAUDE.md", b"a b/[x]*?.envrc ", b"\\.envrc"];
    assert_eq!(
        String::from_utf8(sparse_patterns(&paths).unwrap()).unwrap(),
        "/*\n!/CLAUDE.md\n!/a b/\\[x]\\*\\?.envrc\\ \n!/\\\\.envrc\n"
    );
    let broken: [&[u8]; 1] = [b"bad\n/CLAUDE.md"];
    assert!(sparse_patterns(&broken).is_none(), "a line break is refused");
}
