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
//! Git does not tell a helper whether it fetches or pushes, so `get` reads
//! the nearest `git` ancestor's command line (Linux `/proc`): `push` asks
//! for `contents: write`, `fetch`/`clone`/`pull`/`ls-remote` for
//! `contents: read`. Any other operation asks for write first and, when
//! the team's policy refuses it (`policy.denied`), for read. The API's
//! policy is the limit.
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
/// The agent answers within this: an ask that waited 60 s in its queue is
/// answered `busy` (`github_minter::MAX_QUEUE_WAIT`), and one mint is at
/// most three 20 s API calls, twice with a bearer retry (120 s).
const ASK_TIMEOUT: Duration = Duration::from_secs(240);

/// A minted token, held in memory only (Debug redacts it).
pub struct Minted {
    pub token: String,
}

impl std::fmt::Debug for Minted {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str("Minted(<redacted>)")
    }
}

/// A refusal from the agent or the API.
#[derive(Debug, PartialEq, Eq)]
pub struct Refused {
    pub code: String,
    pub message: String,
    /// Seconds, from a `rate_limited` answer.
    pub retry_after: Option<u64>,
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
    Refused { code: code.to_owned(), message: message.into(), retry_after: None }
}

/// How long to wait before the one retry of a retryable refusal:
/// `integration.unavailable` (the API could not check the team, SSO or
/// install) and `busy` after 1 s, `rate_limited` after its `retry_after`
/// when that is at most 10 s.
pub fn retry_delay(e: &Refused) -> Option<Duration> {
    match e.code.as_str() {
        "integration.unavailable" | "busy" => Some(Duration::from_secs(1)),
        "rate_limited" => e.retry_after.filter(|s| *s <= 10).map(Duration::from_secs),
        _ => None,
    }
}

/// [`ask_agent`], retried once after a retryable refusal.
fn ask_retrying(socket: &Path, ask: &TokenAsk) -> Result<Minted, Refused> {
    match ask_agent(socket, ask) {
        Err(e) => match retry_delay(&e) {
            Some(delay) => {
                std::thread::sleep(delay);
                ask_agent(socket, ask)
            }
            None => Err(e),
        },
        ok => ok,
    }
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
        if token.is_empty() {
            return Err(refused("vm.agent_bad_answer", "no token in the answer"));
        }
        return Ok(Minted { token: token.to_owned() });
    }
    let error = reply.field("error");
    let mut e = refused(
        error.field("code").as_str().unwrap_or("vm.agent_bad_answer"),
        error.field("message").as_str().unwrap_or(""),
    );
    e.retry_after = reply.field("retry_after").as_u64();
    Err(e)
}

fn perms(pairs: &[(&str, &str)]) -> Map<String, Value> {
    pairs.iter().map(|(k, v)| ((*k).to_owned(), json!(v))).collect()
}

/// What the git process this helper answers is doing, from its command
/// line: git does not tell a credential helper.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum GitOp {
    Push,
    Read,
    Unknown,
}

/// The operation of one ancestor's argv, or `None` when it is not `git`
/// (the shell or `git-remote-https` between git and this helper).
pub fn git_op_of(argv: &[String]) -> Option<GitOp> {
    let (program, rest) = argv.split_first()?;
    let name = Path::new(program).file_name()?;
    if name == "git-lfs" {
        return Some(lfs_op(rest.iter().find(|a| !a.starts_with('-'))));
    }
    if name != "git" {
        return None;
    }
    let mut it = rest.iter();
    while let Some(arg) = it.next() {
        match arg.as_str() {
            // Global options that take the next word.
            "-C" | "-c" | "--git-dir" | "--work-tree" | "--namespace" | "--exec-path"
            | "--config-env" => {
                it.next();
            }
            a if a.starts_with('-') => {}
            // `git remote-https …` is the transport between git and this helper.
            // `git credential fill` is git-lfs asking: its caller decides.
            a if a.starts_with("remote-") || a == "credential" => return None,
            "lfs" => return Some(lfs_op(it.find(|a| !a.starts_with('-')))),
            "push" | "send-pack" => return Some(GitOp::Push),
            "fetch" | "clone" | "pull" | "ls-remote" | "fetch-pack" | "submodule" | "remote" => {
                return Some(GitOp::Read);
            }
            _ => return Some(GitOp::Unknown),
        }
    }
    Some(GitOp::Unknown)
}

