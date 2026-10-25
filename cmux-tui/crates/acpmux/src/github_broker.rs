//! Scoped GitHub actions performed by the owner's daemon.
//!
//! The peer sends an action description, never a token. The daemon executes
//! the corresponding fixed `gh` command using the owner's existing keyring
//! and returns a bounded result. Policy is checked before a subprocess is
//! started; a policy entry can never create an arbitrary command.

use crate::config::github_broker::GithubBrokerConfig;
use crate::rpc::RpcError;
use hmac::{Hmac, Mac};
use schemars::JsonSchema;
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use std::collections::HashMap;
use std::path::Path;
use std::sync::Arc;
use std::sync::{Mutex, OnceLock};
use std::time::{SystemTime, UNIX_EPOCH};
use tokio::process::Command;

type HmacSha256 = Hmac<sha2::Sha256>;

const REPO_MAX: usize = 140;
const TEXT_MAX: usize = 64 * 1024;
const OUTPUT_MAX: usize = 64 * 1024;
/// How far `issuedAt` may be from the owner's clock. The signed timestamp is
/// what makes the replay guard both bounded and safe: a captured request is
/// refused once it leaves this window, so a spent id older than the window can
/// be dropped without reopening the replay it was recorded to stop.
const REQUEST_FRESHNESS_SECS: u64 = 120;
/// Spent ids are kept for twice the freshness window, so an id is always still
/// on record for as long as its request could be accepted on either clock.
const SPENT_REQUESTS_MAX: usize = 8192;
/// requestId -> when the owner first saw it, by the owner's clock. Never the
/// caller's `issuedAt`: a caller must not be able to influence when its own id
/// is forgotten.
static SPENT_REQUESTS: OnceLock<Mutex<HashMap<String, u64>>> = OnceLock::new();
/// A brokered `gh` is one bounded API call; it never waits for a person.
const GH_TIMEOUT: std::time::Duration = std::time::Duration::from_secs(60);
/// An owner policy is a small JSON document.
const POLICY_MAX: u64 = 1024 * 1024;
/// How much of a stream is read before the rest is dropped. `gh`'s own output
/// is far smaller; this only bounds a `gh` that will not stop talking, so its
/// output cannot grow the daemon's memory for as long as `GH_TIMEOUT` allows.
const STREAM_READ_MAX: u64 = 2 * OUTPUT_MAX as u64;
/// The owner daemon sets this on the `gh` it runs, and the peer shim refuses
/// to start with it set, so the shim can never be the `gh` the owner calls.
pub const SHIM_REFUSAL_ENV: &str = "ACPMUX_GITHUB_BROKER_OWNER";

#[derive(Debug, Clone, Copy, Serialize, Deserialize, JsonSchema, PartialEq, Eq)]
#[serde(rename_all = "snake_case")]
pub enum GithubAction {
    Read,
    Issue,
    Comment,
    DraftPr,
    Push,
}

impl GithubAction {
    pub fn policy_name(self) -> &'static str {
        match self {
            Self::Read => "read",
            Self::Issue => "issue",
            Self::Comment => "comment",
            Self::DraftPr => "draft_pr",
            Self::Push => "push",
        }
    }

    fn needs_branch(self) -> bool {
        matches!(self, Self::DraftPr | Self::Push)
    }
}

#[derive(Debug, Clone, Serialize, Deserialize, JsonSchema, PartialEq, Eq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct GithubActionParams {
    /// The remote session that owns this request. It is always required,
    /// including for a local owner call, so audit rows have a stable subject.
    pub session_id: String,
    /// One-time action id. It prevents a captured peer request from being
    /// replayed against the owner's identity.
    pub request_id: String,
    /// Unix seconds when the caller built this request. It is covered by the
    /// peer proof, so a captured request expires (`REQUEST_FRESHNESS_SECS`)
    /// instead of staying replayable for as long as the daemon runs.
    pub issued_at: u64,
    pub action: GithubAction,
    pub repo: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub branch: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub base: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub head_sha: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub issue: Option<u64>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub title: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub body: Option<String>,
    /// Set only by acpmux while forwarding to the configured owner peer.
    #[serde(default)]
    pub forwarded: bool,
    /// The lane identity and proof checked by the owner daemon. They are
    /// capabilities, never GitHub credentials.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub peer_id: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub peer_proof: Option<String>,
}

#[derive(Debug, Clone, Serialize, Deserialize, JsonSchema, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub struct GithubActionResult {
    pub action: GithubAction,
    pub repo: String,
    pub session_id: String,
    pub output: String,
}

#[derive(Debug, Clone)]
pub struct AuthorizedGithubAction {
    pub request: GithubActionParams,
}

fn invalid(message: impl Into<String>) -> RpcError {
    RpcError::invalid_params(message.into())
}

fn denied(message: impl Into<String>) -> RpcError {
    RpcError::new(-32040, message.into()).with_data(json!({"reason": "github.policy_denied"}))
}

fn bounded_text(field: &str, value: &str) -> Result<(), RpcError> {
    if value.is_empty() || value.len() > TEXT_MAX || value.bytes().any(|b| b == 0) {
        return Err(invalid(format!("{field} must be 1..{TEXT_MAX} bytes without NUL")));
    }
    Ok(())
}

