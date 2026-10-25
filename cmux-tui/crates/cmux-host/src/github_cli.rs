//! `cmux github …` on a cmux Cloud machine: git and `gh` with short-lived,
//! repo-scoped GitHub tokens and no login on the machine.
//!
//! - `credential get|store|erase`: a git credential helper. `get` asks the
//!   machine's Cloud agent (its socket, `cloud/github.rs`) for a token for
//!   the repo git names and answers `username=x-access-token` and
//!   `password=<token>`; `store` and `erase` do nothing (no helper keeps
//!   it, so the token lives as long as the git process).
//! - `gh [--write] ARGS…`: runs `gh` with `GH_TOKEN` set for that one
//!   process, for the repo named by `-R/--repo`, else `GH_REPO`, else the
//!   current checkout's `origin`.
//! - `setup [--unset]`: opt-in wiring of the user's git config (the helper
//!   for https://github.com, with `useHttpPath` so git names the repo).
//!
//! The token lives only in this process and the git or gh process it
//! answers. Nothing here writes it to disk or prints it anywhere but the
//! credential protocol's stdout.
//!
//! Git does not tell a helper whether it fetches or pushes, so `get` asks
//! for `contents: write` first and, when the team's policy refuses that
//! (`policy.denied`), for `contents: read`. The API's policy is the limit.
//! `CMUX_GITHUB_WORKFLOWS=1` adds `workflows: write` to the first ask, for
//! pushes that change `.github/workflows`.

use std::io::{BufRead, BufReader, Read, Write};
use std::os::unix::net::UnixStream;
use std::path::{Path, PathBuf};
use std::time::Duration;

use serde_json::{Map, Value, json};

use crate::cloud::github::{TokenAsk, valid_repo};
use crate::cloud::wire::AGENT_SOCKET;
use crate::json::JsonField;

const USAGE: &str =
    "usage: cmux github credential get|store|erase | gh [--write] [--] ARGS... | setup [--unset]";
const HOST_KEY: &str = "credential.https://github.com.helper";
const PATH_KEY: &str = "credential.https://github.com.useHttpPath";
/// The agent mints with one API call (bounded by 20 s) and maybe a bearer
/// refresh (two more).
const ASK_TIMEOUT: Duration = Duration::from_secs(70);

/// A minted token, held in memory only.
pub struct Minted {
    pub token: String,
    pub expires_at: String,
}

impl std::fmt::Debug for Minted {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("Minted")
            .field("token", &"<redacted>")
            .field("expires_at", &self.expires_at)
            .finish()
    }
}

/// A refusal from the agent or the API.
#[derive(Debug, PartialEq, Eq)]
pub struct Refused {
    pub code: String,
    pub message: String,
}

impl std::fmt::Display for Refused {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        if self.message.is_empty() {
            write!(f, "{}", self.code)
        } else {
            write!(f, "{}: {}", self.code, self.message)
        }
    }
}

fn refused(code: &str, message: impl Into<String>) -> Refused {
    Refused { code: code.to_owned(), message: message.into() }
}

/// One ask over the agent socket: write the line, read the one reply.
pub fn ask_agent(socket: &Path, ask: &TokenAsk) -> Result<Minted, Refused> {
    let mut stream = UnixStream::connect(socket).map_err(|e| {
        refused(
            "vm.agent_unreachable",
            format!("{} ({e}); `cmux github` works on a cmux Cloud machine", socket.display()),
        )
    })?;
    let io = |e: std::io::Error| refused("vm.agent_unreachable", e.to_string());
    stream.set_read_timeout(Some(ASK_TIMEOUT)).map_err(io)?;
    stream.set_write_timeout(Some(Duration::from_secs(5))).map_err(io)?;
    stream.write_all(format!("{}\n", ask.to_line()).as_bytes()).map_err(io)?;
    let mut line = String::new();
    BufReader::new(stream.take(64 * 1024)).read_line(&mut line).map_err(io)?;
    let reply: Value = serde_json::from_str(&line).map_err(|_| {
        refused("vm.agent_bad_answer", "the Cloud agent's answer is not JSON (an older image?)")
    })?;
    if *reply.field("ok") == true {
        let token = reply.field("token").as_str().unwrap_or("");
        let expires_at = reply.field("expires_at").as_str().unwrap_or("");
        if token.is_empty() {
            return Err(refused("vm.agent_bad_answer", "no token in the answer"));
        }
        return Ok(Minted { token: token.to_owned(), expires_at: expires_at.to_owned() });
    }
    let error = reply.field("error");
    Err(refused(
        error.field("code").as_str().unwrap_or("vm.agent_bad_answer"),
        error.field("message").as_str().unwrap_or(""),
    ))
}

