use super::*;
use std::os::unix::net::UnixListener;

const SECRET: &str = "ghs_fake_installation_token_0000000000";

fn strings(v: &[&str]) -> Vec<String> {
    v.iter().map(|s| (*s).to_owned()).collect()
}

fn minted() -> Minted {
    Minted { token: SECRET.to_owned() }
}

#[test]
fn repos_come_from_github_paths_and_urls_only() {
    for raw in [
        "manaflow-ai/cmux",
        "manaflow-ai/cmux.git",
        "/manaflow-ai/cmux.git/",
        "manaflow-ai/cmux.git/info/lfs",
        "github.com/manaflow-ai/cmux",
        "https://github.com/manaflow-ai/cmux.git",
        "https://x-access-token@github.com/manaflow-ai/cmux",
        "ssh://git@github.com/manaflow-ai/cmux.git",
        "git@github.com:manaflow-ai/cmux.git",
    ] {
        assert_eq!(repo_from(raw).as_deref(), Some("manaflow-ai/cmux"), "{raw}");
    }
    assert_eq!(repo_from("https://github.com:443/o/r").as_deref(), Some("o/r"));
    assert_eq!(repo_from("ssh://git@github.com:22/o/r.git").as_deref(), Some("o/r"));
    assert_eq!(repo_from("https://user:pat@github.com/o/r").as_deref(), Some("o/r"));
    for raw in [
        "https://github.com.evil.com/a/b",
        "https://github.com:x/a/b",
        "https://gitlab.com/a/b",
        "git@gitlab.com:a/b.git",
        "a",
        "a/b/c",
        "a/..",
        "",
    ] {
        assert_eq!(repo_from(raw), None, "{raw}");
    }
}

#[test]
fn get_answers_github_https_with_a_write_token_first() {
    let mut asked = Vec::new();
    let (out, note) = credential_get(
        "protocol=https\nhost=github.com\npath=manaflow-ai/cmux.git\n\n",
        GitOp::Unknown,
        false,
        &mut |ask| {
            asked.push(ask.clone());
            Ok(minted())
        },
    );
    assert_eq!(out, format!("username=x-access-token\npassword={SECRET}\n"));
    assert_eq!(note, None);
    assert_eq!(asked.len(), 1);
    assert_eq!(asked[0].repo, "manaflow-ai/cmux");
    assert_eq!(Value::Object(asked[0].permissions.clone()), json!({ "contents": "write" }));
}

#[test]
fn a_policy_refusal_of_write_falls_back_to_read() {
    let mut asked = Vec::new();
    let (out, _) = credential_get(
        "protocol=https\nhost=github.com\npath=o/r\n",
        GitOp::Unknown,
        true,
        &mut |ask| {
            asked.push(Value::Object(ask.permissions.clone()));
            if ask.permissions.get("contents") == Some(&json!("read")) {
                Ok(minted())
            } else {
                Err(refused("policy.denied", "over the grant"))
            }
        },
    );
    assert!(out.contains(SECRET));
    assert_eq!(
        asked,
        vec![
            json!({ "contents": "write", "workflows": "write" }),
            json!({ "contents": "write" }),
            json!({ "contents": "read" }),
        ]
    );
}

#[test]
fn other_refusals_stop_and_leave_git_no_answer() {
    let mut calls = 0;
    let (out, note) = credential_get(
        "protocol=https\nhost=github.com\npath=o/r\n",
        GitOp::Unknown,
        false,
        &mut |_| {
            calls += 1;
            Err(refused("integration.not_found", "no GitHub connection"))
        },
    );
    assert_eq!(out, "");
    assert_eq!(calls, 1);
    let note = note.unwrap();
    assert!(note.starts_with("o/r: integration.not_found: no GitHub connection. Next: "), "{note}");
    assert!(note.contains("`cmux accounts github-connect`"), "{note}");
    assert!(!note.contains(SECRET));
}

