//! An OS-denied ACP read stays pending for one person-approved retry. This never grants TCC
//! rights, changes a rule, or replays a whole agent turn.
use super::*;
use std::path::Path;

#[derive(Clone, Copy, Debug, PartialEq, Eq, serde::Serialize)]
#[serde(rename_all = "snake_case")]
pub(super) enum AccessKind {
    FilesAndFolders,
    FullDiskAccess,
}

/// EPERM in a known macOS protected location can be a privacy block. EACCES, errors on other
/// platforms, and arbitrary tool text are not evidence of TCC. Keep the UI's wording tentative.
fn classify(
    error: &std::io::Error,
    path: &Path,
    home: Option<&Path>,
    macos: bool,
) -> Option<AccessKind> {
    if !macos || error.raw_os_error() != Some(libc::EPERM) {
        return None;
    }
    let kind = crate::protected_folders::protected_kind_in(path, home)?;
    Some(if kind == "appData" { AccessKind::FullDiskAccess } else { AccessKind::FilesAndFolders })
}

pub(in crate::hub) fn is_external(request: &Value) -> bool {
    request.pointer("/toolCall/_meta/acpmux/externalAccess").is_some()
}

fn request(session: &Session, path: &Path, kind: AccessKind, call: &str) -> Value {
    json!({
        "sessionId": session.meta().agent_session_id.clone().unwrap_or_else(|| session.id.clone()),
        "toolCall": {
            "toolCallId": call, "kind": "read", "status": "pending",
            "title": format!("Read {}", path.display()),
            "rawInput": {"path": path}, "locations": [{"path": path}],
            "_meta": {"acpmux": {"externalAccess": {
                "kind": kind, "target": path, "operation": "read_text_file",
                "platform": "macos"
            }}}
        },
        "options": [
            {"optionId": "allow_once", "name": "Allow once", "kind": "allow_once"},
            {"optionId": "reject_once", "name": "Skip", "kind": "reject_once"}
        ]
    })
}

/// A cancelled/dropped read cannot leave an answerable card behind. Normal settlement removes
/// it before this guard drops; an aborted request settles only its own card here.
struct PendingRead<'a> {
    hub: &'a Hub,
    session: &'a Session,
    call: String,
}
impl Drop for PendingRead<'_> {
    fn drop(&mut self) {
        let pending = {
            let mut state = self.session.permissions.lock().unwrap_or_else(|e| e.into_inner());
            let id = state.pending.iter().find_map(|(id, p)| {
                (is_external(&p.request)
                    && p.request.pointer("/toolCall/toolCallId").and_then(Value::as_str)
                        == Some(&self.call))
                .then(|| id.clone())
            });
            id.and_then(|id| state.pending.remove(&id).map(|p| (id, p)))
        };
        if let Some((id, pending)) = pending {
            self.hub.settle_permission(
                self.session,
                &id,
                json!({"outcome": "cancelled"}),
                None,
                pending.prev_status,
            );
        }
    }
}

impl Hub {
    pub(super) async fn read_with_external_access(
        self: &Arc<Self>,
        session: &Arc<Session>,
        path: &Path,
        epoch: u64,
        turn: Option<String>,
        mut read: impl FnMut() -> std::io::Result<String>,
    ) -> Result<String, RpcError> {
        let error = match read() {
            Ok(text) => return Ok(text),
            Err(error) => error,
        };
        let Some(kind) =
            classify(&error, path, dirs::home_dir().as_deref(), cfg!(target_os = "macos"))
        else {
            return Err(read_error(path, error));
        };
        self.retry_external_read(session, path, epoch, turn, kind, read).await
    }

    #[allow(clippy::too_many_arguments)] // Retains the original operation's turn, path and one retry.
    async fn retry_external_read(
        self: &Arc<Self>,
        session: &Arc<Session>,
        path: &Path,
        epoch: u64,
        turn: Option<String>,
        kind: AccessKind,
        mut read: impl FnMut() -> std::io::Result<String>,
    ) -> Result<String, RpcError> {
        let pending = PendingRead {
            hub: self,
            session,
            call: format!("external-read-{}", uuid::Uuid::now_v7()),
        };
        let ask = request(session, path, kind, &pending.call);
        let outcome = self.handle_permission(session, ask, epoch, turn.clone()).await;
        if !outcome_allows(&outcome) {
            return Err(RpcError::new(-32000, format!("read of {} skipped", path.display())));
        }
        // A deny added after the answer still wins. Full access never grants OS rights.
        let policy = Self::stored_policy_for(session, self.config.read().await.permission_policy);
        let probe = request(session, path, kind, &pending.call);
        let rule = session
            .meta()
            .permission_rules
            .as_ref()
            .and_then(|r| super::super::rules::decide(r, &probe));
        if matches!(rule, Some(super::super::rules::RuleDecision::Deny))
            || (rule.is_none() && policy == PermissionPolicy::DenyAll)
        {
            return Err(RpcError::new(-32000, "policy_changed"));
        }
        if session.permission_epoch.load(Ordering::SeqCst) != epoch || stale_turn(session, &turn) {
            return Err(RpcError::new(-32000, "the turn of this read ended"));
        }
        // Exactly one retry, still under normal OS enforcement. A persistent denial is returned,
        // not converted into another card or an automatic retry loop.
        read().map_err(|error| read_error(path, error))
    }
}

fn read_error(path: &Path, error: std::io::Error) -> RpcError {
    RpcError::new(-32000, format!("read {}: {error}", path.display()))
}

#[cfg(test)]
mod tests;
