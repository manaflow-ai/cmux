//! Agent provenance both ways (manaflow-ai/cmuxterm-hq#2555), through the real
//! `cmux` binary: an agent stamps its commit with `cmux agent link --trailer`,
//! and `cmux agent artifacts` lists that commit back for the session, with the
//! pull request and CI runs `gh` reports for it. Other sessions' commits and
//! commits that only mention the id are not the session's artifacts.
#![cfg(unix)]

use std::fs;
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::process::{Command, Output};
use std::time::{SystemTime, UNIX_EPOCH};

use serde_json::Value;

const SESSION: &str = "0f3c2a91-7d4e-4b8a-9c11-2e5f6a7b8c9d";

fn temp_dir(label: &str) -> PathBuf {
    let stamp = SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_nanos();
    let dir = std::env::temp_dir().join(format!("cxp-{label}-{}-{stamp}", std::process::id()));
    fs::create_dir_all(&dir).unwrap();
    dir
}

/// The binary with a clean agent environment plus `env`; `path` goes first on PATH.
fn cmux(dir: &Path, args: &[&str], env: &[(&str, &str)], path: Option<&Path>) -> Output {
    let mut command = Command::new(env!("CARGO_BIN_EXE_cmux-tui"));
    command.args(args).current_dir(dir).env("HOME", dir).env("LC_ALL", "C");
    for key in [
        "CMUX_AGENT_SESSION_ID",
        "CMUX_AGENT_HARNESS",
        "CMUX_AGENT_HOST",
        "CMUX_AGENT_NAME",
        "CLAUDE_CODE_SESSION_ID",
        "CODEX_THREAD_ID",
        "CODEX_SESSION_ID",
        "OPENCODE_SESSION_ID",
        "AGENT_LEASE_HOLDER",
        "CALLSIGN_SESSION_ID",
        "CALLSIGN_STATE_DIR",
        "XDG_STATE_HOME",
        "CMUX_AGENT_PROVENANCE",
    ] {
        command.env_remove(key);
    }
    command.envs(env.iter().copied());
    if let Some(path) = path {
        let inherited = std::env::var("PATH").unwrap_or_default();
        command.env("PATH", format!("{}:{inherited}", path.display()));
    }
    command.output().unwrap()
}

fn agent_env() -> Vec<(&'static str, &'static str)> {
    vec![
        ("CLAUDE_CODE_SESSION_ID", SESSION),
        ("CMUX_AGENT_HOST", "build-mac"),
        ("CMUX_AGENT_NAME", "Lanternfish"),
    ]
}

fn stdout(output: &Output) -> String {
    assert!(
        output.status.success(),
        "exit {:?}\nstdout: {}\nstderr: {}",
        output.status.code(),
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    );
    String::from_utf8(output.stdout.clone()).unwrap()
}

fn git(repo: &Path, args: &[&str]) -> String {
    let output = Command::new("git")
        .arg("-C")
        .arg(repo)
        .args(args)
        .env("GIT_AUTHOR_NAME", "agent")
        .env("GIT_AUTHOR_EMAIL", "agent@example.com")
        .env("GIT_COMMITTER_NAME", "agent")
        .env("GIT_COMMITTER_EMAIL", "agent@example.com")
        .env("GIT_CONFIG_NOSYSTEM", "1")
        .env("GIT_CONFIG_GLOBAL", "/dev/null")
        .output()
        .unwrap();
    assert!(output.status.success(), "git {args:?}: {}", String::from_utf8_lossy(&output.stderr));
    String::from_utf8(output.stdout).unwrap().trim().to_owned()
}

fn commit(repo: &Path, file: &str, subject: &str, body: Option<&str>) -> String {
    fs::write(repo.join(file), subject).unwrap();
    git(repo, &["add", file]);
    let mut args = vec!["commit", "-q", "-m", subject];
    if let Some(body) = body {
        args.extend(["-m", body]);
    }
    git(repo, &args);
    git(repo, &["rev-parse", "HEAD"])
}

