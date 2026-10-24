//! Scoped GitHub actions performed by the owner's daemon.
//!
//! The peer sends an action description, never a token. The daemon executes
//! the corresponding fixed `gh` command using the owner's existing keyring
//! and returns a bounded result. Policy is checked before a subprocess is
//! started; a policy entry can never create an arbitrary command.

use crate::config::github_broker::GithubBrokerConfig;
use crate::rpc::RpcError;
use schemars::JsonSchema;
use serde::{Deserialize, Serialize};
use serde_json::{Value, json};
use std::sync::Arc;
use tokio::process::Command;

const REPO_MAX: usize = 140;
const TEXT_MAX: usize = 64 * 1024;
const OUTPUT_MAX: usize = 64 * 1024;

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
        && owner.bytes().all(|c| c.is_ascii_alphanumeric() || c == '-' || c == '_')
        && name.bytes().all(|c| c.is_ascii_alphanumeric() || matches!(c, '-' | '_' | '.'))
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
            if !valid_branch(branch)
                || !repo_policy
                    .branch_prefixes
                    .iter()
                    .any(|prefix| !prefix.is_empty() && branch.starts_with(prefix))
            {
                return Err(denied("branch is outside the policy's allowed prefixes"));
            }
        }
        if let Some(base) = request.base.as_deref() {
            if !valid_branch(base) {
                return Err(invalid("base is not a valid Git branch"));
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

fn clean_output(bytes: &[u8]) -> String {
    let mut out = String::from_utf8_lossy(bytes).into_owned();
    if out.len() > OUTPUT_MAX {
        out.truncate(OUTPUT_MAX);
        out.push_str("…");
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
    let Some(path) = config.policy_path.as_deref() else { return Ok(config.clone()) };
    let text = std::fs::read_to_string(path).map_err(|e| {
        RpcError::internal(format!("read GitHub broker policy {}: {e}", path.display()))
    })?;
    let mut from_file: GithubBrokerConfig = serde_json::from_str(&text).map_err(|e| {
        RpcError::invalid_params(format!("parse GitHub broker policy {}: {e}", path.display()))
    })?;
    from_file.enabled = config.enabled;
    from_file.owner_peer = config.owner_peer.clone();
    from_file.policy_path = config.policy_path.clone();
    for (session, policy) in &config.sessions {
        from_file.sessions.entry(session.clone()).or_insert_with(|| policy.clone());
    }
    Ok(from_file)
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
    if request.forwarded {
        if conn.origin != crate::server::Origin::Peer {
            return Err(invalid("forwarded GitHub broker requests require a peer connection"));
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
        let wire = serde_json::to_value(&request).map_err(|e| RpcError::internal(e.to_string()))?;
        let result = peer.request(crate::rpc::method::MUX_GITHUB_ACTION, wire).await;
        // The session lives on this lane, so this is the event stream the app
        // watches even though the owner performed the command.
        match &result {
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
        }
    } else if !matches!(conn.origin, crate::server::Origin::Local | crate::server::Origin::Peer) {
        return Err(invalid(
            "GitHub broker requests are accepted only from a local socket or peer",
        ));
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
            action: GithubAction::Comment,
            repo: "manaflow-ai/cmux".into(),
            issue: Some(1),
            body: Some("hello".into()),
            branch: None,
            base: None,
            head_sha: None,
            title: None,
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
            action: GithubAction::DraftPr,
            repo: "manaflow-ai/cmux".into(),
            branch: Some("agent/42".into()),
            base: Some("main".into()),
            head_sha: None,
            issue: None,
            title: Some("broker".into()),
            body: Some("body".into()),
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
            action: GithubAction::DraftPr,
            repo: "manaflow-ai/cmux".into(),
            branch: Some("agent/42".into()),
            base: None,
            head_sha: None,
            issue: None,
            title: Some("secret title".into()),
            body: Some("secret body".into()),
            forwarded: false,
        };
        let audit = audit_payload(&request, Err(&denied("no")));
        assert_eq!(audit["status"], "denied");
        assert!(audit.get("title").is_none() && audit.get("body").is_none());
    }
}
