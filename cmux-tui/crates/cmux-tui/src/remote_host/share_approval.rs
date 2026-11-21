//! Share This Mac for a Mac already the owner's, confirmed on the device the
//! owner is at (Leo, 2026-11-14: "Let the owner confirm from the device they
//! are at (the same-account device asking, one click there, recorded in the
//! audit log)"): the asker's flow.
//!
//! `cmux remote-host share on --device DEVICE` (or the `remote_share` MCP tool
//! with `device`) asks the asker's own cmux app (`remote.confirm {action:
//! share, device}`). The app shows "Share Studio's screen with your devices?"
//! and only after the person clicks Allow signs a [`ShareApproval`] with its
//! device key. An agent can call `remote.confirm`, but nothing signs without
//! the click: no click, no approval, no share ([`share_from_here`]). The
//! approval and the target's admission are acpmux's (`acpmux::share_approval`),
//! beside the hub carrier that brings it to the target. Both sides write the
//! host audit log (`audit.jsonl`): who confirmed, on which device, and when.

use std::collections::HashSet;

pub(crate) use acpmux::share_approval::{
    AskerKeys, Refused, SameAccountGrant, ShareApproval, Target, admit, target_entry,
};
use serde_json::{Value, json};

/// The asker's audit fields for a confirmed approval: what was allowed, who
/// clicked, on which device, when.
pub(crate) fn asker_fields(approval: &ShareApproval) -> Value {
    json!({
        "device": approval.target,
        "device_name": approval.display_target(),
        "confirmed_by": approval.confirmed_by,
        "confirmed_on": approval.asker,
        "confirmed_on_name": approval.display_asker(),
        "confirmed_at": super::grant::rfc3339(approval.confirmed_at),
        "nonce": approval.nonce,
    })
}

/// [`admit`], with the decision written to an audit log: this Mac's host
/// audit log in the app (`record` is `remote_host::audit::append`).
#[cfg_attr(
    not(test),
    allow(dead_code, reason = "the target calls it once a carrier brings approvals to it")
)]
pub(crate) fn admit_and_record(
    approval: &ShareApproval,
    target: &Target<'_>,
    grant: &impl SameAccountGrant,
    keys: &impl AskerKeys,
    seen: &mut HashSet<String>,
    record: impl FnOnce(&Value),
) -> Result<(), Refused> {
    let decision = admit(approval, target, grant, keys, seen);
    record(&target_entry(approval, &decision));
    decision
}

/// Gets a confirmed approval to the target Mac.
pub(crate) trait Deliver {
    fn deliver(&self, approval: &ShareApproval) -> Result<Value, Value>;
}

/// The delivery until the approval has a carrier to the target: the target's
/// admission reads its owner's `signedInMachines` consent
/// (`acpmux::share_approval::SignedInMachinesConsent`), but nothing brings the
/// approval there yet, so it says so instead of trying.
pub(crate) struct AwaitingSameAccountControl;

impl Deliver for AwaitingSameAccountControl {
    fn deliver(&self, approval: &ShareApproval) -> Result<Value, Value> {
        Err(json!({
            "code": "share.needs_same_account_control",
            "message": format!(
                "you allowed sharing {} here, and it is recorded, but this cmux cannot send the approval to {} yet. {} admits it only while control for your other signed-in Macs is on there. For now, run `cmux remote-host share on` on {} itself.",
                approval.display_target(), approval.display_target(), approval.display_target(), approval.display_target()
            ),
            "details": {"confirmed": true, "delivered": false, "device": approval.target},
        }))
    }
}

/// The app's answer to `remote.confirm {action: share, device}`, read.
#[derive(Debug, PartialEq, Eq)]
pub(crate) enum AskerOutcome {
    /// The person clicked Allow; the app signed this.
    Confirmed(ShareApproval),
    /// The person clicked Cancel (or closed the dialog).
    Declined,
    /// No signed approval came back: an older app, or an answer that is not one.
    NotConfirmed(String),
}

/// Reads the app's answer for `device` (the id or name the caller passed).
pub(crate) fn asker_outcome(answer: &Value, device: &str) -> AskerOutcome {
    if answer.get("declined").and_then(Value::as_bool) == Some(true)
        || answer.get("ok").and_then(Value::as_bool) == Some(false)
    {
        return AskerOutcome::Declined;
    }
    let Some(raw) = answer.get("approval") else {
        return AskerOutcome::NotConfirmed(
            "the cmux app answered without a signed approval; check it with `cmux app version`"
                .into(),
        );
    };
    let approval: ShareApproval = match serde_json::from_value(raw.clone()) {
        Ok(approval) => approval,
        Err(error) => return AskerOutcome::NotConfirmed(format!("unreadable approval: {error}")),
    };
    if approval.signature.is_empty() || approval.nonce.is_empty() {
        return AskerOutcome::NotConfirmed("the approval is not signed".into());
    }
    let wanted = device.trim();
    if approval.target != wanted && !same_name(&approval.target_name, wanted) {
        return AskerOutcome::NotConfirmed(format!(
            "the app approved {}, not {wanted}",
            approval.display_target()
        ));
    }
    AskerOutcome::Confirmed(approval)
}

/// Whether `name` names the device `wanted` does, without case, as the app matches it
/// (Swift `caseInsensitiveCompare`, Unicode-aware): `--device MÜNCHEN` finds "München" on both sides.
fn same_name(name: &str, wanted: &str) -> bool {
    !name.is_empty() && name.to_lowercase() == wanted.to_lowercase()
}

/// The params of `remote.confirm` for sharing `device`.
pub(crate) fn confirm_params(device: &str) -> Value {
    json!({"action": "share", "on": true, "device": device.trim()})
}

/// The asker's whole flow: ask the person in this device's app (`ask` sends
/// `remote.confirm`), record the answer, deliver a signed approval. Only a
/// signed approval reaches `deliver`; a decline, a timeout or an unsigned
/// answer ends here as a refusal.
pub(crate) fn share_from_here(
    device: &str,
    ask: impl FnOnce(Value) -> Result<Value, Value>,
    deliver: &impl Deliver,
    mut record: impl FnMut(&str, Value),
) -> Result<Value, Value> {
    let device = device.trim();
    if device.is_empty() {
        return Err(
            json!({"code": "bad_request", "message": "--device needs a device id or name"}),
        );
    }
    let answer = match ask(confirm_params(device)) {
        Ok(answer) => answer,
        Err(error) => {
            record("remote_host.share_not_confirmed", json!({"device": device, "error": error}));
            return Err(error);
        }
    };
    match asker_outcome(&answer, device) {
        AskerOutcome::Declined => {
            record("remote_host.share_declined", json!({"device": device}));
            Err(
                json!({"code": "share.declined", "message": format!("not shared: the person did not allow sharing {device}")}),
            )
        }
        AskerOutcome::NotConfirmed(why) => {
            record("remote_host.share_not_confirmed", json!({"device": device, "error": why}));
            Err(json!({"code": "share.not_confirmed", "message": format!("not shared: {why}")}))
        }
        AskerOutcome::Confirmed(approval) => {
            record("remote_host.share_confirmed", asker_fields(&approval));
            let delivered = deliver.deliver(&approval)?;
            Ok(json!({
                "shared": true,
                "device": approval.target,
                "device_name": approval.display_target(),
                "confirmed_by": approval.confirmed_by,
                "confirmed_on": approval.asker,
                "confirmed_at": super::grant::rfc3339(approval.confirmed_at),
                "target": delivered,
            }))
        }
    }
}

#[cfg(test)]
#[path = "share_approval_tests.rs"]
mod tests;