#[test]
fn get_ignores_other_hosts_and_asks_for_a_path() {
    let mut never = |_: &TokenAsk| -> Result<Minted, Refused> { panic!("no ask expected") };
    assert_eq!(
        credential_get(
            "protocol=https\nhost=gitlab.com\npath=o/r\n",
            GitOp::Unknown,
            false,
            &mut never
        ),
        (String::new(), None)
    );
    assert_eq!(
        credential_get(
            "protocol=http\nhost=github.com\npath=o/r\n",
            GitOp::Unknown,
            false,
            &mut never
        ),
        (String::new(), None)
    );
    let (out, note) =
        credential_get("protocol=https\nhost=github.com\n", GitOp::Unknown, false, &mut never);
    assert_eq!(out, "");
    assert!(note.unwrap().contains("cmux github setup"));
}

#[test]
fn gh_takes_its_repo_from_flags_env_then_origin() {
    let none = || None;
    let origin = || Some("git@github.com:o/from-origin.git".to_owned());
    let plan =
        gh_plan(&strings(&["--write", "pr", "create", "-R", "o/r"]), Some("x/y"), &none).unwrap();
    assert_eq!(
        plan,
        GhPlan {
            repo: "o/r".to_owned(),
            write: true,
            args: strings(&["pr", "create", "-R", "o/r"])
        }
    );
    assert_eq!(
        gh_plan(&strings(&["pr", "view", "--repo=o/r2"]), None, &none).unwrap().repo,
        "o/r2"
    );
    // Every shorthand -R form names the repo, and one on another host
    // (or a value that only looks like -R) is refused, never left to gh.
    let repo_of = |v: &[&str]| gh_plan(&strings(v), Some("o/env"), &none).map(|p| p.repo);
    assert_eq!(repo_of(&["pr", "view", "-Ro/r3"]).unwrap(), "o/r3");
    assert_eq!(repo_of(&["pr", "view", "-R=o/r4"]).unwrap(), "o/r4");
    assert_eq!(repo_of(&["pr", "view", "-wR", "o/r5"]).unwrap(), "o/r5");
    assert!(repo_of(&["pr", "view", "-Revil.example.com/o/r"]).is_err());
    assert!(repo_of(&["pr", "view", "-R=evil.example.com/o/r"]).is_err());
    assert!(repo_of(&["issue", "create", "--title", "-Rfoo"]).is_err());
    assert!(
        gh_plan(&strings(&["api", "x", "--hostname", "evil.ghe.com"]), Some("o/r"), &none).is_err()
    );
    assert!(gh_plan(&strings(&["api", "x", "--hostname=GitHub.com"]), Some("o/r"), &none).is_ok());
    // URL arguments: https to GitHub's hosts only, never plaintext.
    let url = |v: &[&str]| gh_plan(&strings(v), Some("o/r"), &none).is_ok();
    assert!(url(&["api", "https://api.github.com/repos/o/r"]));
    assert!(url(&["pr", "view", "https://github.com/o/r/pull/1"]));
    assert!(url(&["pr", "create", "--body", "see http://example.com"]));
    assert!(!url(&["api", "http://github.com/secret"]));
    assert!(!url(&["api", "https://github.com.evil/x"]));
    assert!(!url(&["api", "HTTPS://evil.example.com"]));
    assert!(!url(&["api", "https://x@api.github.com/repos"]));
    // HOST/owner/name positionals: github.com only.
    assert!(!url(&["repo", "view", "evil.ghe.com/o/r"]));
    assert!(!url(&["repo", "clone", "Evil.Example.com/o/r"]));
    assert!(url(&["repo", "view", "github.com/o/r"]));
    assert!(url(&["repo", "view", "o/r"]));
    assert!(url(&["api", "repos/o/r"]));
    assert!(url(&["gist", "create", "../a/b"]));
    assert!(!url(&["repo", "view", "evil.ghe.com:443/o/r"]));
    assert!(!url(&["repo", "view", "github.com:443/o/r"]));
    assert!(!url(&["repo", "view", "evil:443/o/r"]));
    assert!(!url(&["repo", "view", "[::1]/o/r"]));
    assert!(!url(&["repo", "view", "evil.example.com/o/r/extra"]));
    assert!(!url(&["pr", "list", "--repo=evil.ghe.com/o/r"]));
    assert!(!url(&["api", "--hostname", "github.com", "-F", "h=x.GHE.com"]));
    let env = gh_plan(&strings(&["--", "pr", "list"]), Some("o/env"), &origin).unwrap();
    assert_eq!(
        (env.repo.as_str(), env.write, env.args),
        ("o/env", false, strings(&["pr", "list"]))
    );
    assert_eq!(gh_plan(&strings(&["pr", "list"]), None, &origin).unwrap().repo, "o/from-origin");
    assert!(gh_plan(&strings(&["pr", "list"]), None, &none).is_err());
    assert!(gh_plan(&strings(&["pr", "list", "-R", "gitlab.com/o/r"]), None, &none).is_err());
}

