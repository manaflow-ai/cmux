//! GitHub for the person's own machines, through the Mac's `gh` login.
//!
//! A machine the person added (the lane) asks the Mac that mirrors it as a peer (the owner) for
//! one GitHub action: an agent session there asks its daemon (`handle`), which sends the request,
//! never a credential, up the link the Mac opened to it (`server/client_request.rs`,
//! `hub/github_owner.rs`). The Mac checks it again, runs one fixed `gh` command with its own
//! login, and answers with bounded output (`peer.rs` takes the request).
//!
//! - The Mac serves only a peer whose saved config says `githubBroker`
//!   (`PeerConfig::github_broker`); any other peer is refused, as every request from a peer was.
//! - Only these actions exist: read a repository or a pull request, open an issue, comment on
//!   one, and open a draft pull request. There is no push, merge, close, delete, edit, settings,
//!   secret, workflow or `gh api` passthrough.
//! - On the lane only an agent session of that daemon may ask (its caller token, `hub/person.rs`),
//!   over the unix socket; the Web, the app's pages and peers are refused (`remote_guard.rs`).
//! - The token never leaves the Mac: `gh` reads it from the Mac's keyring, and the answer holds
//!   only `gh`'s output. Each decision is a `github_broker_action` event on the lane session and
//!   a log line on the Mac, with no title, body or output in either.

use crate::rpc::RpcError;
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use std::sync::Arc;
use tokio::process::Command;

const REPO_MAX: usize = 140;
const TEXT_MAX: usize = 64 * 1024;
const OUTPUT_MAX: usize = 64 * 1024;
/// How much of a stream is read before the rest is dropped, so a `gh` that will not stop
/// talking cannot grow the Mac's daemon for as long as `GH_TIMEOUT` allows.
const STREAM_READ_MAX: u64 = 2 * OUTPUT_MAX as u64;
/// A brokered `gh` is one bounded API call; it never waits for a person.
pub const GH_TIMEOUT: std::time::Duration = std::time::Duration::from_secs(60);
/// How late after the machine sent it a request may still reach the Mac and run, by the Mac's
/// clock: the link's delay plus how far the Mac's clock runs ahead. The two clocks are taken to
/// differ by at most this much (both keep network time); past that, a Mac ahead refuses the
/// machine's requests as late, and one behind refuses a prompt one as too far ahead, so a clock
/// that is off shows as refusals. Past it the machine stopped waiting, so the action never runs.
pub const LINK_SLACK: std::time::Duration = std::time::Duration::from_secs(30);
/// How long the machine waits for the Mac's answer: an action the Mac starts runs at most
/// `GH_TIMEOUT` from a start at most `LINK_SLACK` after it was sent by the Mac's clock, which is
/// at most `LINK_SLACK` behind, so it ends before this, with a few seconds for the answer.
pub const LANE_WAIT: std::time::Duration =
    std::time::Duration::from_secs(GH_TIMEOUT.as_secs() + 2 * LINK_SLACK.as_secs() + 5);
/// How many actions one peer (by name, across reconnects) may have running on the Mac at once.
pub const OWNER_SLOTS: usize = 4;

/// The slots of the actions of the peer named `peer`: one budget per name for the life of this
/// daemon, so a reconnect (a new peer while the old one's actions still run) starts none past
/// `OWNER_SLOTS`. A name's entry goes once nothing holds it.
pub fn owner_slots(peer: &str) -> Arc<tokio::sync::Semaphore> {
    static SLOTS: std::sync::LazyLock<
        std::sync::Mutex<std::collections::HashMap<String, Arc<tokio::sync::Semaphore>>>,
    > = std::sync::LazyLock::new(Default::default);
    let mut slots = SLOTS.lock().unwrap_or_else(|e| e.into_inner());
    slots.retain(|_, s| Arc::strong_count(s) > 1 || s.available_permits() < OWNER_SLOTS);
    slots
        .entry(peer.to_owned())
        .or_insert_with(|| Arc::new(tokio::sync::Semaphore::new(OWNER_SLOTS)))
        .clone()
}
/// The Mac's daemon sets this on the `gh` it runs, and the shim refuses to run with it set, so
/// the shim can never be the `gh` the Mac calls back into.
pub const SHIM_REFUSAL_ENV: &str = "ACPMUX_GITHUB_BROKER_OWNER";