fn valid_repo(repo: &str) -> bool {
    let Some((owner, name)) = repo.split_once('/') else { return false };
    !owner.is_empty()
        && !name.is_empty()
        && repo.len() <= REPO_MAX
        && owner.bytes().all(|c| c.is_ascii_alphanumeric() || c == b'-' || c == b'_')
        && name.bytes().all(|c| c.is_ascii_alphanumeric() || matches!(c, b'-' | b'_' | b'.'))
}

fn valid_branch(branch: &str) -> bool {
    !branch.is_empty()
        && branch.len() <= 256
        && !branch.starts_with('-')
        && !branch.contains("..")
        && !branch.contains("//")
        && !branch.contains('@')
        // `gh pr create --head owner:branch` means a fork's branch, so a `:`
        // would carry the real branch past the policy's prefix check: with
        // `agent-` granted, `agent-x:main` is branch `main` on fork `agent-x`.
        && !branch.contains(':')
        && branch.bytes().all(|c| c.is_ascii_graphic() && c != b'\\')
}

/// Check the request's own shape, with no policy and no I/O. It runs before
/// anything is recorded, so an audit row can never carry an unbounded or
/// control-character string a caller invented (the rows are shown verbatim in
/// the agent pane).
pub fn validate_shape(request: &GithubActionParams) -> Result<(), RpcError> {
    if request.session_id.len() > 256
        || request.session_id.is_empty()
        || !request.session_id.bytes().all(|b| b.is_ascii_graphic() || b == b' ')
    {
        return Err(invalid("sessionId must be 1..256 printable ASCII characters"));
    }
    if !valid_repo(&request.repo) {
        return Err(invalid("repo must be an owner/name GitHub repository"));
    }
    if let Some(branch) = request.branch.as_deref()
        && !valid_branch(branch)
    {
        return Err(invalid("branch is not a valid Git branch"));
    }
    if let Some(base) = request.base.as_deref()
        && !valid_branch(base)
    {
        return Err(invalid("base is not a valid Git branch"));
    }
    Ok(())
}

impl AuthorizedGithubAction {
    pub fn authorize(
        config: &GithubBrokerConfig,
        request: GithubActionParams,
    ) -> Result<Self, RpcError> {
        if !config.enabled {
            return Err(denied("GitHub broker is disabled"));
        }
        validate_shape(&request)?;
        bounded_text("sessionId", &request.session_id)?;
        let Some(session_policy) = config.policy_for(&request.session_id) else {
            return Err(denied("session is not allowed to use the GitHub broker"));
        };
        let Some(repo_policy) = session_policy.repos.get(&request.repo) else {
            return Err(denied("repository is not allowed by the GitHub broker policy"));
        };
        if !repo_policy.actions.contains(request.action.policy_name()) {
            return Err(denied(format!(
                "action {} is not allowed for this repository",
                request.action.policy_name()
            )));
        }
        if request.action.needs_branch() {
            let Some(branch) = request.branch.as_deref() else {
                return Err(invalid("branch is required for this GitHub action"));
            };
            if !repo_policy
                .branch_prefixes
                .iter()
                .any(|prefix| !prefix.is_empty() && branch.starts_with(prefix))
            {
                return Err(denied("branch is outside the policy's allowed prefixes"));
            }
        }
        match request.action {
            GithubAction::Issue | GithubAction::DraftPr => {
                let title = request.title.as_deref().ok_or_else(|| invalid("title is required"))?;
                bounded_text("title", title)?;
                if let Some(body) = request.body.as_deref() {
                    bounded_text("body", body)?;
                }
            }
            GithubAction::Comment => {
                if request.issue.is_none_or(|issue| issue == 0 || issue > 1_000_000_000) {
                    return Err(invalid("issue is required for a comment"));
                }
                bounded_text(
                    "body",
                    request.body.as_deref().ok_or_else(|| invalid("body is required"))?,
                )?;
            }
            GithubAction::Push => {
                let sha = request
                    .head_sha
                    .as_deref()
                    .ok_or_else(|| invalid("headSha is required for push"))?;
                if sha.len() < 7 || sha.len() > 64 || !sha.bytes().all(|c| c.is_ascii_hexdigit()) {
                    return Err(invalid("headSha must be a hexadecimal commit id"));
                }
            }
            GithubAction::Read => {}
        }
        Ok(Self { request })
    }

