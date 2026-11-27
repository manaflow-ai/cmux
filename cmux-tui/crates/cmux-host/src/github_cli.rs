//! `cmux github …` on a cmux Cloud machine: git and `gh` with short-lived,
//! repo-scoped GitHub tokens and no login on the machine. On a machine joined to a cmux hub
//! (`acpmux machine join`) with no Cloud agent, each ask goes to that hub instead
//! (`github_cli_joined.rs`), and on a machine the person added from their Mac, to that Mac
//! through the agent session's acpmux daemon (`github_cli_lane.rs`), with the same answers.
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
use crate::github_cli_joined::{JoinedMachine, Post, ask_hub, https_post, joined_now};
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
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Refused {
    pub code: String,
    pub message: String,
    /// Seconds, from a `rate_limited` answer.
    pub retry_after: Option<u64>,
    /// The GitHub page where the repository can be granted to the cmux GitHub App, when the
    /// refusal names one (a github.com https URL; the agent checks it).
    pub configure_url: Option<String>,
    /// Why a `policy.denied` refused the repository (`cloud::github::DENY_REASONS`), when the
    /// API says.
    pub reason: Option<String>,
}

impl std::fmt::Display for Refused {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        if self.message.is_empty() {
            write!(f, "{}", self.code)?;
        } else {
            write!(f, "{}: {}", self.code, self.message)?;
        }
        match next_step(&self.code, self.configure_url.as_deref()) {
            Some(next) => write!(f, ". Next: {next}"),
            None => Ok(()),
        }
    }
}

pub use crate::github_connect::CONNECT_GITHUB;

impl Refused {
    /// What is wrong with `subject` (a repository, or "GitHub") and, when the person can fix
    /// it, the one line that says how: the cmux GitHub App not installed, the repository not
    /// granted to it, the team's GitHub connection or this machine's Cloud sign-in to renew.
    /// Anything else is the code and message on one line.
    pub fn explain(&self, subject: &str) -> (String, Option<String>) {
        let lead = format!("cmux could not get a GitHub token for {subject}");
        let again = "then run the same command again";
        if self.code == "policy.denied"
            && let Some(why) = self.reason.as_deref().and_then(|r| self.denied(r, subject, &lead))
        {
            return why;
        }
        match self.code.as_str() {
            "integration.not_found" | "github.not_connected" => (
                format!("{lead}: the cmux GitHub App is not installed for this cmux team."),
                Some(format!("To install it, {CONNECT_GITHUB}; {again}.")),
            ),
            "policy.denied" if !self.message.contains("workflows") => {
                let grant = match &self.configure_url {
                    Some(url) => format!("open {url} and add the repository"),
                    None => format!("{CONNECT_GITHUB}, and add the repository on GitHub's page"),
                };
                (
                    format!(
                        "{lead}: the repository is not granted to the cmux GitHub App, or the \
                         team's policy does not allow it."
                    ),
                    Some(format!("To grant it, {grant} (or ask a team admin); {again}.")),
                )
            }
            "needs_reauth" => (
                format!(
                    "{lead}: the team's GitHub connection needs renewing (the app was removed or \
                     suspended on GitHub)."
                ),
                Some(format!("To renew it, {CONNECT_GITHUB}; {again}.")),
            ),
            "github.permissions_pending" => (
                format!(
                    "{lead}: the cmux GitHub App asks for updated permissions this account has \
                     not accepted yet."
                ),
                Some(format!("{}.", permissions_pending_step(self.configure_url.as_deref()))),
            ),
            "github.no_owner" => (
                format!(
                    "{lead}: no Mac that lends GitHub to this machine is connected (cmux on the \
                     Mac that added it is closed, asleep or signed out)."
                ),
                Some(format!(
                    "Open cmux on that Mac (or add this machine from it with Add Machine, GitHub \
                     on); {again}."
                )),
            ),
            "github.denied" => (
                format!("{lead}: the Mac that added this machine does not lend it GitHub."),
                Some(format!(
                    "Turn GitHub on for this machine in cmux on that Mac (Add Machine); {again}."
                )),
            ),
            "auth.required" | "auth.forbidden" | "auth.refused" | "vm.unbound" => (
                format!("{lead}: this machine's cmux Cloud sign-in needs renewing."),
                Some(format!(
                    "Reconnect this machine to cmux Cloud from cmux on your Mac; {again}."
                )),
            ),
            _ if self.message.is_empty() => (format!("{lead} ({}).", self.code), None),
            _ => (format!("{lead} ({}: {}).", self.code, self.message), None),
        }
    }