#[test]
fn provenance_link_prints_the_session_address_in_every_form() {
    let dir = temp_dir("link");
    let native = stdout(&cmux(&dir, &["agent", "link"], &agent_env(), None));
    assert_eq!(
        native.trim(),
        format!("cmux://agent/claude/{SESSION}?host=build-mac&name=Lanternfish")
    );
    let web = format!(
        "https://cmux.com/deeplink/agent?harness=claude&session={SESSION}&host=build-mac&name=Lanternfish"
    );
    assert_eq!(stdout(&cmux(&dir, &["agent", "link", "--web"], &agent_env(), None)).trim(), web);
    assert_eq!(
        stdout(&cmux(&dir, &["agent", "link", "--trailer"], &agent_env(), None)).trim(),
        format!("Agent-Session: {web}")
    );
    assert_eq!(
        stdout(&cmux(&dir, &["agent", "link", "--footer"], &agent_env(), None)).trim(),
        format!("Agent session: [Lanternfish on build-mac]({web})")
    );

    let json: Value = serde_json::from_str(&stdout(&cmux(
        &dir,
        &["--json", "agent", "link"],
        &agent_env(),
        None,
    )))
    .unwrap();
    assert_eq!(json["harness"], "claude");
    assert_eq!(json["session"], SESSION);
    assert!(json.get("account").is_none() && json.get("cwd").is_none(), "{json}");

    // Provenance turned off: no trailer or PR line to stamp.
    let mut off = agent_env();
    off.push(("CMUX_AGENT_PROVENANCE", "0"));
    for form in ["--trailer", "--footer"] {
        assert_eq!(
            cmux(&dir, &["agent", "link", form], &off, None).status.code(),
            Some(1),
            "{form}"
        );
    }
    let help = stdout(&cmux(&dir, &["agent", "link", "--help"], &agent_env(), None));
    assert!(help.contains("agent link"), "{help}");
    // A session id the link grammar refuses is no session.
    let bad = [("CMUX_AGENT_SESSION_ID", "not a session!")];
    assert_eq!(cmux(&dir, &["agent", "link"], &bad, None).status.code(), Some(1));
    assert_eq!(cmux(&dir, &["agent", "artifacts"], &bad, None).status.code(), Some(1));

    let outside = cmux(&dir, &["agent", "link"], &[], None);
    assert_eq!(outside.status.code(), Some(1));
    assert!(String::from_utf8_lossy(&outside.stderr).contains("no agent session"));
    let _ = fs::remove_dir_all(dir);
}