#[test]
fn gh_asks_reads_unless_write() {
    let read = gh_ask("o/r", false);
    assert!(read.permissions.values().all(|v| v == "read"));
    let write = gh_ask("o/r", true);
    assert_eq!(write.permissions["contents"], "write");
    assert_eq!(write.permissions["pull_requests"], "write");
    assert_eq!(write.permissions["checks"], "read");
    assert!(!write.permissions.contains_key("workflows"));
}

#[test]
fn setup_finds_this_binary_by_an_absolute_path() {
    let dir = tempfile::tempdir().unwrap();
    std::fs::create_dir(dir.path().join("bin")).unwrap();
    use std::os::unix::fs::PermissionsExt;
    let exe = std::fs::Permissions::from_mode(0o755);
    std::fs::write(dir.path().join("bin/cmux"), "").unwrap();
    std::fs::set_permissions(dir.path().join("bin/cmux"), exe).unwrap();
    // A non-executable `cmux` earlier on PATH is skipped, as a shell does.
    std::fs::create_dir(dir.path().join("decoy")).unwrap();
    std::fs::write(dir.path().join("decoy/cmux"), "").unwrap();
    let cwd = dir.path();
    let path = |v: &str| Some(std::ffi::OsString::from(v));
    let found = |argv0: &str, var| program_path(Path::new(argv0), var, cwd);
    assert_eq!(found("cmux", path("/nonexistent:decoy:bin")), Some(cwd.join("bin/cmux")));
    assert_eq!(found("bin/cmux", None), Some(cwd.join("bin/cmux")));
    assert_eq!(
        found("/opt/cmux/current/bin/cmux", None),
        Some(PathBuf::from("/opt/cmux/current/bin/cmux"))
    );
    assert_eq!(found("cmux", path("/nonexistent")), None);
}

#[test]
fn setup_writes_only_the_github_helper_and_use_http_path() {
    let helper = helper_value(Path::new("/opt/cmux/current/bin/cmux"));
    assert_eq!(helper, "!'/opt/cmux/current/bin/cmux' github credential");
    assert_eq!(helper_value(Path::new("/a'b/cmux")), r"!'/a'\''b/cmux' github credential");
    let on = setup_commands(Some(&helper));
    assert_eq!(on[0], strings(&["config", "--global", "--replace-all", HOST_KEY, ""]));
    assert_eq!(on[1], strings(&["config", "--global", "--add", HOST_KEY, &helper]));
    assert_eq!(on[2], strings(&["config", "--global", "--replace-all", PATH_KEY, "true"]));
    let off = setup_commands(None);
    assert_eq!(
        off,
        vec![
            strings(&["config", "--global", "--unset-all", HOST_KEY]),
            strings(&["config", "--global", "--unset-all", PATH_KEY])
        ]
    );
}

