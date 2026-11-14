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
//! - `gh --auto ARGS…`: plain `gh` as the image's shim runs it. The
//!   person's own auth (`GH_TOKEN` and the like, their own `gh auth login`)
//!   and verbs that need no repo token (`auth`, `config`, ...) go to gh
//!   untouched; a read (`pr list`, `gh api` GET) asks the read set, any
//!   other command write then read. With no repo, or when the API refuses,
//!   gh still runs, without a token, after one line on stderr.
//!   `CMUX_GITHUB_GH_REAL` names the gh to run (the shim's real one).
//!   With no auth of the person's own, `gh auth status` and `gh api user`
//!   are answered from the account cmux has connected
//!   (`github_cli_identity.rs`), never with a token.
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

const USAGE: &str = "usage: cmux github credential get|store|erase | gh [--write] [--] ARGS... | gh --auto [--] ARGS... | setup [--unset]";
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
            write!(f, "{}", self.code)?;
        } else {
            write!(f, "{}: {}", self.code, self.message)?;
        }
        match next_step(&self.code) {
            Some(next) => write!(f, ". Next: {next}"),
            None => Ok(()),
        }
    }
}

pub use crate::github_connect::CONNECT_GITHUB;

/// The one next step for a refusal the person can fix, or `None` (an outage, a bad answer:
/// retrying is all there is). Leo, 2026-11-10: when the user is not connected, the error says
/// exactly how to connect, and it is retryable once connected.
pub fn next_step(code: &str) -> Option<String> {
    match code {
        "integration.not_found" | "github.not_connected" => Some(format!(
            "GitHub is not connected for this cmux team: {CONNECT_GITHUB}. Then run the same \
             command again; nothing needs setting up on this machine"
        )),
        "needs_reauth" => Some(format!(
            "the team's GitHub connection needs linking again: {CONNECT_GITHUB}. Then run the \
             same command again"
        )),
        "policy.denied" => Some(format!(
            "the team's GitHub connection does not cover this repository: {CONNECT_GITHUB} and \
             pick it on GitHub's page, or ask a team admin to allow it"
        )),
        _ => None,
    }
}

/// Whether the same ask can succeed later with nothing changed on this machine: after the
/// person connects (or reconnects) GitHub, or after a wait.
pub fn retryable(code: &str) -> bool {
    matches!(
        code,
        "integration.not_found"
            | "github.not_connected"
            | "needs_reauth"
            | "integration.unavailable"
            | "busy"
            | "rate_limited"
            | "vm.agent_unreachable"
    )
}