/// A git-lfs subcommand's operation: uploads (`pre-push`, `push`) write,
/// downloads read.
fn lfs_op(sub: Option<&String>) -> GitOp {
    match sub.map(String::as_str) {
        Some("pre-push" | "push") => GitOp::Push,
        Some(
            "fetch" | "pull" | "smudge" | "filter-process" | "checkout" | "clone" | "post-checkout"
            | "post-merge",
        ) => GitOp::Read,
        _ => GitOp::Unknown,
    }
}

/// The nearest `git` ancestor's operation (Linux `/proc`; up to 8 levels).
fn git_op() -> GitOp {
    let mut pid = std::os::unix::process::parent_id();
    for _ in 0..8 {
        let Ok(raw) = std::fs::read(format!("/proc/{pid}/cmdline")) else { break };
        let argv: Vec<String> = raw
            .split(|b| *b == 0)
            .filter(|w| !w.is_empty())
            .map(|w| String::from_utf8_lossy(w).into_owned())
            .collect();
        if let Some(op) = git_op_of(&argv) {
            return op;
        }
        // `pid (comm) state ppid ...`; comm may hold spaces and parens.
        let Ok(stat) = std::fs::read_to_string(format!("/proc/{pid}/stat")) else { break };
        let after = stat.rsplit_once(')').map_or("", |(_, rest)| rest);
        let Some(Ok(ppid)) = after.split_whitespace().nth(1).map(str::parse::<u32>) else { break };
        if ppid <= 1 {
            break;
        }
        pid = ppid;
    }
    GitOp::Unknown
}

