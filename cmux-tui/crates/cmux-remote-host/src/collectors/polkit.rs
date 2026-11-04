//! polkit on a Linux desktop: `CheckAuthorization` for the host process with
//! `AllowUserInteraction`, so the session's polkit agent shows the system
//! authentication dialog, with details naming the agent, the workspace and the
//! app (`dist/com.cmux.computer-use.policy` substitutes them into the message).
//! Authenticating confirms the offered decision; dismissing it answers `deny`.
//! The host withdraws the dialog (`CancelCheckAuthorization`) when another
//! collector answers first.

use std::collections::HashMap;

use async_trait::async_trait;
use zbus::zvariant::Value;

use crate::approval::{ApprovalRequest, Decision};
use crate::approver::{ApproverDecision, LocalCollector};

/// Allow the app for this session (or once).
pub const ACTION_APPROVE: &str = "com.cmux.computer-use.approve";
/// Always allow the app for this cmux client.
pub const ACTION_APPROVE_ALWAYS: &str = "com.cmux.computer-use.approve-always";
const ALLOW_USER_INTERACTION: u32 = 1;

pub struct Polkit;

/// The details polkit shows (`$(agent)`, `$(app)`, `$(workspace)`, `$(scope)`).
pub fn details(request: &ApprovalRequest, offered: Decision) -> HashMap<&'static str, String> {
    let scope = match offered {
        Decision::Once => "for this action",
        Decision::Session => "for this agent session",
        Decision::Always => "always, for this cmux",
        Decision::Deny => "",
    };
    HashMap::from([
        ("agent", request.agent.clone()),
        ("workspace", request.workspace.clone()),
        ("app", request.target.name.clone()),
        ("executable", request.target.executable.clone().unwrap_or_default()),
        ("tool", request.tool.clone()),
        ("scope", scope.to_owned()),
        ("client", request.client.clone()),
    ])
}

pub fn action_for(offered: Decision) -> &'static str {
    if offered == Decision::Always { ACTION_APPROVE_ALWAYS } else { ACTION_APPROVE }
}

/// Withdraws the dialog when the asking future is dropped.
struct CancelOnDrop {
    proxy: Option<zbus::Proxy<'static>>,
    id: String,
}

impl Drop for CancelOnDrop {
    fn drop(&mut self) {
        if let Some(proxy) = self.proxy.take() {
            let id = std::mem::take(&mut self.id);
            tokio::spawn(async move {
                let _ = proxy.call_method("CancelCheckAuthorization", &(id.as_str(),)).await;
            });
        }
    }
}

#[async_trait]
impl LocalCollector for Polkit {
    fn name(&self) -> &'static str {
        "polkit"
    }

    async fn ask(&self, request: &ApprovalRequest, offered: Decision) -> Option<ApproverDecision> {
        if offered == Decision::Deny {
            return None;
        }
        let connection = zbus::Connection::system().await.ok()?;
        let proxy = zbus::Proxy::new(
            &connection,
            "org.freedesktop.PolicyKit1",
            "/org/freedesktop/PolicyKit1/Authority",
            "org.freedesktop.PolicyKit1.Authority",
        )
        .await
        .ok()?;
        let pid = std::process::id();
        let start = crate::platform::process_start(pid)?;
        let uid = i32::try_from(crate::platform::my_uid()).ok()?;
        let subject_details: HashMap<&str, Value<'_>> =
            HashMap::from([("pid", Value::from(pid)), ("start-time", Value::from(start)), ("uid", Value::from(uid))]);
        let subject = ("unix-process", subject_details);
        let details = details(request, offered);
        let details: HashMap<&str, &str> = details.iter().map(|(key, value)| (*key, value.as_str())).collect();
        let cancellation = format!("cmux-cu-{}", &request.nonce[..16.min(request.nonce.len())]);
        let mut guard = CancelOnDrop { proxy: Some(proxy.clone()), id: cancellation.clone() };
        let reply = proxy
            .call_method(
                "CheckAuthorization",
                &(subject, action_for(offered), details, ALLOW_USER_INTERACTION, cancellation.as_str()),
            )
            .await;
        guard.proxy = None; // answered: nothing to cancel
        let reply = reply.ok()?;
        let (authorized, _challenge, details): (bool, bool, HashMap<String, String>) =
            reply.body().deserialize().ok()?;
        let decision = decision_of(authorized, &details, offered)?;
        Some(ApproverDecision {
            decision,
            digest: request.digest.clone(),
            via: "polkit".into(),
        })
    }
}

/// Authorized confirms the offered scope; a dialog the person dismissed is a deny;
/// any other refusal (no agent, not an active session) asks nobody, so the
/// phone and Mac can still answer.
pub fn decision_of(authorized: bool, details: &HashMap<String, String>, offered: Decision) -> Option<Decision> {
    if authorized {
        return Some(offered);
    }
    (details.get("polkit.dismissed").map(String::as_str) == Some("true")).then_some(Decision::Deny)
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::approval::{Question, Target};

    #[test]
    fn details_name_the_agent_the_app_and_the_scope() {
        let request = ApprovalRequest::new(
            Question {
                client: "c".into(),
                machine: "m".into(),
                session: "s".into(),
                agent: "Claude".into(),
                workspace: "api".into(),
                target: Target { bundle_id: None, executable: Some("/usr/bin/gedit".into()), name: "Text Editor".into() },
                tool: "click".into(),
                risk: "R1".into(),
            },
            1,
        )
        .unwrap();
        let details = details(&request, Decision::Session);
        assert_eq!(details["agent"], "Claude");
        assert_eq!(details["app"], "Text Editor");
        assert_eq!(details["scope"], "for this agent session");
        assert_eq!(action_for(Decision::Always), ACTION_APPROVE_ALWAYS);
    }

    /// polkit refuses `CheckAuthorization` details from a caller that is not
    /// uid 0 or the action's owner, and the host runs as the person's user: it
    /// passes none, and the policy's messages are fixed text.
    #[test]
    fn an_unprivileged_check_passes_no_details() {
        let request = ApprovalRequest::new(
            Question {
                client: "c".into(),
                machine: "m".into(),
                session: "s".into(),
                agent: "Claude".into(),
                workspace: "api".into(),
                target: Target { bundle_id: None, executable: Some("/usr/bin/gedit".into()), name: "Text Editor".into() },
                tool: "click".into(),
                risk: "R1".into(),
            },
            1,
        )
        .unwrap();
        for offered in [Decision::Once, Decision::Session, Decision::Always] {
            assert!(details(&request, offered).is_empty());
        }
        let policy = include_str!("../../dist/com.cmux.computer-use.policy");
        assert!(!policy.contains("$("), "a polkit message substitutes nothing the host can pass");
    }

    #[test]
    fn only_a_dismissed_dialog_denies() {
        let none = HashMap::new();
        let dismissed = HashMap::from([("polkit.dismissed".to_owned(), "true".to_owned())]);
        assert_eq!(decision_of(true, &none, Decision::Session), Some(Decision::Session));
        assert_eq!(decision_of(false, &dismissed, Decision::Session), Some(Decision::Deny));
        assert_eq!(decision_of(false, &none, Decision::Session), None);
    }
}