#[derive(Debug, Clone, Copy, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum GithubAction {
    Read,
    Issue,
    Comment,
    DraftPr,
}

impl GithubAction {
    pub fn name(self) -> &'static str {
        match self {
            Self::Read => "read",
            Self::Issue => "issue",
            Self::Comment => "comment",
            Self::DraftPr => "draft_pr",
        }
    }
}

/// One action, as the shim sends it to the lane and the lane sends it to the Mac.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct GithubActionParams {
    /// The lane session that asked. The lane sets it from the caller it proved; whatever a
    /// caller put here is replaced.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub session_id: Option<String>,
    pub action: GithubAction,
    pub repo: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub branch: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub base: Option<String>,
    /// The issue or pull request number of a comment or a pull request read.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub issue: Option<u64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub title: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub body: Option<String>,
    /// Unix ms, by the machine's clock: when it stops waiting for the answer
    /// ([`deadline_from`]). The lane sets it; the Mac starts nothing that could finish later.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub deadline_ms: Option<u64>,
}

/// The deadline the lane gives an action it sends at `now_ms`.
pub fn deadline_from(now_ms: u64) -> u64 {
    now_ms + (GH_TIMEOUT + LINK_SLACK).as_millis() as u64
}

/// The Mac's check of a deadline at `now_ms`: refused when `gh` could still be running after it
/// (the request came late, after a stalled or sleeping link, or the clocks differ).
fn check_deadline(deadline: Option<u64>, now_ms: u64) -> Result<(), RpcError> {
    let deadline = deadline.ok_or_else(|| invalid("deadlineMs is required"))?;
    let run = GH_TIMEOUT.as_millis() as u64;
    if now_ms + run > deadline {
        let late = format!(
            "the request reached the Mac too late to run (over {}s after this machine sent it, \
             or the two clocks differ by that much); nothing was done",
            LINK_SLACK.as_secs()
        );
        return Err(RpcError::new(-32043, late).with_data(json!({"reason": "github.expired"})));
    }
    if deadline > now_ms + run + 2 * LINK_SLACK.as_millis() as u64 {
        return Err(invalid("deadlineMs is further ahead than an action waits"));
    }
    Ok(())
}

fn invalid(message: impl Into<String>) -> RpcError {
    RpcError::invalid_params(message.into())
}

fn denied(message: impl Into<String>) -> RpcError {
    RpcError::new(-32040, message.into()).with_data(json!({"reason": "github.denied"}))
}

fn bounded_text(field: &str, value: Option<&str>) -> Result<(), RpcError> {
    match value {
        Some(v) if v.is_empty() || v.len() > TEXT_MAX || v.contains('\0') => {
            Err(invalid(format!("{field} must be 1..{TEXT_MAX} bytes without NUL")))
        }
        _ => Ok(()),
    }
}

fn valid_repo(repo: &str) -> bool {
    let Some((owner, name)) = repo.split_once('/') else { return false };
    // `repo view` takes it as a positional: a leading `-` would read as a flag.
    !owner.is_empty()
        && !owner.starts_with('-')
        && !name.is_empty()
        && repo.len() <= REPO_MAX
        && owner.bytes().all(|c| c.is_ascii_alphanumeric() || c == b'-' || c == b'_')
        && name.bytes().all(|c| c.is_ascii_alphanumeric() || matches!(c, b'-' | b'_' | b'.'))
        && name != "."
        && name != ".."
}

fn valid_branch(branch: &str) -> bool {
    !branch.is_empty()
        && branch.len() <= 256
        && !branch.starts_with('-')
        && !branch.starts_with('/')
        && !branch.ends_with('/')
        && !branch.ends_with(".lock")
        && !branch.contains("..")
        && !branch.contains("//")
        && !branch.contains("@{")
        // `gh pr create --head owner:branch` names a fork's branch.
        && !branch.contains(':')
        && branch.bytes().all(|c| c.is_ascii_graphic() && !b"\\~^?*[".contains(&c))
}