pub fn refused(code: &str, message: impl Into<String>) -> Refused {
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
pub fn ask_retrying(socket: &Path, ask: &TokenAsk) -> Result<Minted, Refused> {
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
    let reply = agent_reply(socket, &ask.to_line(), ASK_TIMEOUT)?;
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

/// One line to the agent socket and its one JSON reply, read within `wait`.
pub(crate) fn agent_reply(socket: &Path, line: &str, wait: Duration) -> Result<Value, Refused> {
    let stream = UnixStream::connect(socket).map_err(|e| {
        refused(
            "vm.agent_unreachable",
            format!("{} ({e}); `cmux github` works on a cmux Cloud machine", socket.display()),
        )
    })?;
    reply_on(stream, line, wait)
}

/// [`agent_reply`] on a connected socket: one line out, one JSON line back.
pub(crate) fn reply_on(
    mut stream: UnixStream,
    line: &str,
    wait: Duration,
) -> Result<Value, Refused> {
    let io = |e: std::io::Error| refused("vm.agent_unreachable", e.to_string());
    stream.set_read_timeout(Some(wait)).map_err(io)?;
    stream.set_write_timeout(Some(Duration::from_secs(5))).map_err(io)?;
    stream.write_all(format!("{line}\n").as_bytes()).map_err(io)?;
    let mut reply = String::new();
    BufReader::new(stream.take(64 * 1024)).read_line(&mut reply).map_err(io)?;
    serde_json::from_str(&reply).map_err(|_| {
        refused("vm.agent_bad_answer", "the Cloud agent's answer is not JSON (an older image?)")
    })
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

/// What `cmux github gh --auto` (the image's `gh` shim) knows besides the
/// arguments: whether a token is already in the environment, whether the
/// person has their own gh login, and `GH_REPO`.
#[derive(Clone, Copy, Debug)]
pub struct GhContext<'a> {
    pub token_env: bool,
    pub own_login: bool,
    pub gh_repo: Option<&'a str>,
}

/// Where `--auto` sends one gh run.
#[derive(Debug, PartialEq, Eq)]
pub enum GhRoute {
    /// The real gh, untouched: the person's own auth, or a verb that needs no
    /// repo token (`auth`, `config`, `--version`, ...).
    Direct,
    /// The real gh with no token, after `note` on stderr: no repo to ask for,
    /// or an argument that names a host this machine's token is not for.
    Untokened { note: String },
    /// The real gh with a token for `repo`: `asks` in order, each next one
    /// only after a `policy.denied`.
    Token { repo: String, args: Vec<String>, asks: Vec<TokenAsk> },
}

/// gh verbs that never need a repo token.
const GH_DIRECT_VERBS: [&str; 11] = [
    "auth",
    "config",
    "help",
    "version",
    "completion",
    "alias",
    "extension",
    "ext",
    "--version",
    "--help",
    "-h",
];
/// Second words that only read (`gh pr list`, `gh run watch`).
const GH_READ_SUBVERBS: [&str; 8] =
    ["view", "list", "status", "diff", "checks", "watch", "download", "browse"];
/// First words that only read.
const GH_READ_VERBS: [&str; 3] = ["browse", "search", "status"];

/// The words of a gh command line that are not flags: `-R`/`--repo` and
/// `--hostname` values are skipped (they come before the verb as often as
/// after it).
fn gh_words(args: &[String]) -> Vec<&str> {
    let mut words = Vec::new();
    let mut it = args.iter();
    while let Some(arg) = it.next() {
        if arg == "--" {
            break;
        }
        if arg == "-R" || arg == "--repo" || arg == "--hostname" {
            it.next();
        } else if !arg.starts_with('-')
            || words.is_empty() && GH_DIRECT_VERBS.contains(&arg.as_str())
        {
            words.push(arg.as_str());
        }
    }
    words
}

/// Whether `gh api ARGS` only reads: no method other than GET, and no
/// fields or input (gh turns those into a POST).
fn gh_api_reads(args: &[String]) -> bool {
    let mut it = args.iter();
    while let Some(arg) = it.next() {
        let method = if arg == "-X" || arg == "--method" {
            it.next().map(String::as_str)
        } else if let Some(m) = arg.strip_prefix("--method=") {
            Some(m)
        } else if let Some(m) = arg.strip_prefix("-X") {
            Some(m.strip_prefix('=').unwrap_or(m))
        } else {
            None
        };
        if method.is_some_and(|m| !m.eq_ignore_ascii_case("GET")) {
            return false;
        }
        let field = (arg.starts_with("-f") || arg.starts_with("-F"))
            || ["--field", "--raw-field", "--input"]
                .iter()
                .any(|f| arg == f || arg.starts_with(&format!("{f}=")));
        if field {
            return false;
        }
    }
    true
}

/// Whether a gh command line only reads, so a read token is enough.
pub fn gh_reads_only(args: &[String]) -> bool {
    let words = gh_words(args);
    match words.as_slice() {
        ["api", ..] => gh_api_reads(args),
        [verb, ..] if GH_READ_VERBS.contains(verb) => true,
        [_, sub, ..] => GH_READ_SUBVERBS.contains(sub),
        _ => false,
    }
}

/// `--auto`'s decision for one gh run (see the module docs and
/// plans/cmux-next/cloud-github-auth-DESIGN.md 3.2).
pub fn gh_auto_route(
    args: &[String],
    cx: &GhContext<'_>,
    origin: &dyn Fn() -> Option<String>,
) -> GhRoute {
    if cx.token_env || cx.own_login {
        return GhRoute::Direct;
    }
    match gh_words(args).first() {
        None => return GhRoute::Direct,
        Some(verb) if GH_DIRECT_VERBS.contains(verb) => return GhRoute::Direct,
        Some(_) => {}
    }
    let plan = match gh_plan(args, cx.gh_repo, origin) {
        Ok(plan) => plan,
        Err(why) => {
            return GhRoute::Untokened {
                note: format!(
                    "{why}; gh runs without a GitHub token (cmux mints one per repo: run it in a GitHub checkout or pass -R owner/name)"
                ),
            };
        }
    };
    let asks = if gh_reads_only(&plan.args) {
        vec![gh_ask(&plan.repo, false)]
    } else {
        vec![gh_ask(&plan.repo, true), gh_ask(&plan.repo, false)]
    };
    GhRoute::Token { repo: plan.repo, args: plan.args, asks }
}

/// The first token `asks` gets, trying the next ask only after a
/// `policy.denied`; any other refusal ends it.
pub fn first_token(
    asks: &[TokenAsk],
    ask: &mut dyn FnMut(&TokenAsk) -> Result<Minted, Refused>,
) -> Result<Minted, Refused> {
    let mut last = refused("policy.denied", "no permission set was asked");
    for each in asks {
        match ask(each) {
            Ok(minted) => return Ok(minted),
            Err(e) if e.code == "policy.denied" => last = e,
            Err(e) => return Err(e),
        }
    }
    Err(last)
}

/// What gh's `hosts.yml` holds at its root: the host keys of its root
/// mapping, or `unread` when the file is not YAML this can read or its root
/// is not a mapping. The one reader behind both own-login checks
/// (`hosts_has_github` here and `github_cli_identity::hosts_has_any_login`).
#[derive(Debug, Default, PartialEq, Eq)]
pub struct GhHosts {
    pub hosts: Vec<String>,
    /// The file did not parse, or its root is not a mapping. Fail-safe: this
    /// counts as the person's own login, so gh keeps its own answer and the
    /// team's token is never routed when we can't read the person's config.
    pub unread: bool,
}

impl GhHosts {
    /// A login for any host may be there.
    pub fn any_login(&self) -> bool {
        self.unread || !self.hosts.is_empty()
    }

    /// A github.com login may be there.
    pub fn github_login(&self) -> bool {
        self.unread || self.hosts.iter().any(|h| h.eq_ignore_ascii_case("github.com"))
    }
}

/// Parses gh's `hosts.yml` with a YAML parser and reads its root mapping's
/// string keys (the hosts). A file of only blank lines, comments and document
/// markers, or an empty document, holds no host. A file that does not parse,
/// or whose root is anything but a mapping, is `unread` (see `GhHosts`).
pub fn parse_gh_hosts(hosts_yml: &str) -> GhHosts {
    let no_content = hosts_yml.lines().all(|line| {
        let t = line.trim();
        t.is_empty() || t.starts_with('#') || t == "---" || t == "..."
    });
    if no_content {
        return GhHosts::default();
    }
    let unread = GhHosts { hosts: Vec::new(), unread: true };
    let Ok(docs) = yaml_rust::YamlLoader::load_from_str(hosts_yml) else { return unread };
    match docs.into_iter().next() {
        None | Some(yaml_rust::Yaml::Null) => GhHosts::default(),
        Some(yaml_rust::Yaml::Hash(root)) => GhHosts {
            // yaml-rust keeps the tabs of a tab-indented file at the start of
            // the key: strip those only, so a quoted `" github.com "` stays
            // another key rather than a github.com login.
            hosts: root
                .keys()
                .filter_map(|k| k.as_str().map(|h| h.trim_start_matches('\t').to_owned()))
                .collect(),
            unread: false,
        },
        Some(_) => unread,
    }
}

/// Whether gh's `hosts.yml` may hold a github.com login (a `github.com` key
/// in its root mapping, in any form YAML writes it), the person's own
/// `gh auth login`. A file that does not parse counts as one, so an unsure
/// read keeps the person's own gh rather than the team's token.
pub fn hosts_has_github(hosts_yml: &str) -> bool {
    parse_gh_hosts(hosts_yml).github_login()
}

/// gh's `hosts.yml`: `$GH_CONFIG_DIR`, else `$XDG_CONFIG_HOME/gh`, else
/// `~/.config/gh`.
pub fn gh_hosts_path(
    gh_config_dir: Option<&Path>,
    xdg_config_home: Option<&Path>,
    home: Option<&Path>,
) -> Option<PathBuf> {
    if let Some(dir) = gh_config_dir {
        return Some(dir.join("hosts.yml"));
    }
    if let Some(dir) = xdg_config_home {
        return Some(dir.join("gh/hosts.yml"));
    }
    home.map(|h| h.join(".config/gh/hosts.yml"))
}

pub fn origin_url() -> Option<String> {
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

/// The gh `--auto` and the plain form run: `CMUX_GITHUB_GH_REAL` (the
/// image's shim names the store's gh, so the shim never runs itself), else
/// `gh` on PATH.
fn real_gh() -> std::ffi::OsString {
    std::env::var_os("CMUX_GITHUB_GH_REAL").filter(|v| !v.is_empty()).unwrap_or_else(|| "gh".into())
}

const GH_TOKEN_VARS: [&str; 4] =
    ["GH_TOKEN", "GITHUB_TOKEN", "GH_ENTERPRISE_TOKEN", "GITHUB_ENTERPRISE_TOKEN"];

/// gh's `hosts.yml` text, when there is one.
fn gh_hosts_text() -> Option<String> {
    let var = |k: &str| std::env::var_os(k).filter(|v| !v.is_empty()).map(PathBuf::from);
    gh_hosts_path(
        var("GH_CONFIG_DIR").as_deref(),
        var("XDG_CONFIG_HOME").as_deref(),
        var("HOME").as_deref(),
    )
    .and_then(|p| std::fs::read_to_string(p).ok())
}

fn own_gh_login() -> bool {
    gh_hosts_text().is_some_and(|text| hosts_has_github(&text))
}

/// `gh --auto ARGS...`: plain gh on a Cloud machine (the image's shim).
/// It never fails for want of a token: gh runs, with one when it can.
fn gh_auto(args: &[String]) -> u8 {
    use std::os::unix::process::CommandExt;
    let args = args.strip_prefix(&["--".to_owned()][..]).unwrap_or(args);
    let token_env =
        GH_TOKEN_VARS.iter().any(|k| std::env::var_os(k).is_some_and(|v| !v.is_empty()));
    let gh_repo = std::env::var("GH_REPO").ok();
    let cx = GhContext {
        token_env,
        own_login: !token_env && own_gh_login(),
        gh_repo: gh_repo.as_deref(),
    };
    let identity = crate::github_cli_identity::identity_applies(
        token_env,
        gh_hosts_text().as_deref(),
        std::env::var("GH_HOST").ok().as_deref(),
        std::env::var_os(crate::cloud::github_status::GH_OWN_LOGIN_ONLY_ENV)
            .is_some_and(|v| !v.is_empty()),
    );
    if identity {
        match crate::github_cli_identity::answer_from_agent(args, Path::new(AGENT_SOCKET)) {
            Some(Ok(out)) => return out.emit(),
            // No answer from cmux: gh runs as it would have.
            Some(Err(note)) => eprintln!("cmux github gh: {note}"),
            None => {}
        }
    }
    let mut command = std::process::Command::new(real_gh());
    match gh_auto_route(args, &cx, &origin_url) {
        GhRoute::Direct => {
            command.args(args);
        }
        GhRoute::Untokened { note } => {
            eprintln!("cmux github gh: {note}");
            command.args(args);
        }
        GhRoute::Token { repo, args, asks } => {
            command.args(&args);
            match first_token(&asks, &mut |ask| ask_retrying(Path::new(AGENT_SOCKET), ask)) {
                Ok(minted) => {
                    command
                        .env("GH_TOKEN", &minted.token)
                        .env("GH_HOST", "github.com")
                        .env_remove("GITHUB_TOKEN")
                        .env_remove("GH_ENTERPRISE_TOKEN")
                        .env_remove("GITHUB_ENTERPRISE_TOKEN");
                }
                Err(e) => eprintln!(
                    "cmux github gh: no GitHub token for {repo} ({e}); gh runs without one"
                ),
            }
        }
    }
    let err = command.exec();
    eprintln!("cmux github gh: gh: {err}");
    1
}

fn gh(args: &[String]) -> u8 {
    if let Some(rest) = args.strip_prefix(&["--auto".to_owned()][..]) {
        return gh_auto(rest);
    }
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
    let err = std::process::Command::new(real_gh())
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
mod tests;
