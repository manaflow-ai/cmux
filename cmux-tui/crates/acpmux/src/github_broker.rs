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
/// requestId -> its signed `issuedAt`.
static SPENT_REQUESTS: OnceLock<Mutex<HashMap<String, u64>>> = OnceLock::new();

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
        && branch.bytes().all(|c| c.is_ascii_graphic() && c != b'\\')
}

impl AuthorizedGithubAction {
    pub fn authorize(
        config: &GithubBrokerConfig,
        request: GithubActionParams,
    ) -> Result<Self, RpcError> {
        if !config.enabled {
            return Err(denied("GitHub broker is disabled"));
        }
        bounded_text("sessionId", &request.session_id)?;
        if !valid_repo(&request.repo) {
            return Err(invalid("repo must be an owner/name GitHub repository"));
        }
        if let Some(branch) = request.branch.as_deref()
            && !valid_branch(branch)
        {
            return Err(invalid("branch is not a valid Git branch"));
        }
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
        if let Some(base) = request.base.as_deref()
            && !valid_branch(base)
        {
            return Err(invalid("base is not a valid Git branch"));
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
    peer_secrets: &std::collections::BTreeMap<String, String>,
) -> Result<(), RpcError> {
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
    spent.retain(|_, seen| now.saturating_sub(*seen) <= REQUEST_FRESHNESS_SECS * 2);
    if spent.len() >= SPENT_REQUESTS_MAX {
        // Only a flood inside one window reaches this: fail closed rather than
        // evict an id that a captured request could still be replayed with.
        return Err(RpcError::internal("GitHub broker replay guard is saturated"));
    }
    if spent.insert(request_id.to_owned(), issued_at).is_some() {
        return Err(denied("GitHub broker request has already been used"));
    }
    Ok(())
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

pub async fn execute(action: AuthorizedGithubAction) -> Result<GithubActionResult, RpcError> {
    let request = &action.request;
    let args = action.gh_args();
    let output = Command::new("gh")
        .args(&args)
        .output()
        .await
        .map_err(|e| RpcError::internal(format!("GitHub broker could not start gh: {e}")))?;
    if !output.status.success() {
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
        .custom_flags(libc::O_NOFOLLOW)
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
    let mut text = String::new();
    file.read_to_string(&mut text).map_err(|e| unreadable_policy(path, e))?;
    Ok(text)
}

#[cfg(not(unix))]
fn read_policy_file(path: &Path) -> Result<String, RpcError> {
    std::fs::read_to_string(path).map_err(|e| unreadable_policy(path, e))
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
    if !config.enabled {
        let error = denied("GitHub broker is disabled");
        let _ = hub.append_github_audit(&request.session_id, audit_payload(&request, Err(&error)));
        return Err(error);
    }
    if !request.forwarded {
        if conn.origin != crate::server::Origin::Local {
            return Err(denied("peer GitHub broker requests must carry a peer capability"));
        }
        let caller = conn
            .caller()
            .ok_or_else(|| denied("GitHub broker requires a caller-bound acpmux session"))?;
        if caller != request.session_id {
            let error = denied("GitHub broker session does not match the caller-bound session");
            let _ =
                hub.append_github_audit(&request.session_id, audit_payload(&request, Err(&error)));
            return Err(error);
        }
        if let Err(error) = hub.resolve(&request.session_id) {
            let _ =
                hub.append_github_audit(&request.session_id, audit_payload(&request, Err(&error)));
            return Err(error);
        }
    }
    if request.forwarded {
        if conn.origin != crate::server::Origin::Peer {
            return Err(invalid("forwarded GitHub broker requests require a peer connection"));
        }
        if let Err(error) = verify_peer_capability(&request, &config.peer_secrets) {
            let _ =
                hub.append_github_audit(&request.session_id, audit_payload(&request, Err(&error)));
            return Err(error);
        }
        if let Err(error) = consume_request(&request.request_id, request.issued_at, unix_now()) {
            let _ =
                hub.append_github_audit(&request.session_id, audit_payload(&request, Err(&error)));
            return Err(error);
        }
    } else if let Some(owner) = config.owner_peer.as_deref() {
        if conn.origin != crate::server::Origin::Local {
            return Err(invalid("a lane broker request must enter through its local socket"));
        }
        let peer = hub.peer_by_name(owner).ok_or_else(|| {
            RpcError::not_found(format!("GitHub broker owner peer {owner:?} is not configured"))
        })?;
        if !peer.connected.load(std::sync::atomic::Ordering::SeqCst) {
            return Err(RpcError::internal(format!(
                "GitHub broker owner peer {owner:?} is disconnected"
            )));
        }
        request.forwarded = true;
        let peer_id = config
            .peer_id
            .as_deref()
            .ok_or_else(|| denied("lane GitHub broker peer identity is not configured"))?;
        let peer_secret = config
            .peer_secret
            .as_deref()
            .ok_or_else(|| denied("lane GitHub broker peer secret is not configured"))?;
        request.peer_id = Some(peer_id.to_owned());
        request.peer_proof = Some(sign_request(&request, peer_secret)?);
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
                let _ = hub.append_github_audit(
                    &request.session_id,
                    audit_payload(&request, Ok(&successful)),
                );
                Ok(value.clone())
            }
            Err(error) => {
                let _ = hub
                    .append_github_audit(&request.session_id, audit_payload(&request, Err(error)));
                Err(error.clone())
            }
        };
    } else if !matches!(conn.origin, crate::server::Origin::Local | crate::server::Origin::Peer) {
        return Err(invalid(
            "GitHub broker requests are accepted only from a local socket or peer",
        ));
    }

    if !request.forwarded {
        consume_request(&request.request_id, request.issued_at, unix_now())?;
    }

    let authorized = match AuthorizedGithubAction::authorize(&config, request.clone()) {
        Ok(action) => action,
        Err(error) => {
            let _ =
                hub.append_github_audit(&request.session_id, audit_payload(&request, Err(&error)));
            return Err(error);
        }
    };
    match execute(authorized).await {
        Ok(result) => {
            let value =
                serde_json::to_value(&result).map_err(|e| RpcError::internal(e.to_string()))?;
            let _ =
                hub.append_github_audit(&request.session_id, audit_payload(&request, Ok(&result)));
            Ok(value)
        }
        Err(error) => {
            let _ =
                hub.append_github_audit(&request.session_id, audit_payload(&request, Err(&error)));
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
                    repos: BTreeMap::from([(
                        "manaflow-ai/cmux".into(),
                        GithubRepoPolicy {
                            actions,
                            branch_prefixes: prefixes.iter().map(|s| (*s).into()).collect(),
                        },
                    )]),
                },
            )]),
            ..GithubBrokerConfig::default()
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
        let mut request = GithubActionParams {
            session_id: "session-1".into(),
            request_id: "test-4".into(),
            issued_at: 1_700_000_000,
            action: GithubAction::Read,
            repo: "manaflow-ai/cmux".into(),
            branch: None,
            base: None,
            head_sha: None,
            issue: None,
            title: None,
            body: None,
            forwarded: true,
            peer_id: Some("lane-1".into()),
            peer_proof: None,
        };
        let proof = sign_request(&request, TEST_SECRET).unwrap();
        request.peer_proof = Some(proof);
        let secrets =
            std::collections::BTreeMap::from([(String::from("lane-1"), String::from(TEST_SECRET))]);
        assert!(verify_peer_capability(&request, &secrets).is_ok());
        request.session_id = "other-session".into();
        assert!(verify_peer_capability(&request, &secrets).is_err());
        request.session_id = "session-1".into();
        let now = request.issued_at;
        assert!(consume_request(&request.request_id, request.issued_at, now).is_ok());
        assert!(consume_request(&request.request_id, request.issued_at, now).is_err());
    }

    #[test]
    fn a_short_peer_secret_cannot_sign_a_request() {
        let mut request = GithubActionParams {
            session_id: "session-1".into(),
            request_id: "test-5".into(),
            issued_at: 1_700_000_000,
            action: GithubAction::Read,
            repo: "manaflow-ai/cmux".into(),
            branch: None,
            base: None,
            head_sha: None,
            issue: None,
            title: None,
            body: None,
            forwarded: true,
            peer_id: Some("lane-1".into()),
            peer_proof: None,
        };
        assert!(sign_request(&request, "too-short").is_err());
        request.peer_proof = Some(sign_request(&request, TEST_SECRET).unwrap());
        let secrets = BTreeMap::from([(String::from("lane-1"), String::from("too-short-secret"))]);
        assert!(verify_peer_capability(&request, &secrets).is_err());
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
        // Past the window the request itself is refused, so forgetting its id
        // cannot let it through, and the guard stays bounded.
        assert!(spend(&mut spent, "window-1", at, at + REQUEST_FRESHNESS_SECS * 2 + 1).is_err());
        assert!(spent.is_empty());
    }
}