    fn gh_args(&self) -> Vec<String> {
        let r = &self.request;
        match r.action {
            GithubAction::Read => {
                if let Some(issue) = r.issue {
                    vec![
                        "pr".into(),
                        "view".into(),
                        issue.to_string(),
                        "--repo".into(),
                        r.repo.clone(),
                        "--json".into(),
                        "number,title,state,isDraft,url,headRefName,baseRefName".into(),
                    ]
                } else {
                    vec![
                        "repo".into(),
                        "view".into(),
                        r.repo.clone(),
                        "--json".into(),
                        "nameWithOwner,url,defaultBranchRef".into(),
                    ]
                }
            }
            GithubAction::Issue => {
                let mut a = vec![
                    "issue".into(),
                    "create".into(),
                    "--repo".into(),
                    r.repo.clone(),
                    "--title".into(),
                    r.title.clone().unwrap_or_default(),
                ];
                if let Some(body) = &r.body {
                    a.extend(["--body".into(), body.clone()]);
                }
                a
            }
            GithubAction::Comment => vec![
                "issue".into(),
                "comment".into(),
                r.issue.unwrap_or_default().to_string(),
                "--repo".into(),
                r.repo.clone(),
                "--body".into(),
                r.body.clone().unwrap_or_default(),
            ],
            GithubAction::DraftPr => {
                let mut a = vec![
                    "pr".into(),
                    "create".into(),
                    "--draft".into(),
                    "--repo".into(),
                    r.repo.clone(),
                    "--head".into(),
                    r.branch.clone().unwrap_or_default(),
                    "--title".into(),
                    r.title.clone().unwrap_or_default(),
                ];
                if let Some(base) = &r.base {
                    a.extend(["--base".into(), base.clone()]);
                }
                if let Some(body) = &r.body {
                    a.extend(["--body".into(), body.clone()]);
                }
                a
            }
            // The commit must already exist in the owner's repository object
            // database. No credential or arbitrary ref is returned to peers.
            GithubAction::Push => vec![
                "api".into(),
                "--method".into(),
                "POST".into(),
                format!("repos/{}/git/refs", r.repo),
                "-f".into(),
                format!("ref=refs/heads/{}", r.branch.clone().unwrap_or_default()),
                "-f".into(),
                format!("sha={}", r.head_sha.clone().unwrap_or_default()),
            ],
        }
    }
}

fn sign_request(request: &GithubActionParams, secret: &str) -> Result<String, RpcError> {
    if secret.len() < 32 || secret.len() > 4096 {
        return Err(RpcError::invalid_params("GitHub broker peer secret must be 32..4096 bytes"));
    }
    let mut unsigned = request.clone();
    unsigned.peer_proof = None;
    let bytes = serde_json::to_vec(&unsigned).map_err(|e| RpcError::internal(e.to_string()))?;
    let mut mac = HmacSha256::new_from_slice(secret.as_bytes())
        .map_err(|_| RpcError::internal("invalid GitHub broker peer secret"))?;
    mac.update(&bytes);
    Ok(mac.finalize().into_bytes().iter().map(|b| format!("{b:02x}")).collect())
}

fn verify_peer_capability(
    request: &GithubActionParams,
    config: &GithubBrokerConfig,
) -> Result<(), RpcError> {
    let peer_secrets = &config.peer_secrets;
    let peer_id = request
        .peer_id
        .as_deref()
        .ok_or_else(|| denied("GitHub broker peer identity is missing"))?;
    if peer_id.is_empty()
        || peer_id.len() > 128
        || !peer_id.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'-' || b == b'_')
    {
        return Err(denied("GitHub broker peer identity is invalid"));
    }
    let proof = request
        .peer_proof
        .as_deref()
        .ok_or_else(|| denied("GitHub broker peer proof is missing"))?;
    if proof.len() != 64 || !proof.bytes().all(|b| b.is_ascii_hexdigit()) {
        return Err(denied("GitHub broker peer proof is invalid"));
    }
    let secret =
        peer_secrets.get(peer_id).ok_or_else(|| denied("GitHub broker peer is not authorized"))?;
    let expected = sign_request(request, secret)?;
    if expected.len() != proof.len() || !cmux_local_auth::tokens_match(&expected, proof) {
        return Err(denied("GitHub broker peer proof is invalid"));
    }
    // A valid secret proves which lane sent the request, not which session it
    // may act for. Without this, a lane holding its own secret could sign a
    // request naming another lane's session and borrow that session's grants.
    if config.policy_for(&request.session_id).and_then(|p| p.peer.as_deref()) != Some(peer_id) {
        return Err(denied("GitHub broker peer may not act for this session"));
    }
    Ok(())
}

fn unix_now() -> u64 {
    SystemTime::now().duration_since(UNIX_EPOCH).map(|d| d.as_secs()).unwrap_or_default()
}

/// Spend one request id. The id is recorded only after `issuedAt` proves the
/// request is current, so the owner can forget ids the freshness window has
/// already made unusable and the guard stays bounded without ever letting an
/// evicted id through a second time.
fn consume_request(request_id: &str, issued_at: u64, now: u64) -> Result<(), RpcError> {
    let spent = SPENT_REQUESTS.get_or_init(|| Mutex::new(HashMap::new()));
    let mut spent = spent.lock().unwrap_or_else(|poisoned| poisoned.into_inner());
    spend(&mut spent, request_id, issued_at, now)
}

fn spend(
    spent: &mut HashMap<String, u64>,
    request_id: &str,
    issued_at: u64,
    now: u64,
) -> Result<(), RpcError> {
    if request_id.is_empty()
        || request_id.len() > 128
        || !request_id.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'-' || b == b'_')
    {
        return Err(invalid("requestId must be 1..128 ASCII identifier characters"));
    }
    if issued_at.abs_diff(now) > REQUEST_FRESHNESS_SECS {
        return Err(denied(format!(
            "GitHub broker request is outside the {REQUEST_FRESHNESS_SECS}s freshness window"
        )));
    }
    // Retention is measured from the owner's own first sight of an id, never
    // from the caller's `issuedAt`: a caller that could rewrite the stored
    // time could retire its own id early and replay the original request.
    spent.retain(|_, first_seen| now.saturating_sub(*first_seen) <= REQUEST_FRESHNESS_SECS * 2);
    if spent.len() >= SPENT_REQUESTS_MAX {
        // Only a flood inside one window reaches this: fail closed rather than
        // evict an id that a captured request could still be replayed with.
        return Err(RpcError::internal("GitHub broker replay guard is saturated"));
    }
    match spent.entry(request_id.to_owned()) {
        // A duplicate leaves the recorded time untouched.
        std::collections::hash_map::Entry::Occupied(_) => {
            Err(denied("GitHub broker request has already been used"))
        }
        std::collections::hash_map::Entry::Vacant(slot) => {
            slot.insert(now);
            Ok(())
        }
    }
}

