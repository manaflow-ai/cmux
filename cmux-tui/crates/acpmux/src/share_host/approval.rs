//! The target end of the share approval carrier (cmuxterm-hq#18912 cut 2): "Share works from
//! your computer with zero actions on that machine: no app open there, no switch, no approval"
//! (docs/design/remote-screen-share-zero-touch.md).
//!
//! The device the person tapped on (the owner's iPhone, or another Mac's app) signs a
//! [`ShareApproval`] with its device key and sends it to the device hub as
//! `POST /v1/devices/<this Mac>/share-approval {approval}`. The hub takes it only from a
//! person's full session, as the device the approval names (a host or machine session, which is
//! what an agent's fleet or CLI token signs in as, is refused there), and pushes it to this Mac's
//! User DO socket as `{"type": "share.approval", "from": <sender device>, "approval": {..}}`.
//!
//! [`receive`] is what this Mac does with it, with nobody at the Mac: the hub must have carried
//! it from the device that signed it; then [`admit`] with [`OwnerPairedDevice`] for the account
//! this Mac is joined as and the hub's own device list for that account as the keys (a device
//! not on it is `share.unknown_device`, a signature that is not its key's is
//! `share.bad_signature`); on a yes this Mac turns sharing on with its own
//! `PUT /v1/devices/:id/mac-screen`. Every decision is a [`target_entry`] line in
//! `share-host/audit.jsonl` (owner-only). Nothing on this Mac (a settings file, a consent record,
//! an agent's call) is read as the yes: only the signature is.

use crate::share_approval::{
    AskerKeys, CONTROL_VERSION, OwnerPairedDevice, Refused, ShareApproval, Target, VERSION,
    admit_as, target_entry,
};
use serde_json::{Value, json};
use std::collections::{HashMap, HashSet};

/// The push type the hub carries an approval in.
pub(crate) const PUSH: &str = "share.approval";
/// The push type the hub carries a control approval in (`cmux.control-approval.v1`): the
/// owner's tap on their own device, granting this Mac's "control for my other signed-in
/// machines" with nobody at the Mac ([`receive_control`]).
pub(crate) const CONTROL_PUSH: &str = "control.approval";
/// The person's switch for [`receive_control`], in their settings file: off unless they set it
/// to `true`. Off, this Mac grants control only by its own Allow click.
pub(crate) const CONTROL_SETTING: &str = "devices.allowControlFromMyDevices";
/// The audit log under the share host's folder.
pub(crate) const AUDIT_FILE: &str = "audit.jsonl";

/// The device hub's devices for this Mac's account (`GET /v1/devices`, which lists only the
/// account's own live devices): each one's `signingKey`.
#[derive(Debug, Default)]
pub(crate) struct HubDeviceKeys(HashMap<String, String>);

impl HubDeviceKeys {
    pub(crate) fn from_devices(devices: &Value) -> Self {
        let listed = devices.get("devices").and_then(Value::as_array).into_iter().flatten();
        Self(
            listed
                .filter_map(|device| {
                    let field = |k: &str| device.get(k).and_then(Value::as_str).map(str::to_owned);
                    Some((field("id")?, field("signingKey").filter(|key| !key.is_empty())?))
                })
                .collect(),
        )
    }
}

impl AskerKeys for HubDeviceKeys {
    fn signing_key(&self, device: &str) -> Option<String> {
        self.0.get(device).cloned()
    }
}

/// What the target reads from and asks of its device hub.
pub(crate) trait TargetHub {
    /// This Mac's device hub id.
    fn device_id(&self) -> String;
    /// The account this Mac is signed in to the hub as (its machine sign-in's `userId`).
    fn account(&self) -> Option<String>;
    /// `GET /v1/devices`.
    fn devices(&self) -> Result<Value, String>;
    /// `PUT /v1/devices/<this Mac>/mac-screen {"shared": true}`.
    fn share_on(&self) -> Result<(), String>;
}

impl TargetHub for cmux_hub_host::hub::Hub {
    fn device_id(&self) -> String {
        self.device.id.clone()
    }

    fn account(&self) -> Option<String> {
        self.user_id().filter(|account| !account.is_empty())
    }

    fn devices(&self) -> Result<Value, String> {
        self.call("GET", "/v1/devices", None).map_err(|e| e.to_string())
    }

    fn share_on(&self) -> Result<(), String> {
        self.set_shared(true).map(|_| ()).map_err(|e| e.to_string())
    }
}

fn refused(code: &'static str, message: impl Into<String>) -> Refused {
    Refused { code, message: message.into() }
}

/// One carried approval (`push`, a `share.approval` push), at `now` (Unix seconds): admitted
/// and sharing turned on, or refused and why. Each decision goes to `record` as its audit line;
/// a taken nonce goes into `seen`.
pub(crate) fn receive(
    hub: &impl TargetHub,
    push: &Value,
    now: u64,
    seen: &mut HashSet<String>,
    record: impl FnOnce(&Value),
) -> Result<(), Refused> {
    carried(hub, push, VERSION, now, seen, record, |_account| {
        hub.share_on().map_err(|e| {
            refused("share.not_turned_on", format!("admitted, but sharing did not turn on: {e}"))
        })
    })
}