/// The asks `credential get` tries in order, each next one only after a
/// `policy.denied`: a fetch asks for read, a push for write (with
/// `workflows` when set), and an unknown operation for write, then read.
pub fn credential_asks(repo: &str, op: GitOp, workflows: bool) -> Vec<TokenAsk> {
    let ask = |pairs: &[(&str, &str)]| TokenAsk {
        repo: repo.to_owned(),
        permissions: perms(pairs),
        label: Some("git-credential".to_owned()),
    };
    let mut asks = Vec::new();
    if op != GitOp::Read {
        if workflows {
            asks.push(ask(&[("contents", "write"), ("workflows", "write")]));
        }
        asks.push(ask(&[("contents", "write")]));
    }
    if op != GitOp::Push {
        asks.push(ask(&[("contents", "read")]));
    }
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

/// `github.com`, with any port.
fn github_host(authority: &str) -> bool {
    let host = authority.rsplit_once('@').map_or(authority, |(_, host)| host);
    let name = match host.split_once(':') {
        Some((name, port)) if !port.is_empty() && port.bytes().all(|b| b.is_ascii_digit()) => name,
        Some(_) => return false,
        None => host,
    };
    name.eq_ignore_ascii_case("github.com")
}

/// `owner/name` from a GitHub path, URL or `HOST/owner/name`; `None` for
/// anything that is not github.com.
pub fn repo_from(raw: &str) -> Option<String> {
    let raw = raw.trim();
    let scheme = ["https://", "http://", "ssh://", "git+ssh://"]
        .iter()
        .find_map(|scheme| raw.strip_prefix(scheme));
    let path = if let Some(rest) = scheme {
        let (authority, path) = rest.split_once('/')?;
        if !github_host(authority) {
            return None;
        }
        path
    } else if let Some(path) = raw.strip_prefix("git@github.com:") {
        path
    } else {
        raw.strip_prefix("github.com/").unwrap_or(raw)
    };
    // git LFS asks for `owner/name.git/info/lfs`.
    let path = path.split_once(".git/").map_or(path, |(repo, _)| repo);
    let path = path.trim_matches('/');
    let path = path.strip_suffix(".git").unwrap_or(path);
    valid_repo(path).then(|| path.to_owned())
}

/// `credential get`: the lines for git's stdout (empty when this helper
/// has no answer, so git tries its next helper) and a note for stderr.
pub fn credential_get(
    input: &str,
    op: GitOp,
    workflows: bool,
    ask: &mut dyn FnMut(&TokenAsk) -> Result<Minted, Refused>,
) -> (String, Option<String>) {
    let desc = parse_credential_input(input);
    let field = |k: &str| desc.get(k).and_then(Value::as_str).unwrap_or("");
    if field("protocol") != "https" || !github_host(field("host")) {
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
        return (String::new(), Some("git's path is not an owner/name GitHub repo".to_owned()));
    };
    let mut last = None;
    for each in credential_asks(&repo, op, workflows) {
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
    // `gh api URL`, `gh pr view URL` and the like go where the URL says: an
    // argument that is a URL must be https to GitHub's own hosts.
    if !rest.iter().all(|arg| url_arg_ok(arg)) {
        return Err(
            "the token is for github.com: a URL argument must be https://github.com or its API"
                .to_owned(),
        );
    }
    // `gh repo view HOST/owner/name` goes to HOST (gh sends GH_TOKEN to
    // *.ghe.com too): a repo argument may name github.com only.
    if rest.iter().any(|arg| other_host_repo(arg)) {
        return Err("the token is for github.com: a HOST/owner/name argument must name github.com"
            .to_owned());
    }
    let mut named = None;
    let mut it = rest.iter();
    while let Some(arg) = it.next() {
        if arg == "--" {
            break;
        }
        if arg == "--repo" {
            named = it.next().cloned();
        } else if let Some(cluster) = arg.strip_prefix('-').filter(|c| !c.starts_with('-')) {
            // gh's shorthand forms: `-R o/r`, `-Ro/r`, `-R=o/r`, `-wR o/r`. A
            // value that only looks like one is read as a repo too, so the
            // check below refuses it rather than letting gh pick a host.
            if let Some((_, rest)) = cluster.split_once('R') {
                let rest = rest.strip_prefix('=').unwrap_or(rest);
                named = if rest.is_empty() { it.next().cloned() } else { Some(rest.to_owned()) };
            }
        } else if let Some(v) = arg.strip_prefix("--repo=") {
            named = Some(v.to_owned());
        } else if arg == "--hostname" || arg.starts_with("--hostname=") {
            let host = match arg.strip_prefix("--hostname=") {
                Some(host) => Some(host.to_owned()),
                None => it.next().cloned(),
            };
            if !host.is_some_and(|h| h.eq_ignore_ascii_case("github.com")) {
                return Err("the token is for github.com; --hostname must be github.com".to_owned());
            }
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
    let repo =
        repo_from(&raw).ok_or_else(|| format!("{from} is not a github.com owner/name repo"))?;
    Ok(GhPlan { repo, write, args: rest.to_vec() })
}

/// Whether `arg`, when it is a URL (`scheme://...`), is https to github.com,
/// api.github.com or uploads.github.com. Text with a URL inside (a `--body`
/// value, say) is not a URL argument.
fn url_arg_ok(arg: &str) -> bool {
    let Some((scheme, rest)) = arg.split_once("://") else { return true };
    if !scheme.bytes().all(|b| b.is_ascii_alphanumeric() || b"+.-".contains(&b)) {
        return true;
    }
    let authority = rest.split(['/', '?', '#']).next().unwrap_or("");
    scheme.eq_ignore_ascii_case("https")
        && ["github.com", "api.github.com", "uploads.github.com"]
            .iter()
            .any(|host| authority.eq_ignore_ascii_case(host))
}

/// Whether `arg` may name a host other than github.com for gh: a
/// `HOST/owner/name` whose HOST is anything but `github.com` and looks like
/// a host (a port, a dot that is not a `./..` path step, brackets), or any
/// mention of `.ghe.com`, the tenancy hosts gh also sends GH_TOKEN to.
fn other_host_repo(arg: &str) -> bool {
    let lower = arg.to_ascii_lowercase();
    if lower.contains(".ghe.com") || lower.contains("ghe.com:") {
        return true;
    }
    if arg.contains("://") {
        return false; // a URL: url_arg_ok judges it
    }
    let value = arg.split_once('=').map_or(arg, |(_, v)| v);
    let mut parts = value.split('/');
    let (Some(host), Some(owner), Some(_name)) = (parts.next(), parts.next(), parts.next()) else {
        return false;
    };
    if host.is_empty()
        || owner.is_empty()
        || host == "."
        || host == ".."
        || host.contains(char::is_whitespace)
    {
        return false;
    }
    let hostlike = host.contains([':', '.', '[', ']', '@', '%']);
    hostlike && !host.eq_ignore_ascii_case("github.com")
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
    let cwd = std::env::current_dir().ok()?;
    program_path(&PathBuf::from(std::env::args_os().next()?), std::env::var_os("PATH"), &cwd)
}

/// `argv0` as an absolute path: joined to `cwd` when it names a directory,
/// else the first `PATH` entry holding it as an executable file (a relative
/// entry joined to `cwd`), as a shell finds it. Symlinks are kept: the name
/// `cmux` selects the verb.
pub fn program_path(
    argv0: &Path,
    path_var: Option<std::ffi::OsString>,
    cwd: &Path,
) -> Option<PathBuf> {
    let absolute = |p: PathBuf| if p.is_absolute() { p } else { cwd.join(p) };
    if argv0.components().count() > 1 {
        return Some(absolute(argv0.to_path_buf()));
    }
    std::env::split_paths(&path_var?).map(|dir| absolute(dir.join(argv0))).find(|p| executable(p))
}

fn executable(path: &Path) -> bool {
    use std::os::unix::fs::PermissionsExt;
    std::fs::metadata(path).is_ok_and(|m| m.is_file() && m.permissions().mode() & 0o111 != 0)
}

/// The `git config --global` argument lists `setup` runs for `helper`, or
/// `setup --unset` (`None`: unsetting needs no path to this binary).
pub fn setup_commands(helper: Option<&str>) -> Vec<Vec<String>> {
    let cmd = |args: &[&str]| {
        let mut out = vec!["config".to_owned(), "--global".to_owned()];
        out.extend(args.iter().map(|a| (*a).to_owned()));
        out
    };
    let Some(helper) = helper else {
        return vec![cmd(&["--unset-all", HOST_KEY]), cmd(&["--unset-all", PATH_KEY])];
    };
    vec![
        // An empty value resets the helper list for github.com (a gh login's
        // `gh auth git-credential` or a store), so only this helper answers.
        cmd(&["--replace-all", HOST_KEY, ""]),
        cmd(&["--add", HOST_KEY, helper]),
        cmd(&["--replace-all", PATH_KEY, "true"]),
    ]
}

fn setup(args: &[String]) -> u8 {
    let unset = match args {
        [] => false,
        [flag] if flag == "--unset" => true,
        _ => return usage("setup takes --unset only"),
    };
    let helper = if unset {
        None
    } else if let Some(program) = self_program() {
        Some(helper_value(&program))
    } else {
        eprintln!("cmux github setup: cannot find this binary's path");
        return 1;
    };
    for args in setup_commands(helper.as_deref()) {
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
    let (out, note) =
        credential_get(&input, git_op(), workflows, &mut |ask| ask_retrying(socket, ask));
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
    let minted = match ask_retrying(Path::new(AGENT_SOCKET), &gh_ask(&plan.repo, plan.write)) {
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
        // Only github.com: the token is for it and no other host.
        .env("GH_HOST", "github.com")
        .env_remove("GITHUB_TOKEN")
        .env_remove("GH_ENTERPRISE_TOKEN")
        .env_remove("GITHUB_ENTERPRISE_TOKEN")
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
        assert_eq!(note.as_deref(), Some("o/r: integration.not_found: no GitHub connection"));
        assert!(!note.unwrap().contains(SECRET));
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
            gh_plan(&strings(&["api", "x", "--hostname", "evil.ghe.com"]), Some("o/r"), &none)
                .is_err()
        );
        assert!(
            gh_plan(&strings(&["api", "x", "--hostname=GitHub.com"]), Some("o/r"), &none).is_ok()
        );
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
        assert_eq!(
            retry_delay(&with("integration.unavailable", None)),
            Some(Duration::from_secs(1))
        );
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
            vec![
                json!({ "contents": "write", "workflows": "write" }),
                json!({ "contents": "write" })
            ]
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
