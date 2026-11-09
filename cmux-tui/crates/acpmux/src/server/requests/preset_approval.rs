//! `_acpmux/preset_approve {name, approve, digest?}`: the person approves a preset for unattended
//! runs on fleet agent machines, or anyone revokes it (`hub/unattended.rs`). The person check
//! (`hub/person.rs`) has already refused an approve from anyone but the person.
//!
//! An approve names the digest of the contents the person saw (`_acpmux/preset_approvals`
//! `digest`): a preset that changed since is refused with `preset_approval.changed`, so the
//! person approves exactly what the card showed, never an edit that landed in between.

use super::*;
use crate::hub::unattended;

fn refused(reason: &str, message: String) -> RpcError {
    RpcError::invalid_params(message).with_data(json!({"reason": reason}))
}

pub(super) async fn approve(
    hub: &Arc<Hub>,
    _conn: &Arc<Conn>,
    params: &Value,
) -> Result<Value, RpcError> {
    let name = str_param(params, "name")
        .filter(|n| !n.is_empty())
        .ok_or_else(|| RpcError::invalid_params("name is required"))?
        .to_owned();
    let approve = params
        .get("approve")
        .and_then(Value::as_bool)
        .ok_or_else(|| RpcError::invalid_params("approve must be true or false"))?;
    {
        let mut cfg = hub.config.write().await;
        let Some(preset) = cfg.presets.get_mut(&name) else {
            return Err(refused("preset_approval.no_preset", format!("no preset {name:?}")));
        };
        if approve {
            if let Some(why) = preset.unattended_blocker() {
                return Err(RpcError::invalid_params(format!(
                    "preset {name:?} cannot be approved for unattended runs ({why})"
                ))
                .with_data(json!({"reason": "preset_approval.blocked", "blocked": why})));
            }
            let now = preset.approval_digest().unwrap_or_default();
            let seen = str_param(params, "digest").unwrap_or_default();
            if now.is_empty() || !cmux_local_auth::tokens_match(seen, &now) {
                return Err(RpcError::invalid_params(format!(
                    "preset {name:?} changed since it was shown: read it again and approve what it is now"
                ))
                .with_data(json!({"reason": "preset_approval.changed", "digest": now})));
            }
            let approval = unattended::approval_now(preset)
                .ok_or_else(|| RpcError::internal("the preset's contents cannot be hashed"))?;
            unattended::record(
                "approved",
                json!({"preset": name, "digest": approval.digest, "by": approval.by,
                    "approvedOn": approval.host}),
            );
            preset.unattended = Some(approval);
        } else if preset.unattended.take().is_some() {
            unattended::record("revoked", json!({"preset": name}));
        }
        if let Err(e) = cfg.save() {
            return Err(RpcError::internal(format!("save config: {e}")));
        }
    }
    hub.preset_approval_row(&name)
        .await
        .ok_or_else(|| refused("preset_approval.no_preset", format!("no preset {name:?}")))
}