/// One carried control approval (`push`, a [`CONTROL_PUSH`]), at `now`: admitted exactly as
/// [`receive`] admits a share approval (carried by the device that signed it, that device on
/// this account's hub list, its device-key signature, fresh, an unused nonce), and then `grant`
/// records "control for my other signed-in machines" for the account it names. `grant` is this
/// Mac's consent writer; it refuses when this Mac is joined as another account. Nothing an
/// agent can send is read as the yes: an agent's token is not a device and signs nothing.
///
/// `allowed` is the person's [`CONTROL_SETTING`], off by default: while it is off an admitted
/// approval grants nothing and is refused as `control.off`, audited like any other refusal.
/// The approval is still admitted first, so its nonce is spent and the audit line names the
/// device that asked; turning the setting on later needs a new tap.
pub(crate) fn receive_control(
    hub: &impl TargetHub,
    push: &Value,
    now: u64,
    seen: &mut HashSet<String>,
    allowed: bool,
    record: impl FnOnce(&Value),
    grant: impl FnOnce(&str) -> Result<(), String>,
) -> Result<(), Refused> {
    carried(hub, push, CONTROL_VERSION, now, seen, record, |account| {
        if !allowed {
            return Err(refused(
                "control.off",
                format!(
                    "this Mac does not take a control grant from another device: its setting \
                     {CONTROL_SETTING} is off. Set it to true on this Mac, or click Allow there"
                ),
            ));
        }
        grant(account).map_err(|e| {
            refused("control.not_granted", format!("admitted, but control was not turned on: {e}"))
        })
    })
}

/// Whether the settings document turns [`CONTROL_SETTING`] on. Anything but `true` is off.
pub(crate) fn control_allowed_by(doc: Option<&Value>) -> bool {
    doc.and_then(|d| crate::user_settings::value(d, CONTROL_SETTING)) == Some(Value::Bool(true))
}

/// The person's [`CONTROL_SETTING`] as their settings file has it now. An unreadable or
/// missing file is off.
pub(crate) fn control_allowed() -> bool {
    match crate::user_settings::read() {
        crate::user_settings::Settings::Parsed(doc) => control_allowed_by(Some(&doc)),
        _ => false,
    }
}

/// The shared path of [`receive`] and [`receive_control`]: read the approval, admit it as
/// `version`, then `act` for the account it was admitted for. Audited either way.
fn carried(
    hub: &impl TargetHub,
    push: &Value,
    version: &str,
    now: u64,
    seen: &mut HashSet<String>,
    record: impl FnOnce(&Value),
    act: impl FnOnce(&str) -> Result<(), Refused>,
) -> Result<(), Refused> {
    let approval = match push.get("approval").cloned().map(serde_json::from_value::<ShareApproval>)
    {
        Some(Ok(approval)) => approval,
        Some(Err(e)) => {
            let why =
                refused("share.unreadable", format!("the carried approval is unreadable: {e}"));
            record(&unreadable_entry(&why));
            return Err(why);
        }
        None => {
            let why = refused("share.unreadable", "the push carries no approval");
            record(&unreadable_entry(&why));
            return Err(why);
        }
    };
    let decision =
        admitted(hub, push, &approval, version, now, seen).and_then(|account| act(&account));
    let mut entry = target_entry(&approval, &decision);
    if let Some(fields) = entry.as_object_mut() {
        fields.insert("carrier".into(), json!("device-hub"));
        fields.insert("device".into(), json!(approval.target));
    }
    record(&entry);
    decision
}

/// The account `approval` is admitted for, or why it is refused.
fn admitted(
    hub: &impl TargetHub,
    push: &Value,
    approval: &ShareApproval,
    version: &str,
    now: u64,
    seen: &mut HashSet<String>,
) -> Result<String, Refused> {
    // The hub writes `from` from its own authenticated record of the sender, never from the
    // body: the device that sent it must be the one that signed it.
    let from = push.get("from").and_then(Value::as_str).unwrap_or_default();
    if from.is_empty() || from != approval.asker {
        return Err(refused(
            "share.not_carried_by_asker",
            format!(
                "the approval names {} but the hub did not carry it from that device",
                approval.display_asker()
            ),
        ));
    }
    let Some(account) = hub.account() else {
        return Err(refused(
            "share.not_signed_in",
            "this Mac is not signed in to the device hub yet; nothing admitted",
        ));
    };
    let device = hub.device_id();
    let keys = HubDeviceKeys::from_devices(&hub.devices().map_err(|e| {
        refused(
            "share.keys_unavailable",
            format!("the device hub's device list is unreadable: {e}"),
        )
    })?);
    let target = Target { device: &device, account: &account, now };
    admit_as(version, approval, &target, &OwnerPairedDevice { account: &account }, &keys, seen)?;
    Ok(account)
}

/// The audit line for a push whose approval cannot be read.
fn unreadable_entry(why: &Refused) -> Value {
    json!({
        "event": "remote_host.share_refused",
        "via": "same-account",
        "carrier": "device-hub",
        "code": why.code,
        "reason": why.message,
    })
}

/// Appends `entry`, with `ts` (RFC 3339), to `dir`'s [`AUDIT_FILE`] through the home's
/// owner-only state-file open. A failure is logged, never fatal to the decision already made.
pub(crate) fn append_audit(dir: &std::path::Path, entry: &Value) {
    use std::io::Write as _;
    let mut line = entry.clone();
    if let Some(fields) = line.as_object_mut() {
        let now = chrono::Utc::now().to_rfc3339_opts(chrono::SecondsFormat::Secs, true);
        fields.insert("ts".into(), json!(now));
    }
    let path = dir.join(AUDIT_FILE);
    let written = crate::config::private_state_dir(dir)
        .and_then(|()| crate::config::private_state_append(&path))
        .and_then(|mut file| Ok(file.write_all(format!("{line}\n").as_bytes())?));
    if let Err(e) = written {
        tracing::warn!("{}: audit line not written to {}: {e}", super::LOG, path.display());
    }
}

/// Unix seconds now.
pub(crate) fn now_secs() -> u64 {
    cmux_hub_host::hub::now_ms() / 1000
}

#[cfg(test)]
#[path = "approval_tests.rs"]
mod tests;