fn perms(pairs: &[(&str, &str)]) -> Map<String, Value> {
    pairs.iter().map(|(k, v)| ((*k).to_owned(), json!(v))).collect()
}

/// The asks `credential get` tries in order; each next one only after a
/// `policy.denied`.
pub fn credential_asks(repo: &str, workflows: bool) -> Vec<TokenAsk> {
    let ask = |pairs: &[(&str, &str)]| TokenAsk {
        repo: repo.to_owned(),
        permissions: perms(pairs),
        label: Some("git-credential".to_owned()),
    };
    let mut asks = Vec::new();
    if workflows {
        asks.push(ask(&[("contents", "write"), ("workflows", "write")]));
    }
    asks.push(ask(&[("contents", "write")]));
    asks.push(ask(&[("contents", "read")]));
    asks
}

/// The `gh` permission set: reads, or (`--write`) contents, pull requests
/// and issues write.
pub fn gh_ask(repo: &str, write: bool) -> TokenAsk {
    let level = if write { "write" } else { "read" };
    TokenAsk {
        repo: repo.to_owned(),
        permissions: perms(&[
            ("contents", level),
            ("pull_requests", level),
            ("issues", level),
            ("checks", "read"),
            ("actions", "read"),
            ("statuses", "read"),
            ("metadata", "read"),
        ]),
        label: Some("gh".to_owned()),
    }
}

/// git's credential description (`key=value` lines up to a blank line).
pub fn parse_credential_input(input: &str) -> Map<String, Value> {
    let mut out = Map::new();
    for line in input.lines() {
        if line.is_empty() {
            break;
        }
        if let Some((k, v)) = line.split_once('=') {
            out.insert(k.to_owned(), json!(v));
        }
    }
    out
}

/// `owner/name` from a GitHub path, URL or `HOST/owner/name`; `None` for
/// anything that is not github.com.
pub fn repo_from(raw: &str) -> Option<String> {
    let mut s = raw.trim();
    for prefix in ["https://", "http://", "ssh://", "git+ssh://"] {
        if let Some(rest) = s.strip_prefix(prefix) {
            s = rest;
            // user@ and :port before the host.
            s = s.split_once('@').map_or(s, |(_, rest)| rest);
            s = s.strip_prefix("github.com")?;
            s = s.strip_prefix(":443").unwrap_or(s);
            s = s.strip_prefix('/')?;
            break;
        }
    }
    if let Some(rest) = s.strip_prefix("git@github.com:") {
        s = rest;
    }
    s = s.strip_prefix("github.com/").unwrap_or(s);
    // git LFS asks for `owner/name.git/info/lfs`.
    let s = s.split_once(".git/").map_or(s, |(repo, _)| repo);
    let s = s.trim_matches('/');
    let s = s.strip_suffix(".git").unwrap_or(s);
    valid_repo(s).then(|| s.to_owned())
}

/// `credential get`: the lines for git's stdout (empty when this helper
/// has no answer, so git tries its next helper) and a note for stderr.
pub fn credential_get(
    input: &str,
    workflows: bool,
    ask: &mut dyn FnMut(&TokenAsk) -> Result<Minted, Refused>,
) -> (String, Option<String>) {
    let desc = parse_credential_input(input);
    let field = |k: &str| desc.get(k).and_then(Value::as_str).unwrap_or("");
    if field("protocol") != "https" || field("host") != "github.com" {
        return (String::new(), None);
    }
    let path = field("path");
    if path.is_empty() {
        return (
            String::new(),
            Some(format!("git sent no repo path; run `cmux github setup` (it sets {PATH_KEY})")),
        );
    }
    let Some(repo) = repo_from(path) else {
        return (String::new(), Some(format!("{path:?} is not an owner/name GitHub repo")));
    };
    let mut last = None;
    for each in credential_asks(&repo, workflows) {
        match ask(&each) {
            Ok(minted) => {
                return (format!("username=x-access-token\npassword={}\n", minted.token), None);
            }
            Err(e) if e.code == "policy.denied" => last = Some(e),
            Err(e) => return (String::new(), Some(format!("{repo}: {e}"))),
        }
    }
    (String::new(), last.map(|e| format!("{repo}: {e}")))
}