#[test]
fn the_git_operation_comes_from_the_nearest_git_command_line() {
    let op = |v: &[&str]| git_op_of(&strings(v));
    assert_eq!(op(&["git", "push", "origin", "HEAD"]), Some(GitOp::Push));
    assert_eq!(
        op(&["/usr/bin/git", "-C", "/w", "-c", "a=b", "--no-pager", "push"]),
        Some(GitOp::Push)
    );
    assert_eq!(op(&["git", "fetch", "origin"]), Some(GitOp::Read));
    assert_eq!(op(&["git", "clone", "https://github.com/o/r"]), Some(GitOp::Read));
    assert_eq!(op(&["git", "pull"]), Some(GitOp::Read));
    assert_eq!(op(&["git", "remote-https", "origin", "https://github.com/o/r"]), None);
    assert_eq!(op(&["git-remote-https", "origin", "https://github.com/o/r"]), None);
    assert_eq!(op(&["/bin/sh", "-c", "cmux github credential get"]), None);
    // git-lfs asks through `git credential fill`; its own subcommand decides.
    assert_eq!(op(&["git", "credential", "fill"]), None);
    assert_eq!(op(&["git-lfs", "fetch"]), Some(GitOp::Read));
    assert_eq!(op(&["git", "lfs", "pull"]), Some(GitOp::Read));
    assert_eq!(op(&["git-lfs", "filter-process"]), Some(GitOp::Read));
    assert_eq!(op(&["git-lfs", "pre-push", "origin"]), Some(GitOp::Push));
    assert_eq!(op(&["git", "lfs", "migrate"]), Some(GitOp::Unknown));
}

#[test]
fn the_ask_timeout_outlasts_the_agents_queue_and_one_mint() {
    let one_mint = Duration::from_secs(120);
    let need = crate::cloud::github_minter::MAX_QUEUE_WAIT.checked_add(one_mint);
    assert!(need.is_some_and(|need| ASK_TIMEOUT >= need));
}

#[test]
fn only_retryable_refusals_are_retried() {
    let with = |code: &str, retry_after| Refused { retry_after, ..refused(code, "") };
    assert_eq!(retry_delay(&with("integration.unavailable", None)), Some(Duration::from_secs(1)));
    assert_eq!(retry_delay(&with("busy", None)), Some(Duration::from_secs(1)));
    assert_eq!(retry_delay(&with("rate_limited", Some(3))), Some(Duration::from_secs(3)));
    assert_eq!(retry_delay(&with("rate_limited", Some(60))), None);
    assert_eq!(retry_delay(&with("policy.denied", None)), None);
}

#[test]
fn fetches_ask_for_read_and_pushes_for_write() {
    let levels = |op, workflows| -> Vec<Value> {
        credential_asks("o/r", op, workflows)
            .into_iter()
            .map(|a| Value::Object(a.permissions))
            .collect()
    };
    assert_eq!(levels(GitOp::Read, true), vec![json!({ "contents": "read" })]);
    assert_eq!(levels(GitOp::Push, false), vec![json!({ "contents": "write" })]);
    assert_eq!(
        levels(GitOp::Push, true),
        vec![json!({ "contents": "write", "workflows": "write" }), json!({ "contents": "write" })]
    );
    assert_eq!(
        levels(GitOp::Unknown, false),
        vec![json!({ "contents": "write" }), json!({ "contents": "read" })]
    );
    let (out, _) = credential_get(
        "protocol=https\nhost=github.com:443\npath=o/r\n",
        GitOp::Read,
        false,
        &mut |ask| {
            assert_eq!(ask.permissions.get("contents"), Some(&json!("read")));
            Ok(minted())
        },
    );
    assert!(out.contains(SECRET));
}