/// Check one request completely, with no I/O. The lane runs it before anything is sent or
/// recorded (an event row holds only checked strings), and the Mac runs it again: the Mac
/// trusts nothing the lane sends.
pub fn validate(r: &GithubActionParams) -> Result<(), RpcError> {
    if let Some(id) = r.session_id.as_deref()
        && (id.is_empty() || id.len() > 256 || !id.bytes().all(|b| b.is_ascii_graphic()))
    {
        return Err(invalid("sessionId must be 1..256 printable ASCII characters"));
    }
    if !valid_repo(&r.repo) {
        return Err(invalid("repo must be an owner/name GitHub repository"));
    }
    for (field, value) in [("branch", &r.branch), ("base", &r.base)] {
        if value.as_deref().is_some_and(|b| !valid_branch(b)) {
            return Err(invalid(format!("{field} is not a valid branch name")));
        }
    }
    // Each action takes exactly its own fields, so nothing reaches `gh` that its command ignores.
    let (needs, allows): (&[&str], &[&str]) = match r.action {
        GithubAction::Read => (&[], &["issue"]),
        GithubAction::Issue => (&["title"], &["body"]),
        GithubAction::Comment => (&["issue", "body"], &[]),
        GithubAction::DraftPr => (&["branch", "title"], &["base", "body"]),
    };
    let given = [
        ("branch", r.branch.is_some()),
        ("base", r.base.is_some()),
        ("issue", r.issue.is_some()),
        ("title", r.title.is_some()),
        ("body", r.body.is_some()),
    ];
    for (field, present) in given {
        if present && !needs.contains(&field) && !allows.contains(&field) {
            return Err(invalid(format!("{field} is not used by {}", r.action.name())));
        }
        if !present && needs.contains(&field) {
            return Err(invalid(format!("{field} is required for {}", r.action.name())));
        }
    }
    if r.issue.is_some_and(|n| !(1..=1_000_000_000).contains(&n)) {
        return Err(invalid("issue must be a positive number"));
    }
    bounded_text("title", r.title.as_deref())?;
    bounded_text("body", r.body.as_deref())
}

/// The fixed `gh` command for a request `validate` accepted. Every caller value goes as
/// `--flag=value`, so none can read as a flag of its own whatever it starts with.
pub fn gh_args(r: &GithubActionParams) -> Vec<String> {
    let opt = |flag: &str, v: &Option<String>| format!("{flag}={}", v.as_deref().unwrap_or(""));
    let n = r.issue.unwrap_or_default().to_string();
    let repo = format!("--repo={}", r.repo);
    let mut a: Vec<String> = match (r.action, r.issue) {
        (GithubAction::Read, None) => {
            let fields = "--json=nameWithOwner,url,defaultBranchRef,visibility";
            ["repo", "view", &r.repo, fields].map(String::from).to_vec()
        }
        (GithubAction::Read, Some(_)) => {
            let fields = "--json=number,title,state,isDraft,url,headRefName,baseRefName";
            ["pr", "view", &n, fields, &repo].map(String::from).to_vec()
        }
        (GithubAction::Issue, _) => {
            vec!["issue".into(), "create".into(), opt("--title", &r.title), opt("--body", &r.body)]
        }
        (GithubAction::Comment, _) => {
            vec!["issue".into(), "comment".into(), n, opt("--body", &r.body)]
        }
        (GithubAction::DraftPr, _) => vec![
            "pr".into(),
            "create".into(),
            "--draft".into(),
            opt("--head", &r.branch),
            opt("--title", &r.title),
            opt("--body", &r.body),
        ],
    };
    if r.action == GithubAction::DraftPr && r.base.is_some() {
        a.push(opt("--base", &r.base));
    }
    if matches!(r.action, GithubAction::Issue | GithubAction::Comment | GithubAction::DraftPr) {
        a.push(repo);
    }
    a
}

/// `gh`'s output as text: every GitHub token cut out (`redact_github_tokens`), then at most
/// `OUTPUT_MAX` bytes.
fn clean_output(bytes: &[u8]) -> String {
    // Cut out tokens first: `[redacted]` is longer than the shortest token, so cutting to the
    // limit before would let the output grow past it.
    let mut out = redact_github_tokens(&String::from_utf8_lossy(bytes));
    if out.len() > OUTPUT_MAX {
        let mut end = OUTPUT_MAX;
        while !out.is_char_boundary(end) {
            end -= 1;
        }
        out.truncate(end);
        out.push('…');
    }
    out
}