    /// A `policy.denied` with the API's reason: what is wrong and who can fix it. The owner of
    /// another account's repository installs the App; the installation's page adds a repository
    /// (and the team's connection picks it up when it is connected again); a team admin changes
    /// the team's policy.
    fn denied(&self, reason: &str, subject: &str, lead: &str) -> Option<(String, Option<String>)> {
        let again = "then run the same command again";
        let owner = subject.split_once('/').map_or(subject, |(owner, _)| owner);
        Some(match reason {
            "owner_not_connected" => (
                format!(
                    "{lead}: {owner} has no cmux GitHub App installation connected to this cmux \
                     team (the repository belongs to an account the team has not connected)."
                ),
                Some(format!(
                    "If you own {owner}, {CONNECT_GITHUB} and install the App on {owner}; if you \
                     only collaborate on it, ask its owner to install the cmux GitHub App on \
                     {owner} with this repository, then connect it in cmux; {again}."
                )),
            ),
            // The selected connection is the only authority, so its account must be the owner.
            "connection_other_owner" => (
                format!(
                    "{lead}: the selected GitHub connection is for another account, not {owner}."
                ),
                Some(format!(
                    "Select the team's GitHub connection on {owner}; if the team has none, \
                     {CONNECT_GITHUB} and install the App on {owner}; {again}."
                )),
            ),
            // The team's list is what the person who connected GitHub could see in the
            // installation: either the installation or that person's access leaves it out.
            "repo_not_granted" => {
                let grant = match &self.configure_url {
                    Some(url) => format!("open {url} and add it"),
                    None => "add it to the installation on GitHub".to_owned(),
                };
                (
                    format!(
                        "{lead}: the team's cmux GitHub App connection on {owner} does not \
                         include the repository (the installation leaves it out, or the person \
                         who connected GitHub could not see it)."
                    ),
                    Some(format!(
                        "If the installation leaves it out, {grant}; then {CONNECT_GITHUB} \
                         again as someone who can see the repository (or ask a team admin); \
                         {again}."
                    )),
                )
            }
            "repo_not_allowed" => (
                format!("{lead}: the team's GitHub policy does not allow this repository."),
                Some(format!(
                    "Ask a team admin to add it to the team's GitHub repository allowlist; {again}."
                )),
            ),
            "permissions_not_granted" => (
                format!(
                    "{lead}: the cmux GitHub App installation does not grant the access this \
                     needs (for example write access to the repository)."
                ),
                Some(match &self.configure_url {
                    Some(url) => format!(
                        "Ask an owner of {owner} to review the App's access at {url}; {again}."
                    ),
                    None => format!("Ask an owner of {owner} to review the App's access; {again}."),
                }),
            ),
            "workflows_not_allowed" => (
                format!(
                    "{lead} with workflow access: the team's GitHub policy does not allow \
                     changing GitHub Actions workflows (.github/workflows)."
                ),
                Some(format!(
                    "Ask a team admin to allow workflow changes in the team's GitHub policy, or \
                     leave .github/workflows unchanged; {again}."
                )),
            ),
            _ => return None,
        })
    }

    /// [`Refused::explain`] as the one or two lines stderr shows.
    pub fn explained(&self, subject: &str) -> String {
        match self.explain(subject) {
            (what, Some(fix)) => format!("{what}\n{fix}"),
            (what, None) => what,
        }
    }
}