/// A fake Cloud agent: reads one line, answers `reply`, returns the line.
fn fake_agent(
    reply: &'static str,
) -> (tempfile::TempDir, PathBuf, std::thread::JoinHandle<String>) {
    let dir = tempfile::tempdir().unwrap();
    let socket = dir.path().join("agent.sock");
    let listener = UnixListener::bind(&socket).unwrap();
    let thread = std::thread::spawn(move || {
        let (stream, _) = listener.accept().unwrap();
        let mut line = String::new();
        BufReader::new(stream.try_clone().unwrap()).read_line(&mut line).unwrap();
        let mut stream = stream;
        stream.write_all(reply.as_bytes()).unwrap();
        line
    });
    (dir, socket, thread)
}

#[test]
fn ask_agent_sends_one_line_and_reads_the_token() {
    let (_dir, socket, agent) = fake_agent(
        "{\"ok\":true,\"token\":\"ghs_fake_installation_token_0000000000\",\"expires_at\":\"2026-10-25T02:00:00Z\"}\n",
    );
    let ask = gh_ask("o/r", true);
    let got = ask_agent(&socket, &ask).unwrap();
    assert_eq!(got.token, SECRET);
    assert!(!format!("{got:?}").contains(SECRET), "Debug redacts the token");
    let line: Value = serde_json::from_str(&agent.join().unwrap()).unwrap();
    assert_eq!(TokenAsk::from_json(&line["github_token"]).unwrap(), ask);
}

#[test]
fn ask_agent_passes_refusals_through() {
    let (_dir, socket, agent) = fake_agent(
        "{\"ok\":false,\"error\":{\"code\":\"needs_reauth\",\"message\":\"installation suspended\"}}\n",
    );
    let err = ask_agent(&socket, &gh_ask("o/r", false)).unwrap_err();
    assert_eq!(err, refused("needs_reauth", "installation suspended"));
    agent.join().unwrap();
    let (_dir, socket, agent) = fake_agent("not json\n");
    assert_eq!(ask_agent(&socket, &gh_ask("o/r", false)).unwrap_err().code, "vm.agent_bad_answer");
    agent.join().unwrap();
    let missing =
        ask_agent(Path::new("/nonexistent/agent.sock"), &gh_ask("o/r", false)).unwrap_err();
    assert_eq!(missing.code, "vm.agent_unreachable");
}

fn cx<'a>(token_env: bool, own_login: bool, gh_repo: Option<&'a str>) -> GhContext<'a> {
    GhContext { token_env, own_login, gh_repo }
}

fn in_checkout() -> Option<String> {
    Some("git@github.com:o/r.git".to_owned())
}

fn nowhere() -> Option<String> {
    None
}

fn asked(route: &GhRoute) -> Vec<String> {
    let GhRoute::Token { asks, .. } = route else { panic!("not a token route: {route:?}") };
    asks.iter().map(|a| a.permissions["contents"].as_str().unwrap().to_owned()).collect()
}

#[test]
fn auto_leaves_the_persons_own_auth_alone() {
    let args = strings(&["pr", "list"]);
    assert_eq!(gh_auto_route(&args, &cx(true, false, None), &in_checkout), GhRoute::Direct);
    assert_eq!(gh_auto_route(&args, &cx(false, true, None), &in_checkout), GhRoute::Direct);
}

#[test]
fn auto_passes_verbs_that_need_no_repo_token_straight_through() {
    for args in [
        &[][..],
        &["auth", "status"][..],
        &["auth", "login", "--web"][..],
        &["--version"][..],
        &["version"][..],
        &["--help"][..],
        &["help", "pr"][..],
        &["config", "get", "editor"][..],
        &["extension", "list"][..],
        &["completion", "-s", "bash"][..],
        &["alias", "list"][..],
    ] {
        assert_eq!(
            gh_auto_route(&strings(args), &cx(false, false, None), &in_checkout),
            GhRoute::Direct,
            "{args:?}"
        );
    }
}

