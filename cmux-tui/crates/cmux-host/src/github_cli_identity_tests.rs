use std::io::{BufRead, BufReader, Write};
use std::os::unix::net::UnixListener;
use std::path::PathBuf;

use serde_json::{Value, json};

use super::*;

const TOKEN: &str = "ghs_16C7e42F292c6912E7710c838347Ae178B4a";

fn args(v: &[&str]) -> Vec<String> {
    v.iter().map(|s| (*s).to_owned()).collect()
}

/// A fake Cloud agent: reads one line, answers `reply`, returns the line.
fn fake_agent(reply: String) -> (tempfile::TempDir, PathBuf, std::thread::JoinHandle<String>) {
    let dir = tempfile::tempdir().unwrap();
    let socket = dir.path().join("agent.sock");
    let listener = UnixListener::bind(&socket).unwrap();
    let thread = std::thread::spawn(move || {
        let (stream, _) = listener.accept().unwrap();
        let mut line = String::new();
        BufReader::new(stream.try_clone().unwrap()).read_line(&mut line).unwrap();
        let mut stream = stream;
        stream.write_all(format!("{reply}\n").as_bytes()).unwrap();
        line
    });
    (dir, socket, thread)
}

/// Runs `gh_args` against a fake agent answering `reply`; checks the agent was
/// asked `{"github_status": {}}` and nothing printed holds a token.
fn run(gh_args: &[&str], reply: Value) -> Answered {
    let (_dir, socket, agent) = fake_agent(reply.to_string());
    let out =
        answer_from_agent(&args(gh_args), &socket).expect("an identity ask").expect("answered");
    let asked: Value = serde_json::from_str(&agent.join().unwrap()).unwrap();
    assert_eq!(asked, json!({"github_status": {}}));
    for text in [&out.stdout, &out.stderr] {
        assert!(
            !text.contains("ghs_") && !text.contains("ghu_") && !text.contains(TOKEN),
            "{text}"
        );
        assert!(!text.to_ascii_lowercase().contains("scope"), "{text}");
    }
    out
}

fn connected_user() -> Value {
    json!({
        "ok": true, "connected": true, "login": "teamleaderleo", "name": "Leo",
        "htmlUrl": "https://github.com/teamleaderleo",
        "avatarUrl": "https://avatars.githubusercontent.com/u/1?v=4",
        "source": "github-app", "accountType": "user",
        "repositories": {"count": 8, "selection": "selected"},
        // A source that sends a token anyway: it must never be printed.
        "token": TOKEN, "installationToken": TOKEN,
    })
}

#[test]
fn only_the_identity_questions_are_answered() {
    for a in [
        &["auth", "status"][..],
        &["auth", "status", "-a"],
        &["auth", "status", "--show-token"],
        &["auth", "status", "-h", "github.com"],
        &["auth", "status", "--hostname=github.com"],
    ] {
        assert_eq!(identity_ask(&args(a)), Some(IdentityAsk::AuthStatus), "{a:?}");
    }
    assert_eq!(identity_ask(&args(&["api", "user"])), Some(IdentityAsk::User { jq: None }));
    assert_eq!(identity_ask(&args(&["api", "/user"])), Some(IdentityAsk::User { jq: None }));
    assert_eq!(
        identity_ask(&args(&["api", "user", "--jq", ".login"])),
        Some(IdentityAsk::User { jq: Some(".login".into()) })
    );
    assert_eq!(
        identity_ask(&args(&["api", "-q", ".login", "/user"])),
        Some(IdentityAsk::User { jq: Some(".login".into()) })
    );
    assert_eq!(
        identity_ask(&args(&["api", "--method=GET", "user", "--jq=.type"])),
        Some(IdentityAsk::User { jq: Some(".type".into()) })
    );
    for a in [
        &["auth", "status", "-h", "ghe.example.com"][..],
        &["auth", "status", "--json", "hosts"],
        &["auth", "login"],
        &["auth", "token"],
        &["api", "user/repos"],
        &["api", "users/octocat"],
        &["api", "-X", "PATCH", "user"],
        &["api", "user", "-f", "name=x"],
        &["api", "graphql"],
        &["pr", "list"],
        &[],
    ] {
        assert_eq!(identity_ask(&args(a)), None, "{a:?}");
    }
}

#[test]
fn other_gh_runs_never_touch_the_agent() {
    let missing = Path::new("/nonexistent/agent.sock");
    assert!(answer_from_agent(&args(&["pr", "list"]), missing).is_none());
    assert!(answer_from_agent(&args(&["api", "repos/o/r"]), missing).is_none());
}

#[test]
fn auth_status_connected_names_the_account_and_no_token() {
    let out = run(&["auth", "status", "--show-token"], connected_user());
    assert_eq!(out.code, 0);
    assert_eq!(out.stderr, "");
    assert_eq!(
        out.stdout,
        "github.com\n  ✓ Connected through cmux as teamleaderleo (GitHub App installation)\n  - Account type: User\n  - Repositories: 8 selected\n  - Git operations protocol: https\n  - Token: none on this machine; cmux mints a short-lived token per repository when gh or git needs one\n"
    );
}