/// What `gh` runs with: the repo, whether to ask for write, and gh's own
/// arguments (cmux's `--write` and a leading `--` taken out).
#[derive(Debug, PartialEq, Eq)]
pub struct GhPlan {
    pub repo: String,
    pub write: bool,
    pub args: Vec<String>,
}

pub fn gh_plan(
    args: &[String],
    gh_repo_env: Option<&str>,
    origin: &dyn Fn() -> Option<String>,
) -> Result<GhPlan, String> {
    let mut rest = args;
    let mut write = false;
    if let Some((first, after)) = rest.split_first()
        && first == "--write"
    {
        write = true;
        rest = after;
    }
    if let Some((first, after)) = rest.split_first()
        && first == "--"
    {
        rest = after;
    }
    let mut named = None;
    let mut it = rest.iter();
    while let Some(arg) = it.next() {
        if arg == "--" {
            break;
        }
        if arg == "-R" || arg == "--repo" {
            named = it.next().cloned();
        } else if let Some(v) = arg.strip_prefix("--repo=") {
            named = Some(v.to_owned());
        } else if let Some(v) = arg.strip_prefix("-R").filter(|v| !v.is_empty()) {
            named = Some(v.to_owned());
        }
    }
    let (raw, from) = match (named, gh_repo_env.filter(|v| !v.is_empty())) {
        (Some(named), _) => (named, "-R/--repo"),
        (None, Some(env)) => (env.to_owned(), "GH_REPO"),
        (None, None) => match origin() {
            Some(url) => (url, "the origin remote"),
            None => {
                return Err(
                    "no repo: pass -R owner/name, set GH_REPO, or run in a GitHub checkout"
                        .to_owned(),
                );
            }
        },
    };
    let repo = repo_from(&raw)
        .ok_or_else(|| format!("{from} {raw:?} is not a github.com owner/name repo"))?;
    Ok(GhPlan { repo, write, args: rest.to_vec() })
}

fn origin_url() -> Option<String> {
    let out =
        std::process::Command::new("git").args(["remote", "get-url", "origin"]).output().ok()?;
    out.status.success().then(|| String::from_utf8_lossy(&out.stdout).trim().to_owned())
}

/// The helper value `setup` writes: this binary by absolute path (the name
/// `cmux` selects the verb, so a symlink is kept, not resolved).
pub fn helper_value(program: &Path) -> String {
    let quoted = program.display().to_string().replace('\'', r"'\''");
    format!("!'{quoted}' github credential")
}

/// How to run this binary again as `cmux`: argv[0] made absolute, or found
/// on PATH.
fn self_program() -> Option<PathBuf> {
    let argv0 = PathBuf::from(std::env::args_os().next()?);
    if argv0.components().count() > 1 {
        return Some(if argv0.is_absolute() {
            argv0
        } else {
            std::env::current_dir().ok()?.join(argv0)
        });
    }
    std::env::split_paths(&std::env::var_os("PATH")?)
        .map(|dir| dir.join(&argv0))
        .find(|p| p.is_file())
}

/// The `git config --global` argument lists `setup` (or `--unset`) runs.
pub fn setup_commands(helper: &str, unset: bool) -> Vec<Vec<String>> {
    let cmd = |args: &[&str]| {
        let mut out = vec!["config".to_owned(), "--global".to_owned()];
        out.extend(args.iter().map(|a| (*a).to_owned()));
        out
    };
    if unset {
        return vec![cmd(&["--unset-all", HOST_KEY]), cmd(&["--unset", PATH_KEY])];
    }
    vec![
        // An empty value resets the helper list for github.com (a gh login's
        // `gh auth git-credential` or a store), so only this helper answers.
        cmd(&["--replace-all", HOST_KEY, ""]),
        cmd(&["--add", HOST_KEY, helper]),
        cmd(&[PATH_KEY, "true"]),
    ]
}