#[test]
fn auto_without_a_repo_runs_gh_without_a_token_and_says_why() {
    let route = gh_auto_route(&strings(&["pr", "list"]), &cx(false, false, None), &nowhere);
    let GhRoute::Untokened { note } = route else { panic!("{route:?}") };
    assert!(note.contains("-R owner/name"), "{note}");
    // A URL to another host never gets this machine's token.
    let route = gh_auto_route(
        &strings(&["api", "https://evil.example/x"]),
        &cx(false, false, None),
        &in_checkout,
    );
    assert!(matches!(route, GhRoute::Untokened { .. }), "{route:?}");
}

#[test]
fn auto_reads_ask_for_read_only() {
    for args in [
        &["pr", "list"][..],
        &["pr", "view", "12"][..],
        &["pr", "checks"][..],
        &["pr", "diff", "3"][..],
        &["run", "watch", "9"][..],
        &["run", "download", "9"][..],
        &["repo", "view"][..],
        &["issue", "list", "--json", "number"][..],
        &["status"][..],
        &["search", "prs", "x"][..],
        &["api", "repos/{owner}/{repo}/pulls"][..],
        &["api", "--method", "GET", "x"][..],
        &["api", "-XGET", "x"][..],
    ] {
        let route = gh_auto_route(&strings(args), &cx(false, false, None), &in_checkout);
        assert_eq!(asked(&route), ["read"], "{args:?}");
    }
}

#[test]
fn auto_writes_ask_for_write_then_read() {
    for args in [
        &["pr", "create", "--fill"][..],
        &["pr", "merge", "1"][..],
        &["issue", "comment", "1", "-b", "hi"][..],
        &["release", "create", "v1"][..],
        &["api", "-X", "POST", "x"][..],
        &["api", "--method=PATCH", "x"][..],
        &["api", "x", "-f", "title=t"][..],
        &["api", "x", "-Fdraft=true"][..],
        &["api", "x", "--input", "body.json"][..],
        &["workflow", "run", "ci.yml"][..],
    ] {
        let route = gh_auto_route(&strings(args), &cx(false, false, None), &in_checkout);
        assert_eq!(asked(&route), ["write", "read"], "{args:?}");
    }
}

#[test]
fn auto_takes_the_repo_from_r_then_gh_repo_then_origin_and_keeps_args() {
    let args = strings(&["-R", "a/b", "issue", "view", "5"]);
    let route = gh_auto_route(&args, &cx(false, false, Some("c/d")), &in_checkout);
    let GhRoute::Token { repo, args: kept, asks } = &route else { panic!("{route:?}") };
    assert_eq!(repo, "a/b");
    assert_eq!(kept, &args);
    assert_eq!(asked(&route), ["read"]);
    assert!(asks.iter().all(|a| a.repo == "a/b" && a.label.as_deref() == Some("gh")));
    let route =
        gh_auto_route(&strings(&["pr", "list"]), &cx(false, false, Some("c/d")), &in_checkout);
    assert!(matches!(&route, GhRoute::Token { repo, .. } if repo == "c/d"), "{route:?}");
    let route = gh_auto_route(&strings(&["pr", "list"]), &cx(false, false, None), &in_checkout);
    assert!(matches!(&route, GhRoute::Token { repo, .. } if repo == "o/r"), "{route:?}");
}

#[test]
fn first_token_falls_back_on_policy_only() {
    let asks = vec![gh_ask("o/r", true), gh_ask("o/r", false)];
    let mut seen = Vec::new();
    let got = first_token(&asks, &mut |a| {
        seen.push(a.permissions["contents"].as_str().unwrap().to_owned());
        if a.permissions["contents"] == "write" {
            Err(refused("policy.denied", "no write"))
        } else {
            Ok(minted())
        }
    });
    assert_eq!(got.unwrap().token, SECRET);
    assert_eq!(seen, ["write", "read"]);
    let mut calls = 0;
    let err = first_token(&asks, &mut |_| {
        calls += 1;
        Err(refused("integration.not_found", "no GitHub connection"))
    })
    .unwrap_err();
    assert_eq!((err.code.as_str(), calls), ("integration.not_found", 1));
}