fn validate_peer_secrets(
    secrets: &std::collections::BTreeMap<String, String>,
) -> Result<(), RpcError> {
    for (id, secret) in secrets {
        if id.is_empty()
            || id.len() > 128
            || !id.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'-' || b == b'_')
            || secret.len() < 32
            || secret.len() > 4096
        {
            return Err(RpcError::invalid_params(
                "GitHub broker peerSecrets contains an invalid id or secret",
            ));
        }
    }
    Ok(())
}

fn clean_output(bytes: &[u8]) -> String {
    let mut out = String::from_utf8_lossy(bytes).into_owned();
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

/// Record one decision. The session's event stream is the surface the app
/// shows, but on the owner daemon a forwarded request names a session that
/// lives on the lane, so `append_github_audit` legitimately finds nothing. The
/// owner must still have its own record of what was done with its credential,
/// so a row that cannot be appended is logged instead of dropped.
fn audit(hub: &Arc<crate::hub::Hub>, request: &GithubActionParams, payload: Value) {
    if hub.append_github_audit(&request.session_id, payload.clone()).is_ok() {
        return;
    }
    tracing::warn!(
        session = %request.session_id,
        peer = request.peer_id.as_deref().unwrap_or("-"),
        forwarded = request.forwarded,
        "github broker: {payload}"
    );
}

pub fn audit_payload(
    request: &GithubActionParams,
    result: Result<&GithubActionResult, &RpcError>,
) -> Value {
    let (status, error) = match result {
        Ok(_) => ("allowed", Value::Null),
        Err(e) => (if e.code == -32040 { "denied" } else { "failed" }, json!({"code": e.code})),
    };
    json!({
        "sessionId": request.session_id,
        "action": request.action.policy_name(),
        "repo": request.repo,
        "branch": request.branch,
        "status": status,
        "error": error,
    })
}

/// Read at most `STREAM_READ_MAX` from one of the child's pipes, draining it
/// so the child is never blocked on a full pipe, and dropping the rest.
async fn read_bounded<R>(pipe: &mut Option<R>) -> Vec<u8>
where
    R: tokio::io::AsyncRead + Unpin,
{
    use tokio::io::AsyncReadExt;
    let Some(pipe) = pipe.as_mut() else { return Vec::new() };
    let mut kept = Vec::new();
    if tokio::io::AsyncReadExt::take(&mut *pipe, STREAM_READ_MAX)
        .read_to_end(&mut kept)
        .await
        .is_err()
    {
        return kept;
    }
    // Whatever is past the cap is read and thrown away rather than left to
    // block the child.
    let mut sink = tokio::io::sink();
    let _ = tokio::io::copy(pipe, &mut sink).await;
    kept
}

pub async fn execute(action: AuthorizedGithubAction) -> Result<GithubActionResult, RpcError> {
    let request = &action.request;
    let args = action.gh_args();
    let mut child = Command::new("gh")
        .args(&args)
        // The shim is named `acpmux-gh`, so it is not what a bare `gh` finds.
        // This marker is the second line of defence: the shim refuses to start
        // with it set, so a shim deliberately installed as `gh` cannot recurse
        // into the daemon that called it. A wrapper that strips the marker can
        // still stand in for `gh`, as anything on the owner's PATH can; the
        // marker narrows an accident, it is not an identity check.
        .env(SHIM_REFUSAL_ENV, "1")
        .env("GH_PROMPT_DISABLED", "1")
        .env("GH_NO_UPDATE_NOTIFIER", "1")
        .stdin(std::process::Stdio::null())
        .stdout(std::process::Stdio::piped())
        .stderr(std::process::Stdio::piped())
        // A `gh` left running must not outlive the request that started it.
        .kill_on_drop(true)
        .spawn()
        .map_err(|e| RpcError::internal(format!("GitHub broker could not start gh: {e}")))?;
    // Read both streams bounded and concurrently: unbounded buffering would
    // let a `gh` that will not stop talking grow the daemon's memory for the
    // whole timeout, and reading them one after the other would let a full
    // pipe on the other stream stall the child.
    let mut stdout_pipe = child.stdout.take();
    let mut stderr_pipe = child.stderr.take();
    let collect = async {
        let (out, err, status) = tokio::join!(
            read_bounded(&mut stdout_pipe),
            read_bounded(&mut stderr_pipe),
            child.wait(),
        );
        status.map(|status| (status, out, err))
    };
    let (status, stdout, stderr) = match tokio::time::timeout(GH_TIMEOUT, collect).await {
        Ok(result) => {
            result.map_err(|e| RpcError::internal(format!("GitHub broker lost gh: {e}")))?
        }
        Err(_) => {
            // `kill_on_drop` ends the child itself; a wrapper's own children
            // are its business, as they are for every other spawn here.
            return Err(RpcError::internal(format!(
                "GitHub action did not finish within {}s",
                GH_TIMEOUT.as_secs()
            )));
        }
    };
    let output = std::process::Output { status, stdout, stderr };
    if !output.status.success() {
        // `gh`'s own diagnostics go back to the caller so a denied or broken
        // action is debuggable, bounded and with no owner path in it.
        return Err(RpcError::new(
            -32041,
            format!("GitHub action failed: {}", clean_output(&output.stderr)),
        )
        .with_data(json!({"reason": "github.command_failed"})));
    }
    Ok(GithubActionResult {
        action: request.action,
        repo: request.repo.clone(),
        session_id: request.session_id.clone(),
        output: clean_output(&output.stdout),
    })
}

pub fn load_policy(config: &GithubBrokerConfig) -> Result<GithubBrokerConfig, RpcError> {
    let Some(path) = config.policy_path.as_deref() else {
        validate_peer_secrets(&config.peer_secrets)?;
        return Ok(config.clone());
    };
    let text = read_policy_file(path)?;
    let mut from_file: GithubBrokerConfig = serde_json::from_str(&text).map_err(|e| {
        RpcError::invalid_params(format!("parse GitHub broker policy {}: {e}", path.display()))
    })?;
    from_file.enabled = config.enabled;
    from_file.owner_peer = config.owner_peer.clone();
    from_file.policy_path = config.policy_path.clone();
    from_file.peer_id = config.peer_id.clone();
    from_file.peer_secret = config.peer_secret.clone();
    validate_peer_secrets(&from_file.peer_secrets)?;
    Ok(from_file)
}

fn unreadable_policy(path: &Path, cause: impl std::fmt::Display) -> RpcError {
    RpcError::internal(format!("read GitHub broker policy {}: {cause}", path.display()))
}

/// Read the owner-only policy. The ownership and mode are checked on the open
/// file descriptor, not on the path, so the file that was vetted is the file
/// that is read; `O_NOFOLLOW` keeps a symlink from standing in for it.
#[cfg(unix)]
fn read_policy_file(path: &Path) -> Result<String, RpcError> {
    use std::fs::OpenOptions;
    use std::io::Read;
    use std::os::unix::fs::{MetadataExt, OpenOptionsExt, PermissionsExt};

    let mut file = OpenOptions::new()
        .read(true)
        // O_NOFOLLOW keeps a symlink from standing in for the file. O_NONBLOCK
        // is what makes the open itself safe: without it, a policy_path naming
        // a FIFO would block here until someone opened the write end, and the
        // caller holds the config read lock across this call. On a regular
        // file, which is all the check below accepts, O_NONBLOCK does nothing.
        .custom_flags(libc::O_NOFOLLOW | libc::O_NONBLOCK)
        .open(path)
        .map_err(|e| unreadable_policy(path, e))?;
    let metadata = file.metadata().map_err(|e| unreadable_policy(path, e))?;
    if !metadata.file_type().is_file()
        || metadata.uid() != unsafe { libc::getuid() }
        || metadata.permissions().mode() & 0o077 != 0
    {
        return Err(RpcError::invalid_params(format!(
            "GitHub broker policy {} must be an owner-only regular file",
            path.display()
        )));
    }
    if metadata.len() > POLICY_MAX {
        return Err(RpcError::invalid_params(format!(
            "GitHub broker policy {} is larger than {POLICY_MAX} bytes",
            path.display()
        )));
    }
    let mut text = String::new();
    file.read_to_string(&mut text).map_err(|e| unreadable_policy(path, e))?;
    Ok(text)
}

/// There is no owner-only check to make here, so the broker does not run: a
/// policy read without the ownership and mode checks would quietly drop the
/// guarantee the owner-only file is supposed to give.
#[cfg(not(unix))]
fn read_policy_file(_path: &Path) -> Result<String, RpcError> {
    Err(RpcError::invalid_params(
        "the GitHub broker policy file is supported only where its owner-only mode can be checked",
    ))
}

/// Handle the peer-facing RPC. A lane daemon with `ownerPeer` set forwards
/// over its already-authenticated acpmux link; the owner daemon executes the
/// fixed command locally. No token is present in either request or response.
pub async fn handle(
    hub: &Arc<crate::hub::Hub>,
    conn: &Arc<crate::server::Conn>,
    params: Value,
) -> Result<Value, RpcError> {
    let mut request: GithubActionParams = serde_json::from_value(params)
        .map_err(|e| invalid(format!("invalid GitHub broker request: {e}")))?;
    let config = {
        let guard = hub.config.read().await;
        load_policy(&guard.github_broker)?
    };
    // Nothing below this point is recorded until the caller has proved which
    // session it is: an audit row names a session, so writing one for an
    // unproved caller would let anyone who can reach the socket or the peer
    // link append rows to a session that is not theirs. The shape check comes
    // first for the same reason: a row only ever holds validated strings.
    if !config.enabled {
        return Err(denied("GitHub broker is disabled"));
    }
    validate_shape(&request)?;
    if request.forwarded {
        if conn.origin != crate::server::Origin::Peer {
            return Err(invalid("forwarded GitHub broker requests require a peer connection"));
        }
        verify_peer_capability(&request, &config)?;
    } else {
        if conn.origin != crate::server::Origin::Local {
            return Err(denied("peer GitHub broker requests must carry a peer capability"));
        }
        let caller = conn
            .caller()
            .ok_or_else(|| denied("GitHub broker requires a caller-bound acpmux session"))?;
        if caller != request.session_id {
            return Err(denied("GitHub broker session does not match the caller-bound session"));
        }
        hub.resolve(&request.session_id)?;
    }
    // From here the session is established, so a refusal is this session's own
    // business and is audited.
    if let (false, Some(owner)) = (request.forwarded, config.owner_peer.as_deref()) {
        // Every refusal below is a genuine refusal for an established session,
        // so each one is recorded rather than returned silently.
        let setup = || -> Result<(_, String, String), RpcError> {
            let peer = hub.peer_by_name(owner).ok_or_else(|| {
                RpcError::not_found(format!("GitHub broker owner peer {owner:?} is not configured"))
            })?;
            if !peer.connected.load(std::sync::atomic::Ordering::SeqCst) {
                return Err(RpcError::internal(format!(
                    "GitHub broker owner peer {owner:?} is disconnected"
                )));
            }
            let peer_id = config
                .peer_id
                .clone()
                .ok_or_else(|| denied("lane GitHub broker peer identity is not configured"))?;
            let peer_secret = config
                .peer_secret
                .clone()
                .ok_or_else(|| denied("lane GitHub broker peer secret is not configured"))?;
            Ok((peer, peer_id, peer_secret))
        };
        let (peer, peer_id, peer_secret) = match setup() {
            Ok(ready) => ready,
            Err(error) => {
                audit(hub, &request, audit_payload(&request, Err(&error)));
                return Err(error);
            }
        };
        request.forwarded = true;
        request.peer_id = Some(peer_id);
        request.peer_proof = match sign_request(&request, &peer_secret) {
            Ok(proof) => Some(proof),
            Err(error) => {
                audit(hub, &request, audit_payload(&request, Err(&error)));
                return Err(error);
            }
        };
        let wire = serde_json::to_value(&request).map_err(|e| RpcError::internal(e.to_string()))?;
        let result = peer.request(crate::rpc::method::MUX_GITHUB_ACTION, wire).await;
        // The session lives on this lane, so this is the event stream the app
        // watches even though the owner performed the command.
        return match &result {
            Ok(value) => {
                let successful = GithubActionResult {
                    action: request.action,
                    repo: request.repo.clone(),
                    session_id: request.session_id.clone(),
                    output: String::new(),
                };
                audit(hub, &request, audit_payload(&request, Ok(&successful)));
                Ok(value.clone())
            }
            Err(error) => {
                audit(hub, &request, audit_payload(&request, Err(error)));
                Err(error.clone())
            }
        };
    }

    // Authorize before spending the request id. Spending first would let a
    // peer burn the replay guard's capacity with requests the policy denies,
    // and make the ids of honest requests unavailable for the retention window.
    let authorized = match AuthorizedGithubAction::authorize(&config, request.clone()) {
        Ok(action) => action,
        Err(error) => {
            audit(hub, &request, audit_payload(&request, Err(&error)));
            return Err(error);
        }
    };
    if let Err(error) = consume_request(&request.request_id, request.issued_at, unix_now()) {
        audit(hub, &request, audit_payload(&request, Err(&error)));
        return Err(error);
    }
    match execute(authorized).await {
        Ok(result) => {
            let value =
                serde_json::to_value(&result).map_err(|e| RpcError::internal(e.to_string()))?;
            audit(hub, &request, audit_payload(&request, Ok(&result)));
            Ok(value)
        }
        Err(error) => {
            audit(hub, &request, audit_payload(&request, Err(&error)));
            Err(error)
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::config::github_broker::{GithubRepoPolicy, GithubSessionPolicy};
    use std::collections::{BTreeMap, BTreeSet};

    /// `sign_request` refuses anything under 32 bytes, so the fixtures use a
    /// secret of the shape a real policy file would hold.
    const TEST_SECRET: &str = "0123456789abcdef0123456789abcdef";

    fn config(action: &str, prefixes: &[&str]) -> GithubBrokerConfig {
        let mut actions = BTreeSet::new();
        actions.insert(action.into());
        GithubBrokerConfig {
            enabled: true,
            sessions: BTreeMap::from([(
                "session-1".into(),
                GithubSessionPolicy {
                    peer: Some("lane-1".into()),
                    repos: BTreeMap::from([(
                        "manaflow-ai/cmux".into(),
                        GithubRepoPolicy {
                            actions,
                            branch_prefixes: prefixes.iter().map(|s| (*s).into()).collect(),
                        },
                    )]),
                },
            )]),
            peer_secrets: BTreeMap::from([("lane-1".into(), TEST_SECRET.into())]),
            ..GithubBrokerConfig::default()
        }
    }

    fn params(request_id: &str) -> GithubActionParams {
        GithubActionParams {
            session_id: "session-1".into(),
            request_id: request_id.into(),
            issued_at: 1_700_000_000,
            action: GithubAction::Read,
            repo: "manaflow-ai/cmux".into(),
            branch: None,
            base: None,
            head_sha: None,
            issue: None,
            title: None,
            body: None,
            forwarded: false,
            peer_id: None,
            peer_proof: None,
        }
    }

    #[test]
    fn denied_action_is_fail_closed() {
        let request = GithubActionParams {
            session_id: "session-1".into(),
            request_id: "test-1".into(),
            issued_at: 1_700_000_000,
            action: GithubAction::Comment,
            repo: "manaflow-ai/cmux".into(),
            issue: Some(1),
            body: Some("hello".into()),
            branch: None,
            base: None,
            head_sha: None,
            title: None,
            peer_id: None,
            peer_proof: None,
            forwarded: false,
        };
        let err = AuthorizedGithubAction::authorize(&config("read", &[]), request).unwrap_err();
        assert_eq!(
            err.data.as_ref().and_then(|data| data["reason"].as_str()),
            Some("github.policy_denied")
        );
    }

    #[test]
    fn allowed_draft_pr_requires_allowed_prefix() {
        let request = GithubActionParams {
            session_id: "session-1".into(),
            request_id: "test-2".into(),
            issued_at: 1_700_000_000,
            action: GithubAction::DraftPr,
            repo: "manaflow-ai/cmux".into(),
            branch: Some("agent/42".into()),
            base: Some("main".into()),
            head_sha: None,
            issue: None,
            title: Some("broker".into()),
            body: Some("body".into()),
            peer_id: None,
            peer_proof: None,
            forwarded: false,
        };
        let authorized =
            AuthorizedGithubAction::authorize(&config("draft_pr", &["agent/"]), request).unwrap();
        assert_eq!(authorized.gh_args()[0..3], ["pr", "create", "--draft"]);
    }

    #[test]
    fn audit_entry_omits_body_and_title() {
        let request = GithubActionParams {
            session_id: "session-1".into(),
            request_id: "test-3".into(),
            issued_at: 1_700_000_000,
            action: GithubAction::DraftPr,
            repo: "manaflow-ai/cmux".into(),
            branch: Some("agent/42".into()),
            base: None,
            head_sha: None,
            issue: None,
            title: Some("secret title".into()),
            body: Some("secret body".into()),
            peer_id: None,
            peer_proof: None,
            forwarded: false,
        };
        let audit = audit_payload(&request, Err(&denied("no")));
        assert_eq!(audit["status"], "denied");
        assert!(audit.get("title").is_none() && audit.get("body").is_none());
    }

    #[test]
    fn output_limit_never_splits_utf8() {
        let out = clean_output("é".repeat(OUTPUT_MAX).as_bytes());
        assert!(out.ends_with('…'));
        assert!(out.len() <= OUTPUT_MAX + '…'.len_utf8());
    }

    #[test]
    fn peer_capability_binds_identity_and_request() {
        let mut request = params("test-4");
        request.forwarded = true;
        request.peer_id = Some("lane-1".into());
        let config = config("read", &[]);
        request.peer_proof = Some(sign_request(&request, TEST_SECRET).unwrap());
        assert!(verify_peer_capability(&request, &config).is_ok());
        // Changing any signed field invalidates the proof.
        request.session_id = "other-session".into();
        assert!(verify_peer_capability(&request, &config).is_err());
        request.session_id = "session-1".into();
        let now = request.issued_at;
        assert!(consume_request(&request.request_id, request.issued_at, now).is_ok());
        assert!(consume_request(&request.request_id, request.issued_at, now).is_err());
    }

    /// A lane's own secret proves which lane sent a request, not which session
    /// it may act for: with both sessions in the policy, lane-1 must not be
    /// able to sign a well-formed request that borrows session-2's grants.
    #[test]
    fn a_peer_cannot_act_for_another_sessions_grants() {
        let mut config = config("read", &[]);
        let session_2 = config.sessions.get("session-1").cloned().unwrap();
        config.sessions.insert(
            "session-2".into(),
            GithubSessionPolicy { peer: Some("lane-2".into()), ..session_2 },
        );
        config.peer_secrets.insert("lane-2".into(), "fedcba9876543210fedcba9876543210".into());

        let mut request = params("test-6");
        request.forwarded = true;
        request.peer_id = Some("lane-1".into());
        request.session_id = "session-2".into();
        request.peer_proof = Some(sign_request(&request, TEST_SECRET).unwrap());
        // The proof itself verifies: lane-1 really did sign this request.
        assert!(verify_peer_capability(&request, &config).is_err());

        // lane-2 is the session's own peer, so the same request is accepted.
        request.peer_id = Some("lane-2".into());
        request.peer_proof =
            Some(sign_request(&request, "fedcba9876543210fedcba9876543210").unwrap());
        assert!(verify_peer_capability(&request, &config).is_ok());
    }

    /// Unset `peer` denies every forwarded request for the session, rather
    /// than letting any lane with a valid secret act for it.
    #[test]
    fn a_session_with_no_peer_takes_no_forwarded_request() {
        let mut config = config("read", &[]);
        config.sessions.get_mut("session-1").unwrap().peer = None;
        let mut request = params("test-7");
        request.forwarded = true;
        request.peer_id = Some("lane-1".into());
        request.peer_proof = Some(sign_request(&request, TEST_SECRET).unwrap());
        assert!(verify_peer_capability(&request, &config).is_err());
    }

    /// An audit row is shown verbatim in the agent pane, so the shape check
    /// must refuse a control-character or oversized string before a refusal
    /// could put one there.
    #[test]
    fn the_shape_check_refuses_what_an_audit_row_would_show() {
        let mut request = params("test-8");
        assert!(validate_shape(&request).is_ok());
        request.branch = Some("agent/\u{1b}[2Jwiped".into());
        assert!(validate_shape(&request).is_err());
        request.branch = Some("a".repeat(257));
        assert!(validate_shape(&request).is_err());
        request.branch = None;
        request.repo = "not-a-repo".into();
        assert!(validate_shape(&request).is_err());
        request.repo = "manaflow-ai/cmux".into();
        request.session_id = "has\na newline".into();
        assert!(validate_shape(&request).is_err());
    }

    #[test]
    fn a_short_peer_secret_cannot_sign_a_request() {
        let mut request = params("test-5");
        request.forwarded = true;
        request.peer_id = Some("lane-1".into());
        assert!(sign_request(&request, "too-short").is_err());
        request.peer_proof = Some(sign_request(&request, TEST_SECRET).unwrap());
        let mut config = config("read", &[]);
        config.peer_secrets.insert("lane-1".into(), "too-short-secret".into());
        assert!(verify_peer_capability(&request, &config).is_err());
    }

    #[test]
    fn a_stale_or_future_request_is_refused_before_it_is_recorded() {
        let mut spent = HashMap::new();
        let now = 1_700_000_000u64;
        let stale = now - REQUEST_FRESHNESS_SECS - 1;
        assert!(spend(&mut spent, "stale-1", stale, now).is_err());
        let ahead = now + REQUEST_FRESHNESS_SECS + 1;
        assert!(spend(&mut spent, "ahead-1", ahead, now).is_err());
        // A refusal must not spend the id, so an honest retry still works.
        assert!(spent.is_empty());
        assert!(spend(&mut spent, "stale-1", now, now).is_ok());
        assert!(spend(&mut spent, "ahead-1", now, now).is_ok());
    }

    #[test]
    fn a_spent_id_is_forgotten_only_after_it_can_no_longer_be_replayed() {
        let mut spent = HashMap::new();
        let at = 1_700_000_000u64;
        assert!(spend(&mut spent, "window-1", at, at).is_ok());
        // Still inside the window a replay is refused, and the pass that bounds
        // the guard must not drop the id that refuses it.
        assert!(spend(&mut spent, "window-1", at, at + REQUEST_FRESHNESS_SECS).is_err());
        assert!(spent.contains_key("window-1"));
        // Past the window the request is refused by its own `issuedAt`, so
        // whether its id is still on record cannot change the answer.
        assert!(spend(&mut spent, "window-1", at, at + REQUEST_FRESHNESS_SECS * 2 + 1).is_err());
        // The id is dropped by the next request that gets as far as the guard,
        // which is what keeps the map bounded.
        assert!(spend(&mut spent, "other-1", at + 241, at + 241).is_ok());
        assert!(!spent.contains_key("window-1"));
    }

    /// A duplicate must not be able to rewrite the time the owner recorded.
    /// Retention is measured from the owner's first sight of an id, so a
    /// caller that could backdate the stored time could retire its own id
    /// early and then replay the original request while it is still fresh.
    #[test]
    fn a_duplicate_cannot_backdate_a_spent_id() {
        let mut spent = HashMap::new();
        let now = 1_700_000_000u64;
        // Accepted with an issuedAt at the far edge of the window.
        assert!(spend(&mut spent, "x", now + REQUEST_FRESHNESS_SECS, now).is_ok());
        // A duplicate carrying the opposite edge is denied, and leaves the
        // recorded time alone.
        assert!(spend(&mut spent, "x", now - REQUEST_FRESHNESS_SECS, now).is_err());
        assert_eq!(spent.get("x"), Some(&now));
        // One second past the first request's own freshness window, the replay
        // is refused, and the id is still on record until retention ends.
        let replay_at = now + REQUEST_FRESHNESS_SECS + 1;
        assert!(spend(&mut spent, "x", now + REQUEST_FRESHNESS_SECS, replay_at).is_err());
        assert!(spent.contains_key("x"));
    }

    /// The branch prefix is the whole policy for `draft_pr` and `push`, so a
    /// `:` must never reach `gh --head`, where `owner:branch` means a fork's
    /// branch and the real branch would escape the granted prefix.
    #[test]
    fn a_fork_qualified_branch_cannot_escape_the_prefix() {
        let mut request = params("test-9");
        request.action = GithubAction::DraftPr;
        request.title = Some("broker".into());
        request.branch = Some("agent-attacker:main".into());
        assert!(validate_shape(&request).is_err());
        assert!(
            AuthorizedGithubAction::authorize(&config("draft_pr", &["agent-"]), request).is_err()
        );
    }

    /// The guard is bounded by retention, not by eviction, so a run of
    /// requests spread over many windows never grows it without limit.
    #[test]
    fn the_guard_stays_bounded_across_windows() {
        let mut spent = HashMap::new();
        let start = 1_700_000_000u64;
        for i in 0..200u64 {
            let at = start + i * 60;
            assert!(spend(&mut spent, &format!("req-{i}"), at, at).is_ok());
            assert!(spent.len() <= 5, "{} ids at step {i}", spent.len());
        }
    }
}