/// The one next step for a refusal the person can fix, or `None` (an outage, a bad answer:
/// retrying is all there is). Leo, 2026-11-10: when the user is not connected, the error says
/// exactly how to connect, and it is retryable once connected. `configure_url`: the refusal's
/// GitHub installation page, when it names one.
pub fn next_step(code: &str, configure_url: Option<&str>) -> Option<String> {
    match code {
        // The cmux GitHub App asks for more than the installation accepted (contents: write).
        "github.permissions_pending" => Some(permissions_pending_step(configure_url)),
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

/// The step for `github.permissions_pending`: accept the App's updated permissions on the
/// installation's GitHub page (the refusal's `configure_url`), then run the command again.
fn permissions_pending_step(configure_url: Option<&str>) -> String {
    let page =
        configure_url.unwrap_or("the cmux GitHub App installation's settings page on GitHub");
    format!(
        "GitHub needs you to accept cmux's updated permissions for this account: open {page} \
         and accept, then run the same command again"
    )
}

/// Whether the same ask can succeed later with nothing changed on this machine: after the
/// person connects (or reconnects) GitHub, accepts the App's updated permissions, or after a
/// wait.
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
            | "github.no_owner"
            | "github.permissions_pending"
    )
}

pub fn refused(code: &str, message: impl Into<String>) -> Refused {
    Refused {
        code: code.to_owned(),
        message: message.into(),
        retry_after: None,
        configure_url: None,
        reason: None,
    }
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

/// [`ask_here`] with this process's join reader (`github_cli_joined::set_joined_source`) and
/// HTTPS, retried once after a retryable refusal.
pub fn ask_retrying(socket: &Path, ask: &TokenAsk) -> Result<Minted, Refused> {
    let once = || ask_here(socket, ask, &joined_now, &https_post);
    match once() {
        Err(e) => match retry_delay(&e) {
            Some(delay) => {
                std::thread::sleep(delay);
                once()
            }
            None => Err(e),
        },
        ok => ok,
    }
}

/// One ask for this machine: its Cloud agent over `socket`, else, when no agent socket answers
/// and the machine is joined to a hub (`joined`), that hub's machine token route
/// (`github_cli_joined.rs`), else, in an acpmux agent session on a machine a Mac lends GitHub
/// to, that Mac through the session's daemon (`github_cli_lane.rs`). None: the agent's
/// `vm.agent_unreachable`.
pub fn ask_here(
    socket: &Path,
    ask: &TokenAsk,
    joined: &dyn Fn() -> Option<JoinedMachine>,
    post: &Post<'_>,
) -> Result<Minted, Refused> {
    match UnixStream::connect(socket) {
        Ok(stream) => minted_from_reply(&reply_on(stream, &ask.to_line(), ASK_TIMEOUT)?),
        Err(e) => match joined() {
            Some(machine) => ask_hub(&machine, ask, post),
            None => crate::github_cli_lane::ask_lane(ask)
                .unwrap_or_else(|| Err(unreachable(socket, &e))),
        },
    }
}

/// One ask over the agent socket: write the line, read the one reply.
pub fn ask_agent(socket: &Path, ask: &TokenAsk) -> Result<Minted, Refused> {
    minted_from_reply(&agent_reply(socket, &ask.to_line(), ASK_TIMEOUT)?)
}

/// The token of an agent reply line (`{ok: true, token}`), or its refusal
/// (`{ok: false, error: {code, message, configure_url?, reason?}, retry_after?}`).
pub(crate) fn minted_from_reply(reply: &Value) -> Result<Minted, Refused> {
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
    e.configure_url = error
        .field("configure_url")
        .as_str()
        .filter(|url| crate::cloud::github::configure_url(url))
        .map(str::to_owned);
    e.reason = error
        .field("reason")
        .as_str()
        .filter(|r| crate::cloud::github::DENY_REASONS.contains(r))
        .map(str::to_owned);
    Err(e)
}

/// One line to the agent socket and its one JSON reply, read within `wait`.
pub(crate) fn agent_reply(socket: &Path, line: &str, wait: Duration) -> Result<Value, Refused> {
    let stream = UnixStream::connect(socket).map_err(|e| unreachable(socket, &e))?;
    reply_on(stream, line, wait)
}

/// No agent at `socket` (and no join to ask instead).
fn unreachable(socket: &Path, e: &std::io::Error) -> Refused {
    refused(
        "vm.agent_unreachable",
        format!(
            "{} ({e}); `cmux github` works on a cmux Cloud machine or a machine joined to a cmux \
             hub (`acpmux machine join`)",
            socket.display()
        ),
    )
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
    let mut no_workflows: Option<Refused> = None;
    for each in credential_asks(&repo, op, workflows) {
        match ask(&each) {
            Ok(minted) => {
                let out = format!("username=x-access-token\npassword={}\n", minted.token);
                // CMUX_GITHUB_WORKFLOWS asked for workflow access and was refused: the push goes
                // ahead without it, and GitHub refuses it if it changes .github/workflows.
                let note =
                    no_workflows.filter(|_| !each.permissions.contains_key("workflows")).map(|e| {
                        let (what, fix) = e.explain(&repo);
                        let fix = fix.map_or_else(String::new, |fix| format!("\n{fix}"));
                        format!(
                            "{what}\nThe push goes ahead without workflow access: GitHub refuses \
                             it if it changes .github/workflows.{fix}"
                        )
                    });
                return (out, note);
            }
            Err(e) if e.code == "policy.denied" => {
                if each.permissions.contains_key("workflows") {
                    no_workflows = Some(e.clone());
                }
                last = Some(e);
            }
            Err(e) => return (String::new(), Some(refusal_note(&e, &repo))),
        }
    }
    (String::new(), last.map(|e| refusal_note(&e, &repo)))
}

/// A refusal as `credential get` writes it to stderr: [`Refused::explained`], then the code in
/// brackets. The code is the stable part: the app's setup probe (CmuxNextApp
/// `CloudGitHubSetup.unboundProbe`) reads `policy.denied` there to tell a working path (the
/// agent reached the API, which refused a repository no team has) from a broken one.
fn refusal_note(e: &Refused, repo: &str) -> String {
    format!("{} [{}]", e.explained(repo), e.code)
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
/// `policy.denied`; any other refusal ends it. With the token comes the
/// refusal of the wider ask before it, when one was refused (a write ask
/// refused, so the token reads only).
pub fn first_token(
    asks: &[TokenAsk],
    ask: &mut dyn FnMut(&TokenAsk) -> Result<Minted, Refused>,
) -> Result<(Minted, Option<Refused>), Refused> {
    let mut last = None;
    for each in asks {
        match ask(each) {
            Ok(minted) => return Ok((minted, last)),
            Err(e) if e.code == "policy.denied" => last = Some(e),
            Err(e) => return Err(e),
        }
    }
    Err(last.unwrap_or_else(|| refused("policy.denied", "no permission set was asked")))
}

/// What `gh` says before it runs on a read token because the write ask was refused: why, that a
/// change it makes (`pr create`, an issue comment) is refused by GitHub, and the fix when there is
/// one. Without it gh ends with GitHub's bare "Resource not accessible by integration".
pub fn read_only_note(repo: &str, wider: &Refused) -> String {
    let (what, fix) = wider.explain(repo);
    let fix = fix.map_or_else(String::new, |fix| format!("\n{fix}"));
    format!(
        "{what}\ngh runs with read access to {repo} only, so GitHub refuses a change it makes \
         (a pull request, an issue or a comment).{fix}"
    )
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

/// The working folder's `origin` as configured. Not `git remote get-url`: that applies
/// `url.*.insteadOf`, and a Cloud machine's git cache rewrites every github.com fetch URL to
/// its loopback proxy (`cmux_git_cache::gitconfig`), so the repo read as none there and
/// `acpmux github-mcp` had no default repo (journey runs 45750510949, 45778908629).
pub fn origin_url() -> Option<String> {
    origin_url_in(None)
}

/// [`origin_url`] for `dir` (the process's working folder when none).
pub fn origin_url_in(dir: Option<&Path>) -> Option<String> {
    let mut git = std::process::Command::new("git");
    if let Some(dir) = dir {
        git.arg("-C").arg(dir);
    }
    let out = git.args(["config", "--get", "remote.origin.url"]).output().ok()?;
    let url = String::from_utf8_lossy(&out.stdout).trim().to_owned();
    (out.status.success() && !url.is_empty()).then_some(url)
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
                Ok((minted, wider)) => {
                    if let Some(wider) = wider {
                        eprintln!("cmux github gh: {}", read_only_note(&repo, &wider));
                    }
                    command
                        .env("GH_TOKEN", &minted.token)
                        .env("GH_HOST", "github.com")
                        .env_remove("GITHUB_TOKEN")
                        .env_remove("GH_ENTERPRISE_TOKEN")
                        .env_remove("GITHUB_ENTERPRISE_TOKEN");
                }
                Err(e) => match e.explain(&repo) {
                    (what, Some(fix)) => {
                        eprintln!("cmux github gh: {what} gh runs without one.\n{fix}");
                    }
                    (what, None) => eprintln!("cmux github gh: {what} gh runs without one."),
                },
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
            eprintln!("cmux github gh: {}", e.explained(&plan.repo));
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

    /// A Cloud machine's git cache rewrites github.com fetches to its proxy; the repo still reads.
    #[test]
    fn origin_reads_through_a_git_cache_rewrite() {
        let tmp = tempfile::tempdir().unwrap();
        let git = |args: &[&str]| {
            let ok = std::process::Command::new("git")
                .arg("-C")
                .arg(tmp.path())
                .args(args)
                .env("GIT_CONFIG_GLOBAL", "/dev/null")
                .env("GIT_CONFIG_NOSYSTEM", "1")
                .status()
                .unwrap()
                .success();
            assert!(ok, "git {args:?}");
        };
        git(&["init", "-q"]);
        assert_eq!(origin_url_in(Some(tmp.path())), None);
        git(&["remote", "add", "origin", "https://github.com/acme/app.git"]);
        git(&["config", "url.http://127.0.0.1:47380/github.com/.insteadOf", "https://github.com/"]);
        let url = origin_url_in(Some(tmp.path()));
        assert_eq!(url.as_deref(), Some("https://github.com/acme/app.git"));
        assert_eq!(url.as_deref().and_then(repo_from).as_deref(), Some("acme/app"));
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
        assert!(
            note.starts_with(
                "cmux could not get a GitHub token for o/r: the cmux GitHub App is not installed \
                 for this cmux team.\nTo install it, in cmux choose Connect GitHub"
            ),
            "{note}"
        );
        assert!(note.contains("`cmux accounts github-connect`"), "{note}");
        assert_eq!(note.lines().count(), 2, "{note}");
        assert!(!note.contains(SECRET));
    }

    #[test]
    fn a_refused_ask_keeps_its_code_on_stderr_for_the_setup_probe() {
        // CloudGitHubSetup.unboundProbe asks for a repository no team has and reads
        // `policy.denied` on stderr as "the agent reached the API": the explained text must keep it.
        for reason in [None, Some("owner_not_connected")] {
            let (out, note) = credential_get(
                "protocol=https\nhost=github.com\npath=cmux-setup-probe/none.git\n\n",
                GitOp::Unknown,
                false,
                &mut |_| {
                    Err(Refused {
                        reason: reason.map(str::to_owned),
                        ..refused("policy.denied", "may not act on cmux-setup-probe/none")
                    })
                },
            );
            assert_eq!(out, "");
            let note = note.unwrap();
            assert!(note.ends_with(" [policy.denied]"), "{note}");
            assert_eq!(note.lines().count(), 2, "{note}");
        }
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
    fn each_refusal_the_person_can_fix_says_what_is_wrong_and_what_to_do_in_two_lines() {
        let lines = |e: &Refused| e.explained("acme/web");
        let not_installed = lines(&refused("integration.not_found", "no GitHub connection"));
        assert!(not_installed.contains("the cmux GitHub App is not installed"), "{not_installed}");
        assert!(not_installed.contains("Connect GitHub"), "{not_installed}");

        // Not granted: the configure page when the refusal names one, else Connect GitHub.
        let denied = refused("policy.denied", "may not act on acme/web");
        let plain = lines(&denied);
        assert!(plain.contains("not granted to the cmux GitHub App"), "{plain}");
        assert!(plain.contains("Connect GitHub"), "{plain}");
        assert!(plain.contains(", and add the repository on GitHub's page"), "{plain}");
        let url = "https://github.com/organizations/acme/settings/installations/9";
        let with_page = lines(&Refused { configure_url: Some(url.to_owned()), ..denied });
        assert!(with_page.contains(&format!("open {url} and add the repository")), "{with_page}");
        // A workflows refusal is no grant problem: its own words.
        let workflows = lines(&refused("policy.denied", "workflows: write needs the team policy"));
        assert_eq!(
            workflows,
            "cmux could not get a GitHub token for acme/web (policy.denied: workflows: write \
             needs the team policy)."
        );

        let renew = lines(&refused("needs_reauth", "link GitHub again"));
        assert!(renew.contains("GitHub connection needs renewing"), "{renew}");
        for code in ["auth.required", "auth.forbidden", "vm.unbound"] {
            let signin = lines(&refused(code, ""));
            assert!(signin.contains("cmux Cloud sign-in needs renewing"), "{code}: {signin}");
            assert!(signin.contains("Reconnect this machine"), "{code}: {signin}");
        }
        for text in [not_installed, plain, with_page, renew] {
            assert_eq!(text.lines().count(), 2, "{text}");
        }
        assert_eq!(
            lines(&refused("integration.unavailable", "")),
            "cmux could not get a GitHub token for acme/web (integration.unavailable)."
        );
    }

    #[test]
    fn a_pending_permission_update_names_its_page_and_is_retryable() {
        let page = "https://github.com/organizations/acme/settings/installations/99";
        let pending = Refused {
            configure_url: Some(page.to_owned()),
            ..refused(
                "github.permissions_pending",
                "GitHub needs you to accept cmux's updated permissions for acme.",
            )
        };
        let step = next_step(&pending.code, pending.configure_url.as_deref()).unwrap();
        assert_eq!(
            step,
            format!(
                "GitHub needs you to accept cmux's updated permissions for this account: open \
                 {page} and accept, then run the same command again"
            )
        );
        assert!(pending.to_string().ends_with(&format!(". Next: {step}")), "{pending}");
        let (what, fix) = pending.explain("acme/web");
        assert!(what.contains("updated permissions"), "{what}");
        assert_eq!(fix, Some(format!("{step}.")));
        let bare = next_step("github.permissions_pending", None).unwrap();
        assert!(bare.contains("installation's settings page on GitHub"), "{bare}");
        assert!(retryable("github.permissions_pending"));
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

    #[test]
    fn ask_agent_keeps_a_known_deny_reason_and_the_configure_page() {
        let (_dir, socket, agent) = fake_agent(
            "{\"ok\":false,\"status\":403,\"error\":{\"code\":\"policy.denied\",\"message\":\"m\",\"reason\":\"repo_not_granted\",\"configure_url\":\"https://github.com/settings/installations/9\"}}\n",
        );
        let err = ask_agent(&socket, &gh_ask("o/r", false)).unwrap_err();
        assert_eq!(err.reason.as_deref(), Some("repo_not_granted"));
        assert_eq!(
            err.configure_url.as_deref(),
            Some("https://github.com/settings/installations/9")
        );
        agent.join().unwrap();
        let (_dir, socket, agent) = fake_agent(
            "{\"ok\":false,\"error\":{\"code\":\"policy.denied\",\"message\":\"m\",\"reason\":\"made_up\"}}\n",
        );
        assert_eq!(ask_agent(&socket, &gh_ask("o/r", false)).unwrap_err().reason, None);
        agent.join().unwrap();
    }

    #[test]
    fn each_deny_reason_names_who_can_fix_it() {
        let denied = |reason: &str, url: Option<&str>| {
            Refused {
                reason: Some(reason.to_owned()),
                configure_url: url.map(str::to_owned),
                ..refused("policy.denied", "m")
            }
            .explained("acme/web")
        };
        let page = "https://github.com/organizations/acme/settings/installations/9";
        // A repository of an account the team has not connected: its owner installs the App.
        let other = denied("owner_not_connected", None);
        assert!(other.contains("acme has no cmux GitHub App installation connected"), "{other}");
        assert!(other.contains("ask its owner to install the cmux GitHub App on acme"), "{other}");
        assert!(other.contains("If you own acme, in cmux choose Connect GitHub"), "{other}");
        // Not in the installation: its page, then connect again so the team's list has it.
        // The selected connection is on another account: select the owner's, never "no connection".
        let selected = denied("connection_other_owner", None);
        assert!(
            selected.contains("the selected GitHub connection is for another account, not acme"),
            "{selected}"
        );
        assert!(selected.contains("Select the team's GitHub connection on acme"), "{selected}");
        assert!(!selected.contains("has no cmux GitHub App installation"), "{selected}");
        // Not in the team's list (the linking person's access): the installation may already
        // include it, so both fixes, ending with connecting again as someone who can see it.
        let missing = denied("repo_not_granted", Some(page));
        assert!(missing.contains("does not include the repository"), "{missing}");
        assert!(missing.contains("the person who connected GitHub could not see it"), "{missing}");
        assert!(
            missing.contains(&format!(
                "If the installation leaves it out, open {page} and add it; then in cmux choose \
                 Connect GitHub"
            )),
            "{missing}"
        );
        assert!(missing.contains("again as someone who can see the repository"), "{missing}");
        let no_page = denied("repo_not_granted", None);
        assert!(no_page.contains("add it to the installation on GitHub; then"), "{no_page}");
        let allowlist = denied("repo_not_allowed", Some(page));
        assert!(
            allowlist
                .contains("Ask a team admin to add it to the team's GitHub repository allowlist"),
            "{allowlist}"
        );
        assert!(
            !allowlist.contains(page),
            "the allowlist is not fixed on GitHub's page: {allowlist}"
        );
        let access = denied("permissions_not_granted", Some(page));
        assert!(access.contains("does not grant the access this needs"), "{access}");
        assert!(access.contains(&format!("review the App's access at {page}")), "{access}");
        let workflows = denied("workflows_not_allowed", None);
        assert!(
            workflows.contains("does not allow changing GitHub Actions workflows"),
            "{workflows}"
        );
        assert!(workflows.contains("Ask a team admin to allow workflow changes"), "{workflows}");
        for text in [other, selected, missing, no_page, allowlist, access, workflows] {
            assert_eq!(text.lines().count(), 2, "{text}");
            assert!(text.starts_with("cmux could not get a GitHub token for acme/web"), "{text}");
        }
        // A reason this build does not know reads as before.
        assert_eq!(denied("made_up", None), refused("policy.denied", "m").explained("acme/web"));
    }

    #[test]
    fn a_refused_workflows_ask_says_the_push_goes_ahead_without_it() {
        let (out, note) = credential_get(
            "protocol=https\nhost=github.com\npath=o/r\n",
            GitOp::Push,
            true,
            &mut |ask| {
                if ask.permissions.contains_key("workflows") {
                    Err(Refused {
                        reason: Some("workflows_not_allowed".to_owned()),
                        ..refused("policy.denied", "workflows: write needs the team policy")
                    })
                } else {
                    Ok(minted())
                }
            },
        );
        assert!(out.contains(SECRET));
        let note = note.unwrap();
        assert!(note.contains("GitHub refuses it if it changes .github/workflows"), "{note}");
        assert!(note.contains("Ask a team admin to allow workflow changes"), "{note}");
        assert!(!note.contains(SECRET));
        // Granted with workflows: nothing to say.
        let (_, note) = credential_get(
            "protocol=https\nhost=github.com\npath=o/r\n",
            GitOp::Push,
            true,
            &mut |_| Ok(minted()),
        );
        assert_eq!(note, None);
    }

    #[test]
    fn a_read_only_gh_says_why_and_that_changes_are_refused() {
        let wider = Refused {
            reason: Some("permissions_not_granted".to_owned()),
            ..refused("policy.denied", "GitHub refused")
        };
        let note = read_only_note("o/r", &wider);
        assert!(note.contains("does not grant the access this needs"), "{note}");
        assert!(
            note.contains("gh runs with read access to o/r only, so GitHub refuses a change"),
            "{note}"
        );
        assert!(note.contains("Ask an owner of o to review the App's access"), "{note}");
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
        let (got, wider) = got.unwrap();
        assert_eq!(got.token, SECRET);
        assert_eq!(wider.map(|e| e.message), Some("no write".to_owned()));
        assert_eq!(seen, ["write", "read"]);
        // The first ask answered: nothing was narrowed.
        let (_, wider) = first_token(&asks, &mut |_| Ok(minted())).unwrap();
        assert_eq!(wider, None);
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
}