fn setup(args: &[String]) -> u8 {
    let unset = match args {
        [] => false,
        [flag] if flag == "--unset" => true,
        _ => return usage("setup takes --unset only"),
    };
    let helper = match self_program() {
        Some(program) => helper_value(&program),
        None => {
            eprintln!("cmux github setup: cannot find this binary's path");
            return 1;
        }
    };
    for args in setup_commands(&helper, unset) {
        let status = std::process::Command::new("git").args(&args).status();
        match status {
            Ok(s) if s.success() => {}
            // `--unset` of a key that is not set exits 5.
            Ok(s) if unset && s.code() == Some(5) => {}
            Ok(s) => {
                eprintln!("cmux github setup: git {} failed ({s})", args.join(" "));
                return 1;
            }
            Err(e) => {
                eprintln!("cmux github setup: git: {e}");
                return 1;
            }
        }
    }
    if unset {
        println!("git no longer asks cmux for GitHub credentials");
    } else {
        println!(
            "git now asks cmux for a short-lived token per GitHub repo; for gh, run `cmux github gh [--write] ARGS...`"
        );
    }
    0
}

fn credential(args: &[String]) -> u8 {
    match args {
        [op] if op == "get" => {}
        // Nothing is kept, so there is nothing to store or erase.
        [op] if op == "store" || op == "erase" => {
            let _ = std::io::copy(&mut std::io::stdin(), &mut std::io::sink());
            return 0;
        }
        _ => return usage("credential takes get, store or erase"),
    }
    let mut input = String::new();
    if std::io::stdin().read_to_string(&mut input).is_err() {
        return 1;
    }
    let workflows = std::env::var("CMUX_GITHUB_WORKFLOWS").is_ok_and(|v| v == "1");
    let socket = Path::new(AGENT_SOCKET);
    let (out, note) = credential_get(&input, workflows, &mut |ask| ask_agent(socket, ask));
    if let Some(note) = note {
        eprintln!("cmux github credential: {note}");
    }
    let _ = std::io::stdout().write_all(out.as_bytes());
    0
}

fn gh(args: &[String]) -> u8 {
    let env_repo = std::env::var("GH_REPO").ok();
    let plan = match gh_plan(args, env_repo.as_deref(), &origin_url) {
        Ok(plan) => plan,
        Err(e) => {
            eprintln!("cmux github gh: {e}");
            return 2;
        }
    };
    let minted = match ask_agent(Path::new(AGENT_SOCKET), &gh_ask(&plan.repo, plan.write)) {
        Ok(minted) => minted,
        Err(e) => {
            eprintln!("cmux github gh: {}: {e}", plan.repo);
            return 1;
        }
    };
    use std::os::unix::process::CommandExt;
    let err = std::process::Command::new("gh")
        .args(&plan.args)
        .env("GH_TOKEN", &minted.token)
        .env_remove("GITHUB_TOKEN")
        .exec();
    eprintln!("cmux github gh: gh: {err}");
    1
}

fn usage(msg: &str) -> u8 {
    eprintln!("cmux github: {msg}\n{USAGE}");
    2
}