#[test]
fn provenance_artifacts_lists_the_sessions_commits_prs_and_runs() {
    let dir = temp_dir("artifacts");
    let repo = dir.join("repo");
    fs::create_dir_all(&repo).unwrap();
    git(&repo, &["init", "-q", "-b", "main"]);

    // The agent stamps its commit with the trailer the CLI prints.
    let trailer = stdout(&cmux(&dir, &["agent", "link", "--trailer"], &agent_env(), None));
    let mine = commit(&repo, "a.txt", "agent work", Some(trailer.trim()));
    // Another session's commit, one that only mentions the id, and a branch commit of ours.
    commit(
        &repo,
        "b.txt",
        "codex work",
        Some(&format!(
            "Agent-Session: https://cmux.com/deeplink/agent?harness=codex&session={SESSION}&host=x"
        )),
    );
    commit(&repo, "c.txt", &format!("mentions {SESSION}"), None);
    git(&repo, &["checkout", "-q", "-b", "side"]);
    let branch = commit(
        &repo,
        "d.txt",
        "agent branch work",
        Some(&format!("Refs: x\nAgent-Session: cmux://agent/claude/{SESSION}?host=build-mac")),
    );
    git(&repo, &["checkout", "-q", "main"]);

    let repo_arg = repo.to_str().unwrap();
    let listed: Value = serde_json::from_str(&stdout(&cmux(
        &dir,
        &["--json", "agent", "artifacts", "--repo", repo_arg],
        &agent_env(),
        None,
    )))
    .unwrap();
    let shas: Vec<&str> =
        listed["commits"].as_array().unwrap().iter().map(|c| c["sha"].as_str().unwrap()).collect();
    assert_eq!(shas.len(), 2, "{listed}");
    assert!(shas.contains(&mine.as_str()) && shas.contains(&branch.as_str()), "{listed}");
    assert_eq!(listed["link"], format!("cmux://agent/claude/{SESSION}"));

    // Another session's view: by its address, from outside any agent session.
    let codex: Value = serde_json::from_str(&stdout(&cmux(
        &dir,
        &["--json", "agent", "artifacts", &format!("codex/{SESSION}"), "--repo", repo_arg],
        &[],
        None,
    )))
    .unwrap();
    assert_eq!(codex["commits"].as_array().unwrap().len(), 1, "{codex}");
    assert_eq!(codex["commits"][0]["subject"], "codex work");

    // --github: `gh` answers which PR holds each commit and its CI runs.
    let bin = dir.join("bin");
    fs::create_dir_all(&bin).unwrap();
    let gh = bin.join("gh");
    fs::write(
        &gh,
        format!(
            "#!/bin/sh\n\
             case \"$1 $2\" in\n\
             \"api repos/{{owner}}/{{repo}}/commits/{mine}/pulls\") echo '[{{\"number\":42,\"html_url\":\"https://github.com/o/r/pull/42\",\"state\":\"open\",\"title\":\"Agent work\",\"merged_at\":null}}]' ;;\n\
             \"api \"*) echo '[{{\"number\":42,\"html_url\":\"https://github.com/o/r/pull/42\",\"state\":\"open\",\"title\":\"Agent work\",\"merged_at\":null}}]' ;;\n\
             \"run list\") [ \"$4\" = \"{mine}\" ] && echo '[{{\"databaseId\":7,\"name\":\"ci\",\"url\":\"https://github.com/o/r/actions/runs/7\",\"status\":\"completed\",\"conclusion\":\"success\"}}]' || echo '[]' ;;\n\
             *) echo \"unexpected gh $*\" >&2; exit 9 ;;\n\
             esac\n"
        ),
    )
    .unwrap();
    fs::set_permissions(&gh, fs::Permissions::from_mode(0o755)).unwrap();
    let full: Value = serde_json::from_str(&stdout(&cmux(
        &dir,
        &["--json", "agent", "artifacts", "--repo", repo_arg, "--github"],
        &agent_env(),
        Some(&bin),
    )))
    .unwrap();
    assert_eq!(full["pull_requests"].as_array().unwrap().len(), 1, "the PR is listed once: {full}");
    assert_eq!(full["pull_requests"][0]["url"], "https://github.com/o/r/pull/42");
    let runs = full["runs"].as_array().unwrap();
    assert_eq!(runs.len(), 1, "{full}");
    assert_eq!(runs[0]["url"], "https://github.com/o/r/actions/runs/7");
    assert_eq!(runs[0]["sha"], mine.as_str());

    let human = stdout(&cmux(
        &dir,
        &["agent", "artifacts", "--repo", repo_arg, "--github"],
        &agent_env(),
        Some(&bin),
    ));
    assert!(
        human.contains("commits (2)") && human.contains("#42") && human.contains("runs/7"),
        "{human}"
    );
    let _ = fs::remove_dir_all(dir);
}

