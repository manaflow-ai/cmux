use super::{claim, deep_enough, is_partial, origin_url, too_broad};

#[test]
fn a_repository_root_is_never_a_home_or_top_folder() {
    for (path, ok) in [
        ("/", false),
        ("/home", false),
        ("/home/cmux", false),
        ("/home/cmux/app", true),
        ("/root", false),
        ("/root/app", true),
        ("/Users/me", false),
        ("/Users/me/app", true),
        ("/work/a", false),
        ("/work/a/b", true),
    ] {
        assert_eq!(deep_enough(path), ok, "{path}");
    }
    for (path, broad) in [
        ("/", true),
        ("", true),
        ("/home", true),
        ("/tmp", true),
        ("/root", true),
        ("/root/", true),
        ("/home/cmux", true),
        ("/home/cmux/", true),
        ("/Users/me", true),
        ("/home/cmux/../..", true),
        ("/home/cmux/app", false),
        ("/root/app", false),
        ("/workspace/app", false),
        ("/tmp/x", false),
    ] {
        assert_eq!(too_broad(path), broad, "{path}");
    }
}

#[test]
fn agent_and_tool_sign_ins_never_come_over_but_project_settings_do() {
    use crate::link::access_cli::is_secret;
    for path in [
        ".codex/auth.json",
        "x/.claude/.credentials.json",
        ".claude.json",
        ".config/gh/hosts.yml",
        ".Docker/Config.json",
    ] {
        assert!(is_secret(path), "{path}");
    }
    for path in
        [".claude/settings.json", ".claude/commands/review.md", ".config/app.toml", "src/auth.json"]
    {
        assert!(!is_secret(path), "{path}");
    }
}

#[test]
fn a_seed_clone_is_partial_and_a_copy_is_not() {
    let seed = "[core]\n\trepositoryformatversion = 1\n[remote \"origin\"]\n\turl = https://github.com/acme/app.git\n\tpromisor = true\n\tpartialclonefilter = blob:none\n";
    assert!(is_partial(seed));
    assert!(!is_partial(
        "[core]\n\tbare = false\n[remote \"origin\"]\n\turl = https://github.com/acme/app.git\n"
    ));
}

#[test]
fn only_a_plain_https_origin_is_taken_from_the_machine() {
    let config = |url: &str| {
        format!(
            "[remote \"upstream\"]\n\turl = https://evil.test/x\n[remote \"origin\"]\n\turl = {url}\n"
        )
    };
    assert_eq!(
        origin_url(&config("https://github.com/acme/app.git")).as_deref(),
        Some("https://github.com/acme/app.git")
    );
    assert_eq!(origin_url(&config("https://token@github.com/acme/app.git")), None);
    assert_eq!(origin_url(&config("file:///Users/me/secret")), None);
    assert_eq!(origin_url(&config("/Users/me/repo")), None);
    assert_eq!(origin_url(&config("ext::sh -c touch% /tmp/pwned")), None);
    assert_eq!(origin_url("[core]\n"), None);
}

#[test]
fn only_a_new_or_empty_folder_is_claimed() {
    let dir = tempfile::tempdir().unwrap();
    let fresh = dir.path().join("a/b");
    assert!(claim(&fresh).unwrap());
    assert!(!claim(&fresh).unwrap());
    std::fs::write(fresh.join("x"), "1").unwrap();
    assert!(claim(&fresh).is_err());
}