/// GitHub token prefixes: classic and fine-grained personal, OAuth, user-to-server,
/// server-to-server (App installation) and refresh tokens.
const TOKEN_PREFIXES: [&str; 6] = ["github_pat_", "ghp_", "gho_", "ghu_", "ghs_", "ghr_"];

/// `text` with every GitHub token in it (one of `TOKEN_PREFIXES` at the start of a word, whole
/// or cut off) replaced by `[redacted]`: whatever `gh` prints (a debug setting, a wrapper), no
/// token goes back to the machine.
pub(crate) fn redact_github_tokens(text: &str) -> String {
    let word = |c: char| c.is_ascii_alphanumeric() || c == '_';
    let mut out = String::with_capacity(text.len());
    let mut rest = text;
    let mut after_word = false;
    while let Some(c) = rest.chars().next() {
        let prefix = TOKEN_PREFIXES.iter().find(|p| !after_word && rest.starts_with(**p));
        if let Some(prefix) = prefix {
            let tail = &rest[prefix.len()..];
            let end = tail.find(|c: char| !word(c)).unwrap_or(tail.len());
            out.push_str("[redacted]");
            rest = &tail[end..];
            after_word = true;
            continue;
        }
        out.push(c);
        after_word = word(c);
        rest = &rest[c.len_utf8()..];
    }
    out
}

/// What one decision records: never the title, body or output.
pub fn audit_payload(r: &GithubActionParams, status: &str, error: Option<&RpcError>) -> Value {
    json!({
        "action": r.action.name(),
        "repo": r.repo,
        "branch": r.branch,
        "issue": r.issue,
        "status": status,
        "error": error.map(|e| json!({"code": e.code})),
    })
}

/// Read at most `STREAM_READ_MAX` of one pipe, then drain the rest so the child never blocks.
async fn read_bounded<R: tokio::io::AsyncRead + Unpin>(pipe: Option<R>) -> Vec<u8> {
    use tokio::io::AsyncReadExt;
    let Some(mut pipe) = pipe else { return Vec::new() };
    let mut kept = Vec::new();
    if (&mut pipe).take(STREAM_READ_MAX).read_to_end(&mut kept).await.is_ok() {
        let _ = tokio::io::copy(&mut pipe, &mut tokio::io::sink()).await;
    }
    kept
}

/// Run the fixed `gh` command for a checked request on this machine, with its own login.
async fn execute(r: &GithubActionParams) -> Result<String, RpcError> {
    let mut gh = Command::new("gh");
    gh.args(gh_args(r));
    login_env(gh.as_std_mut(), None);
    let mut child = gh
        .stdin(std::process::Stdio::null())
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::piped())
        .kill_on_drop(true)
        .spawn()
        .map_err(|e| RpcError::internal(format!("could not start gh on the Mac: {e}")))?;
    let (stdout, stderr) = (child.stdout.take(), child.stderr.take());
    let run = async {
        let (out, err, status) =
            tokio::join!(read_bounded(stdout), read_bounded(stderr), child.wait());
        status.map(|status| (status, out, err))
    };
    let (status, stdout, stderr) = tokio::time::timeout(GH_TIMEOUT, run)
        .await
        .map_err(|_| {
            RpcError::internal(format!("gh did not finish within {}s", GH_TIMEOUT.as_secs()))
        })?
        .map_err(|e| RpcError::internal(format!("lost gh: {e}")))?;
    if !status.success() {
        return Err(RpcError::new(
            -32041,
            format!("GitHub refused the action: {}", clean_output(&stderr)),
        )
        .with_data(json!({"reason": "github.command_failed"})));
    }
    Ok(clean_output(&stdout))
}