/// The agent's name comes from the live callsign lease, as in
/// tools/remote-agents/agent_identity.py: `CMUX_AGENT_NAME`, else the lease
/// `callsign start` keeps for the session, else the lane of `AGENT_LEASE_HOLDER`.
/// A pending or expired lease doesn't count.
#[test]
fn provenance_link_names_the_agent_by_its_live_callsign_lease() {
    let dir = temp_dir("callsign");
    let state = dir.join(".local/state/callsign");
    fs::create_dir_all(&state).unwrap();
    let lease = state.join("session-0f3c2a91_7d4e_4b8a_9c11_2e5f6a7b8c9d.json");
    let env = [
        ("CLAUDE_CODE_SESSION_ID", SESSION),
        ("CMUX_AGENT_HOST", "build-mac"),
        ("AGENT_LEASE_HOLDER", "lane-7@build-mac"),
    ];
    let link =
        |env: &[(&str, &str)]| stdout(&cmux(&dir, &["agent", "link"], env, None)).trim().to_owned();
    let named = |name: &str| format!("cmux://agent/claude/{SESSION}?host=build-mac&name={name}");

    fs::write(
        &lease,
        r#"{"callsign":"Heron","expiresAt":"2999-01-01T00:00:00.000Z","generation":3}"#,
    )
    .unwrap();
    assert_eq!(link(&env), named("Heron"));
    // CALLSIGN_SESSION_ID keys the lease when set.
    let mut keyed = env.to_vec();
    keyed.push(("CALLSIGN_SESSION_ID", "Other Session"));
    fs::write(
        state.join("session-other_session.json"),
        r#"{"callsign":"Wren","expiresAt":"2999-01-01T00:00:00Z"}"#,
    )
    .unwrap();
    assert_eq!(link(&keyed), named("Wren"));
    // CMUX_AGENT_NAME wins over the lease.
    let mut explicit = env.to_vec();
    explicit.push(("CMUX_AGENT_NAME", "Lanternfish"));
    assert_eq!(link(&explicit), named("Lanternfish"));
    // Pending and expired leases fall back to the lease holder's lane.
    fs::write(&lease, r#"{"callsign":"Heron","pending":true,"expiresAt":"2999-01-01T00:00:00Z"}"#)
        .unwrap();
    assert_eq!(link(&env), named("lane-7"));
    fs::write(&lease, r#"{"callsign":"Heron","expiresAt":"2001-01-01T00:00:00+00:00"}"#).unwrap();
    assert_eq!(link(&env), named("lane-7"));
    let _ = fs::remove_dir_all(dir);
}

/// `--github` still lists the session's commits when `gh` can't answer for
/// some of them (an unpushed commit: GitHub answers 422), naming each failure.
#[test]
fn provenance_artifacts_github_keeps_the_commits_when_gh_fails_for_one() {
    let dir = temp_dir("gh-partial");
    let repo = dir.join("repo");
    fs::create_dir_all(&repo).unwrap();
    git(&repo, &["init", "-q", "-b", "main"]);
    let trailer = stdout(&cmux(&dir, &["agent", "link", "--trailer"], &agent_env(), None));
    let pushed = commit(&repo, "a.txt", "pushed work", Some(trailer.trim()));
    let local = commit(&repo, "b.txt", "local work", Some(trailer.trim()));
    let bin = dir.join("bin");
    fs::create_dir_all(&bin).unwrap();
    let gh = bin.join("gh");
    fs::write(
        &gh,
        format!(
            "#!/bin/sh\n\
             case \"$*\" in\n\
             *{local}*) echo 'gh: No commit found for SHA: {local} (HTTP 422)' >&2; exit 1 ;;\n\
             \"api \"*) echo '[{{\"number\":5,\"html_url\":\"https://github.com/o/r/pull/5\",\"state\":\"open\",\"title\":\"t\",\"merged_at\":null}}]' ;;\n\
             \"run list\"*) echo '[]' ;;\n\
             *) echo '[]' ;;\n\
             esac\n"
        ),
    )
    .unwrap();
    fs::set_permissions(&gh, fs::Permissions::from_mode(0o755)).unwrap();
    let repo_arg = repo.to_str().unwrap();
    let full: Value = serde_json::from_str(&stdout(&cmux(
        &dir,
        &["--json", "agent", "artifacts", "--repo", repo_arg, "--github"],
        &agent_env(),
        Some(&bin),
    )))
    .unwrap();
    assert_eq!(full["commits"].as_array().unwrap().len(), 2, "{full}");
    assert_eq!(full["pull_requests"][0]["number"], 5, "{full}");
    let errors = full["github_errors"].as_array().unwrap();
    assert_eq!(errors.len(), 1, "{full}");
    assert_eq!(errors[0]["sha"], local.as_str());
    assert!(errors.iter().all(|error| error["sha"] != pushed.as_str()), "{full}");
    let _ = fs::remove_dir_all(dir);
}