#[test]
fn own_gh_login_is_a_github_com_entry_in_hosts_yml() {
    assert!(hosts_has_github("github.com:\n    oauth_token: gho_x\n    user: me\n"));
    assert!(hosts_has_github("ghe.example.com:\n  user: a\ngithub.com:\n  user: b\n"));
    assert!(!hosts_has_github(""));
    assert!(!hosts_has_github("ghe.example.com:\n  user: a\n"));
    assert!(!hosts_has_github("x:\n  github.com: 1\n"));
    let dir = tempfile::tempdir().unwrap();
    let home = dir.path();
    assert_eq!(gh_hosts_path(None, None, Some(home)), Some(home.join(".config/gh/hosts.yml")));
    assert_eq!(
        gh_hosts_path(None, Some(Path::new("/x")), Some(home)),
        Some(PathBuf::from("/x/gh/hosts.yml"))
    );
    assert_eq!(
        gh_hosts_path(Some(Path::new("/g")), Some(Path::new("/x")), Some(home)),
        Some(PathBuf::from("/g/hosts.yml"))
    );
    assert_eq!(gh_hosts_path(None, None, None), None);
}

#[test]
fn own_gh_login_reads_an_indented_or_inline_github_com_entry() {
    // cmux#35095: an indented root mapping, a tab-indented one, or an inline
    // (flow) mapping is still a github.com login gh reads.
    for hosts in [
        "  github.com:\n      oauth_token: gho_x\n      user: me\n",
        "\tgithub.com:\n\t\tuser: me\n",
        "{github.com: {user: me, oauth_token: gho_x}}\n",
        "{\"ghe.example.com\": {user: a}, github.com: {user: b}}\n",
        "{ # comment\n  github.com: {user: me}\n}\n",
        "{ghe.example.com: {user: a}, # work\n github.com: {user: b}} # end\n",
        "github.com: {user: me, oauth_token: gho_x}\n",
        "github.com: # personal\n    user: me\n",
        "---\n\"github.com\":\n  user: me\n",
        "'GitHub.com':\n  user: me\n",
        // Escaped, tagged and anchored keys are decoded by the YAML parser.
        "\"\\u0067ithub.com\":\n  user: me\n",
        "{\"\\u0067ithub.com\": {user: me}}\n",
        "!!str github.com:\n  user: me\n",
        "{&a github.com: {user: me}}\n",
        // Not valid YAML (`,#` is no comment): unread, so the person's own.
        "{ghe.example.com: {oauth_token: x,# Alice's account\n user: a},\ngithub.com:\n {oauth_token: y, # Bob's account\n user: b}}\n",
        "{ghe.example.com: {user: it's me}, github.com: {user: b}}\n",
    ] {
        assert!(hosts_has_github(hosts), "{hosts:?}");
    }
    // A login for another host only, or github.com as a nested key, is not one.
    for hosts in [
        "  ghe.example.com:\n      user: a\n",
        "{ghe.example.com: {user: a, note: github.com}}\n",
        "{ghe.example.com: {github.com: 1}}\n",
        "{mygithub.com: {user: a}}\n",
        "mygithub.com:\n  user: a\n",
        "# a comment\n  # another\n---\n",
        "{ghe.example.com: {user: a, note: \"github.com: x\"}}\n",
        "  x:\n      github.com: 1\n",
        "{}\n",
        "# github.com:\n",
        // cmux#35263: a quoted key with spaces is another host, not github.com.
        "\" github.com \":\n  user: me\n",
        "\"github.com \":\n  user: me\n",
        "{\" github.com\": {user: me}}\n",
    ] {
        assert!(!hosts_has_github(hosts), "{hosts:?}");
    }
}