/// The env every `gh` the broker runs gets: only the Mac's keyring login (`token` None: every
/// GitHub token in this daemon's env removed, so `keyring` means the keyring), or only `token`;
/// github.com whatever `GH_HOST` the daemon has.
pub(crate) fn login_env(gh: &mut std::process::Command, token: Option<&str>) {
    gh.env(SHIM_REFUSAL_ENV, "1")
        .env("GH_PROMPT_DISABLED", "1")
        .env("GH_NO_UPDATE_NOTIFIER", "1")
        .env("GH_HOST", "github.com")
        // `gh` prints its HTTP traffic with these set; it has no business doing so here.
        .env_remove("GH_DEBUG")
        .env_remove("DEBUG")
        .env_remove("GH_TOKEN")
        .env_remove("GITHUB_TOKEN")
        .env_remove("GH_ENTERPRISE_TOKEN")
        .env_remove("GITHUB_ENTERPRISE_TOKEN");
    if let Some(token) = token {
        gh.env("GH_TOKEN", token);
    }
}

/// The Mac's gate for `peer`'s request, before anything is spawned: `enabled` is that peer's
/// saved `githubBroker`, and `slots` bound how many of its actions run at once.
pub fn admit_owner(
    peer: &str,
    enabled: bool,
    slots: &Arc<tokio::sync::Semaphore>,
) -> Result<tokio::sync::OwnedSemaphorePermit, RpcError> {
    if !enabled {
        tracing::warn!(peer, "github broker: refused a request from a peer it is off for");
        return Err(denied("this Mac does not lend its GitHub login to this machine"));
    }
    slots.clone().try_acquire_owned().map_err(|_| {
        RpcError::new(-32000, "too many GitHub actions from this machine at once")
            .with_data(json!({"reason": "github.busy", "retryable": true}))
    })
}

/// The Mac's side, once `admit_owner` let `peer`'s request in: check it again (the Mac trusts
/// nothing the lane sends) and run it.
pub async fn serve_owner(peer: &str, params: Value) -> Result<Value, RpcError> {
    let request: GithubActionParams = serde_json::from_value(params)
        .map_err(|e| invalid(format!("invalid GitHub action: {e}")))?;
    validate(&request)?;
    check_deadline(request.deadline_ms, crate::store::now_ms())?;
    let result = execute(&request).await;
    let session = request.session_id.as_deref().unwrap_or("-");
    let status = if result.is_ok() { "allowed" } else { "failed" };
    let row = audit_payload(&request, status, result.as_ref().err());
    tracing::info!(peer, session, "github broker: {row}");
    Ok(json!({"action": request.action, "repo": request.repo, "output": result?}))
}

/// The lane's side: an agent session asked over the unix socket (`remote_guard.rs` refuses
/// every other origin).
pub async fn handle(
    hub: &Arc<crate::hub::Hub>,
    conn: &Arc<crate::server::Conn>,
    params: Value,
) -> Result<Value, RpcError> {
    if conn.origin != crate::server::Origin::Local {
        return Err(denied("GitHub actions are asked over this machine's unix socket only"));
    }
    let mut request: GithubActionParams = serde_json::from_value(params)
        .map_err(|e| invalid(format!("invalid GitHub action: {e}")))?;
    let session = conn
        .caller()
        .ok_or_else(|| {
            denied("GitHub actions are for an acpmux session's agent (run it inside one)")
        })?
        .to_owned();
    request.session_id = Some(session.clone());
    validate(&request)?;
    let session = hub.resolve(&session)?;
    let record = |status: &str, error: Option<&RpcError>| {
        hub.append_github_audit(&session, audit_payload(&request, status, error));
    };
    let Some(owner) = hub.github_owner_link() else {
        let error = RpcError::new(
            -32042,
            "no Mac that lends GitHub to this machine is connected (add this machine from the Mac with Add Machine)",
        )
        .with_data(json!({"reason": "github.no_owner"}));
        record("unavailable", Some(&error));
        return Err(error);
    };
    // The Mac starts nothing it could not finish before this machine stops waiting.
    let mut wire = request.clone();
    wire.deadline_ms = Some(deadline_from(crate::store::now_ms()));
    let wire = serde_json::to_value(&wire).map_err(|e| RpcError::internal(e.to_string()))?;
    let budget = LANE_WAIT;
    let reply = owner.request_client(crate::rpc::method::MUX_GITHUB_ACTION, wire, budget).await;
    match &reply {
        Ok(_) => record("allowed", None),
        Err(e) if e.code == -32040 => record("denied", Some(e)),
        Err(e) => record("failed", Some(e)),
    }
    reply
}

#[cfg(test)]
#[path = "github_broker_tests.rs"]
mod tests;