/// Entry for `cmux github <args>`.
pub fn run(args: &[String]) -> u8 {
    let Some((verb, rest)) = args.split_first() else { return usage("missing verb") };
    match verb.as_str() {
        "credential" => credential(rest),
        "gh" => gh(rest),
        "setup" => setup(rest),
        "--help" | "-h" | "help" => {
            println!("{USAGE}");
            0
        }
        other => usage(&format!("unknown verb {other}")),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::os::unix::net::UnixListener;

    const SECRET: &str = "ghs_fake_installation_token_0000000000";

    fn strings(v: &[&str]) -> Vec<String> {
        v.iter().map(|s| (*s).to_owned()).collect()
    }

    fn minted() -> Minted {
        Minted { token: SECRET.to_owned(), expires_at: "2026-10-25T02:00:00Z".to_owned() }
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
        for raw in ["https://gitlab.com/a/b", "git@gitlab.com:a/b.git", "a", "a/b/c", "a/..", ""] {
            assert_eq!(repo_from(raw), None, "{raw}");
        }
    }

    #[test]
    fn get_answers_github_https_with_a_write_token_first() {
        let mut asked = Vec::new();
        let (out, note) = credential_get(
            "protocol=https\nhost=github.com\npath=manaflow-ai/cmux.git\n\n",
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
        let (out, _) =
            credential_get("protocol=https\nhost=github.com\npath=o/r\n", true, &mut |ask| {
                asked.push(Value::Object(ask.permissions.clone()));
                if ask.permissions.get("contents") == Some(&json!("read")) {
                    Ok(minted())
                } else {
                    Err(refused("policy.denied", "over the grant"))
                }
            });
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
        let (out, note) =
            credential_get("protocol=https\nhost=github.com\npath=o/r\n", false, &mut |_| {
                calls += 1;
                Err(refused("integration.not_found", "no GitHub connection"))
            });
        assert_eq!(out, "");
        assert_eq!(calls, 1);
        assert_eq!(note.as_deref(), Some("o/r: integration.not_found: no GitHub connection"));
        assert!(!note.unwrap().contains(SECRET));
    }

    #[test]
    fn get_ignores_other_hosts_and_asks_for_a_path() {
        let mut never = |_: &TokenAsk| -> Result<Minted, Refused> { panic!("no ask expected") };
        assert_eq!(
            credential_get("protocol=https\nhost=gitlab.com\npath=o/r\n", false, &mut never),
            (String::new(), None)
        );
        assert_eq!(
            credential_get("protocol=http\nhost=github.com\npath=o/r\n", false, &mut never),
            (String::new(), None)
        );
        let (out, note) = credential_get("protocol=https\nhost=github.com\n", false, &mut never);
        assert_eq!(out, "");
        assert!(note.unwrap().contains("cmux github setup"));
    }

    #[test]
    fn gh_takes_its_repo_from_flags_env_then_origin() {
        let none = || None;
        let origin = || Some("git@github.com:o/from-origin.git".to_owned());
        let plan = gh_plan(&strings(&["--write", "pr", "create", "-R", "o/r"]), Some("x/y"), &none)
            .unwrap();
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
        assert_eq!(gh_plan(&strings(&["pr", "view", "-Ro/r3"]), None, &none).unwrap().repo, "o/r3");
        let env = gh_plan(&strings(&["--", "pr", "list"]), Some("o/env"), &origin).unwrap();
        assert_eq!(
            (env.repo.as_str(), env.write, env.args),
            ("o/env", false, strings(&["pr", "list"]))
        );
        assert_eq!(
            gh_plan(&strings(&["pr", "list"]), None, &origin).unwrap().repo,
            "o/from-origin"
        );
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
    fn setup_writes_only_the_github_helper_and_use_http_path() {
        let helper = helper_value(Path::new("/opt/cmux/current/bin/cmux"));
        assert_eq!(helper, "!'/opt/cmux/current/bin/cmux' github credential");
        assert_eq!(helper_value(Path::new("/a'b/cmux")), r"!'/a'\''b/cmux' github credential");
        let on = setup_commands(&helper, false);
        assert_eq!(on[0], strings(&["config", "--global", "--replace-all", HOST_KEY, ""]));
        assert_eq!(on[1], strings(&["config", "--global", "--add", HOST_KEY, &helper]));
        assert_eq!(on[2], strings(&["config", "--global", PATH_KEY, "true"]));
        let off = setup_commands(&helper, true);
        assert_eq!(
            off,
            vec![
                strings(&["config", "--global", "--unset-all", HOST_KEY]),
                strings(&["config", "--global", "--unset", PATH_KEY])
            ]
        );
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
        assert_eq!(
            ask_agent(&socket, &gh_ask("o/r", false)).unwrap_err().code,
            "vm.agent_bad_answer"
        );
        agent.join().unwrap();
        let missing =
            ask_agent(Path::new("/nonexistent/agent.sock"), &gh_ask("o/r", false)).unwrap_err();
        assert_eq!(missing.code, "vm.agent_unreachable");
    }
}