#[test]
fn api_user_connected_is_a_minimal_user_object() {
    let out = run(&["api", "user"], connected_user());
    assert_eq!(out.code, 0);
    let user: Value = serde_json::from_str(&out.stdout).unwrap();
    assert_eq!(
        user,
        json!({
            "login": "teamleaderleo", "html_url": "https://github.com/teamleaderleo",
            "avatar_url": "https://avatars.githubusercontent.com/u/1?v=4", "name": "Leo",
            "type": "User",
        })
    );
    assert_eq!(
        run(&["api", "/user", "--jq", ".login"], connected_user()).stdout,
        "teamleaderleo\n"
    );
    assert_eq!(run(&["api", "user", "-q", ".id"], connected_user()).stdout, "null\n");
    let bad = run(&["api", "user", "--jq", ".login | ascii_upcase"], connected_user());
    assert_eq!(bad.code, 1);
    assert!(bad.stderr.contains("--jq takes only"), "{}", bad.stderr);
}

#[test]
fn an_organization_account_says_so() {
    let org = json!({
        "ok": true, "connected": true, "login": "manaflow-ai", "accountType": "organization",
        "repositories": {"count": 3, "selection": "all"},
    });
    let out = run(&["auth", "status"], org.clone());
    assert_eq!(out.code, 0);
    assert!(out.stdout.contains("Connected through cmux as manaflow-ai (GitHub App installation)"));
    assert!(out.stdout.contains("  - Account type: Organization (connected by your cmux team)\n"));
    assert!(out.stdout.contains("  - Repositories: all (3)\n"));
    let user: Value = serde_json::from_str(&run(&["api", "user"], org.clone()).stdout).unwrap();
    // Unknown fields are left out; the profile URL follows from the login.
    assert_eq!(
        user,
        json!({"login": "manaflow-ai", "html_url": "https://github.com/manaflow-ai", "type": "Organization"})
    );
    assert_eq!(run(&["api", "user", "--jq", ".type"], org).stdout, "Organization\n");
}

#[test]
fn not_connected_fails_like_gh_and_points_at_cmux() {
    let reply = json!({
        "ok": true, "connected": false,
        "connectUrl": "https://github.com/apps/cmux/installations/new", "token": TOKEN,
    });
    let out = run(&["auth", "status"], reply.clone());
    assert_eq!(out.code, 1);
    assert_eq!(out.stdout, "");
    assert!(out.stderr.starts_with("You are not logged into any GitHub hosts."), "{}", out.stderr);
    assert!(out.stderr.contains("https://github.com/apps/cmux/installations/new"));
    let out = run(&["api", "user", "--jq", ".login"], reply);
    assert_eq!(out.code, 1);
    assert!(out.stderr.starts_with("gh: Requires authentication (HTTP 401)\n"), "{}", out.stderr);
}

#[test]
fn a_token_in_a_profile_field_or_login_is_never_printed() {
    let reply = json!({
        "ok": true, "connected": true, "login": "octocat", "name": TOKEN,
        "htmlUrl": format!("https://github.com/octocat?access_token={TOKEN}"),
        "avatarUrl": format!("https://avatars.githubusercontent.com/{TOKEN}"),
    });
    let user: Value = serde_json::from_str(&run(&["api", "user"], reply).stdout).unwrap();
    assert_eq!(user, json!({"login": "octocat", "html_url": "https://github.com/octocat"}));
    // A login that is a token is no account.
    let out = run(&["auth", "status"], json!({"ok": true, "connected": true, "login": TOKEN}));
    assert_eq!(out.code, 1);
}

#[test]
fn no_answer_leaves_gh_to_run_as_before() {
    let (_dir, socket, agent) = fake_agent(
        json!({"ok": false, "error": {"code": "integration.unreachable", "message": TOKEN}})
            .to_string(),
    );
    let note = answer_from_agent(&args(&["auth", "status"]), &socket).unwrap().unwrap_err();
    agent.join().unwrap();
    assert!(note.contains("integration.unreachable"), "{note}");
    assert!(!note.contains(TOKEN), "{note}");
    let (_dir, socket, agent) = fake_agent("not json".to_owned());
    assert!(answer_from_agent(&args(&["api", "user"]), &socket).unwrap().is_err());
    agent.join().unwrap();
    let missing = Path::new("/nonexistent/agent.sock");
    assert!(answer_from_agent(&args(&["auth", "status"]), missing).unwrap().is_err());
}

#[test]
fn the_persons_own_auth_or_an_own_login_probe_keeps_gh() {
    let applies = |hosts: Option<&str>| identity_applies(false, hosts, None, false);
    assert!(applies(None));
    assert!(applies(Some("")));
    assert!(applies(Some("# no hosts\n")));
    assert!(applies(Some("---\n")));
    assert!(applies(Some("{}\n")));
    // Only comments, blank lines and document markers, indented or not, are no login.
    assert!(applies(Some("\n  # a comment\n\t\n# another\n  ---\n")));
    // Any host login in any form gh reads: github.com, Enterprise, a comment or inline mapping.
    for hosts in [
        "github.com:\n    user: me\n",
        "ghe.example.com:\n    user: me\n",
        "github.com: # personal account\n    user: me\n",
        "github.com: {user: me, oauth_token: x}\n",
        "---\n\"github.com\":\n  user: me\n",
        // An indented root mapping is still valid YAML that gh reads.
        "  github.com:\n      user: me\n",
        "\tghe.example.com: {user: me}\n",
    ] {
        assert!(!applies(Some(hosts)), "{hosts}");
    }
    // A token in the env, another GH_HOST, or acpmux's own-login probe.
    assert!(!identity_applies(true, None, None, false));
    assert!(!identity_applies(false, None, Some("ghe.example.com"), false));
    assert!(identity_applies(false, None, Some("github.com"), false));
    assert!(identity_applies(false, None, Some(""), false));
    assert!(!identity_applies(false, None, None, true));
}
