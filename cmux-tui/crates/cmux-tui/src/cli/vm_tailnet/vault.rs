//! The user's tailnet node, kept in their cmux vault (RFD 0169): `keep VM` copies the node state a
//! VM holds into the vault, `adopt VM` brings that node up on a VM with no key, and `vm rm` of a
//! joined VM hands its node to the vault instead of signing it out. The state is a secret (the
//! node's private keys): it goes from the VM to the vault and back, never to stdout, a log or a file
//! on this machine. The vault route is person-only; no machine credential reads it.

use std::time::{Duration, Instant};

use base64::Engine as _;
use cmux_tailnet_join::{SCRIPT_FILE, Secret, handoff};
use serde_json::{Value, json};
use sha2::{Digest as _, Sha256};

use super::super::machine_join::{self, CallError, Platform};
use super::super::vm_bootstrap::Guest;
use super::{await_detached, exec_ok, millis};

/// The vault's one tailnet node (cmux-platform `VaultTailnetNodeApi`).
pub(super) const NODE_PATH: &str = "/v1/vault/tailnet-node";
/// Which VM holds that node now: a lease only one VM has at a time (cmux-platform#2167).
pub(super) const HOLDER_PATH: &str = "/v1/vault/tailnet-node/holder";
const RELEASE_PATH: &str = "/v1/vault/tailnet-node/holder/release";

const VAULT_TIMEOUT: Duration = Duration::from_secs(20);

/// What the vault keeps: the node's name (its MagicDNS name), the vault revision it was written at,
/// and its state (base64).
pub(super) struct KeptNode {
    pub(super) name: String,
    pub(super) revision: u64,
    pub(super) state: Secret,
}

/// The vault's lease on the node: the VM that holds it (none between holders) and the epoch every
/// claim and release moves on, so a late write from an old holder is refused.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub(super) struct Lease {
    pub(super) holder: Option<String>,
    pub(super) epoch: u64,
}

/// The user's vault, as far as the node goes. A fake stands in for it in tests.
pub(super) trait NodeVault {
    /// Keeps `state` as the node `name`; `Ok` is the vault revision.
    fn put(&self, name: &str, state: &Secret) -> Result<u64, String>;
    /// The kept node, or `None` when the vault keeps none.
    fn get(&self) -> Result<Option<KeptNode>, String>;
    /// Drops the kept node (it was signed out: its keys open nothing any more).
    fn delete(&self) -> Result<(), String>;
    /// Who holds the node now.
    fn lease(&self) -> Result<Lease, String>;
    /// Names `holder` the node's holder. With `if_epoch` it takes the node over from whoever holds
    /// it at that epoch; without it, another holder is refused.
    fn claim(&self, holder: &str, if_epoch: Option<u64>) -> Result<Lease, String>;
    /// Ends `holder`'s lease, when it still holds the node at `epoch`.
    fn release(&self, holder: &str, epoch: u64) -> Result<(), String>;
}

/// The vault on the cmux platform, signed in as the person.
pub(super) struct PlatformVault {
    platform: Platform,
}

/// The vault for whoever is signed in here; `None` when nobody is (no `CMUX_CLOUD_ACCESS_TOKEN`).
pub(super) fn signed_in(
    env: &dyn Fn(&str) -> Option<String>,
) -> Result<Option<PlatformVault>, String> {
    let Some(credential) = machine_join::device_credential(None, false)? else {
        return Ok(None);
    };
    let origin = machine_join::platform_origin(None, env)?;
    let platform =
        Platform::new(origin, credential, VAULT_TIMEOUT).map_err(|failure| failure.message)?;
    Ok(Some(PlatformVault { platform }))
}

fn said(error: CallError) -> String {
    match error {
        CallError::Status { code: "vault.tailnet_node_conflict", .. } => {
            "your vault's tailnet node changed while this ran; run it again".to_owned()
        }
        CallError::Status { code: "vault.tailnet_holder_conflict", .. } => {
            "another VM holds your tailnet node now (your vault's lease); nothing changed"
                .to_owned()
        }
        CallError::Status { status, code, .. } if !code.is_empty() => {
            format!("your vault refused it ({status} {code})")
        }
        CallError::Status { status, .. } => format!("your vault refused it ({status})"),
        CallError::Unreachable(why) => format!("your vault is unreachable ({why})"),
        CallError::Unreadable(status) => format!("your vault's answer was unreadable ({status})"),
    }
}

impl NodeVault for PlatformVault {
    fn put(&self, name: &str, state: &Secret) -> Result<u64, String> {
        let answer = self
            .platform
            .request(reqwest::Method::PUT, NODE_PATH, Some(put_body(name, state)?))
            .map_err(said)?;
        answer
            .get("revision")
            .and_then(Value::as_u64)
            .ok_or_else(|| said(CallError::Unreadable(200)))
    }

    fn get(&self) -> Result<Option<KeptNode>, String> {
        match self.platform.request(reqwest::Method::GET, NODE_PATH, None) {
            Ok(body) => parse_node(&body).map(Some),
            Err(CallError::Status { code: "vault.tailnet_node_missing", .. }) => Ok(None),
            Err(error) => Err(said(error)),
        }
    }

    fn delete(&self) -> Result<(), String> {
        match self.platform.request(reqwest::Method::DELETE, NODE_PATH, None) {
            Ok(_) | Err(CallError::Status { code: "vault.tailnet_node_missing", .. }) => Ok(()),
            Err(error) => Err(said(error)),
        }
    }

    fn lease(&self) -> Result<Lease, String> {
        let body = self.platform.request(reqwest::Method::GET, HOLDER_PATH, None).map_err(said)?;
        parse_lease(&body)
    }

    fn claim(&self, holder: &str, if_epoch: Option<u64>) -> Result<Lease, String> {
        let mut body = json!({"holder": holder});
        if let Some(epoch) = if_epoch {
            body["ifEpoch"] = json!(epoch);
        }
        match self.platform.request(reqwest::Method::PUT, HOLDER_PATH, Some(body)) {
            Ok(answer) => parse_lease(&answer),
            Err(CallError::Status { code: "vault.tailnet_holder_conflict", .. }) => {
                Err(match self.lease() {
                    Ok(Lease { holder: Some(other), .. }) => held_by(&other, holder),
                    _ => said(CallError::Status {
                        status: 409,
                        code: "vault.tailnet_holder_conflict",
                        facts: None,
                    }),
                })
            }
            Err(error) => Err(said(error)),
        }
    }

    fn release(&self, holder: &str, epoch: u64) -> Result<(), String> {
        self.platform
            .request(
                reqwest::Method::POST,
                RELEASE_PATH,
                Some(json!({"holder": holder, "epoch": epoch})),
            )
            .map(|_| ())
            .map_err(said)
    }
}

/// Reads the vault's lease answer (`{holder: string|null, epoch, updatedAt}`).
pub(super) fn parse_lease(body: &Value) -> Result<Lease, String> {
    let Some(epoch) = body.get("epoch").and_then(Value::as_u64) else {
        return Err("your vault's tailnet lease is missing its epoch".to_owned());
    };
    let holder = match body.get("holder") {
        None | Some(Value::Null) => None,
        Some(Value::String(holder)) if !holder.is_empty() => Some(holder.clone()),
        Some(_) => return Err("your vault's tailnet lease has an unreadable holder".to_owned()),
    };
    Ok(Lease { holder, epoch })
}

fn held_by(other: &str, vm: &str) -> String {
    format!(
        "{other} holds your tailnet node (your vault's lease); run `cmux vm tailnet move {other} {vm}`, or `cmux vm tailnet adopt {vm} --take-over` if {other} is gone"
    )
}

/// Makes `vm` the node's one holder before it comes up there. Already its holder: unchanged. Free:
/// claimed. Held by `from` (a move) or `take_over` (the user said so): taken over at the epoch
/// just read, so a holder that changed meanwhile still wins. Held by another VM: refused.
pub(super) fn hold(
    vault: &dyn NodeVault,
    vm: &str,
    from: Option<&str>,
    take_over: bool,
) -> Result<Lease, String> {
    let lease = vault.lease()?;
    match lease.holder.as_deref() {
        Some(holder) if holder == vm => Ok(lease),
        None => vault.claim(vm, None),
        Some(holder) if take_over || from == Some(holder) => vault.claim(vm, Some(lease.epoch)),
        Some(holder) => Err(held_by(holder, vm)),
    }
}

/// Ends `vm`'s lease when it holds the node (it signed out or went away); a lease it does not
/// hold is left alone.
pub(super) fn let_go(vault: &dyn NodeVault, vm: &str) -> Result<(), String> {
    match vault.lease()? {
        Lease { holder: Some(holder), epoch } if holder == vm => vault.release(vm, epoch),
        _ => Ok(()),
    }
}

/// The vault names the node by its hostname label (`leo-cmux` of `leo-cmux.tail1.ts.net`): the
/// tailnet's suffix is not the node's and the vault takes only a label.
pub(super) fn label(name: &str) -> &str {
    name.trim_end_matches('.').split('.').next().unwrap_or_default()
}

fn fingerprint(raw: &[u8]) -> String {
    Sha256::digest(raw).iter().map(|b| format!("{b:02x}")).collect()
}

fn decode(state: &Secret) -> Result<Vec<u8>, String> {
    handoff::check_state(state.expose())?;
    base64::engine::general_purpose::STANDARD
        .decode(state.expose())
        .map_err(|_| "the node state is not base64".to_owned())
}

/// The PUT body: the state, its name and the sha256 of its bytes, which the vault checks.
pub(super) fn put_body(name: &str, state: &Secret) -> Result<Value, String> {
    let raw = decode(state)?;
    let name = label(name);
    if name.is_empty() {
        return Err("the node has no name to keep it under".to_owned());
    }
    Ok(json!({"stateBase64": state.expose(), "name": name, "fingerprint": fingerprint(&raw)}))
}

/// Reads the vault's GET answer; the state must be a node's size and match its fingerprint.
pub(super) fn parse_node(body: &Value) -> Result<KeptNode, String> {
    let text = |key: &str| body.get(key).and_then(Value::as_str);
    let (Some(state), Some(name), Some(print), Some(revision)) = (
        text("stateBase64"),
        text("name"),
        text("fingerprint"),
        body.get("revision").and_then(Value::as_u64),
    ) else {
        return Err("your vault's tailnet node is missing a field".to_owned());
    };
    let state = Secret::new(state);
    let raw = decode(&state).map_err(|why| why.replacen("the node", "the vault's node", 1))?;
    if fingerprint(&raw) != print {
        return Err("your vault's tailnet node does not match its fingerprint".to_owned());
    }
    Ok(KeptNode { name: name.to_owned(), revision, state })
}

/// May the vault take the node `name`? Yes when it keeps none or keeps this same node; a different
/// node stays unless the user runs `keep` on purpose.
pub(super) fn holds_other(vault: &dyn NodeVault, name: &str) -> Result<Option<String>, String> {
    Ok(vault.get()?.map(|kept| kept.name).filter(|kept| label(kept) != label(name)))
}

/// Copies the node `guest` holds into the vault as `name`, leaving it running there. `Ok` is the
/// vault revision.
pub(super) fn keep(
    guest: &mut dyn Guest,
    vault: &dyn NodeVault,
    name: &str,
) -> Result<u64, String> {
    let answer = guest.exec(&handoff::snapshot_command())?;
    if answer.exit_code != 0 {
        return Err(format!(
            "the VM did not hand over its node state (exit {}): {}",
            answer.exit_code,
            answer.stderr.trim()
        ));
    }
    let state = handoff::parse_snapshot(&answer.stdout)?;
    vault.put(name, &state)
}

/// Brings the vault's node up on `guest`: same name, addresses and node key, no auth key. `Ok` is
/// the node, its name in the vault and how long it took.
pub(super) fn adopt(
    guest: &mut dyn Guest,
    vault: &dyn NodeVault,
    vm: &str,
    take_over: bool,
    timeout: Duration,
) -> Result<(Value, String), String> {
    let started = Instant::now();
    let deadline = started + timeout;
    let Some(kept) = vault.get()? else {
        return Err(
            "your vault keeps no tailnet node; join a VM first (cmux vm tailnet join), then keep it"
                .to_owned(),
        );
    };
    let lease = hold(vault, vm, None, take_over)?;
    let brought_up = bring_up(guest, &kept, deadline, timeout);
    let node = match brought_up {
        Ok(node) => node,
        Err(why) => {
            // It never came up here: the lease goes back, so the next adopt or move is not refused.
            let _ = vault.release(vm, lease.epoch);
            return Err(why);
        }
    };
    Ok((
        json!({
            "dnsName": node.dns_name,
            "ips": node.ips,
            "tags": node.tags,
            "online": node.online,
            "revision": kept.revision,
            "epoch": lease.epoch,
            "elapsedMs": millis(started.elapsed()),
        }),
        kept.name,
    ))
}

fn bring_up(
    guest: &mut dyn Guest,
    kept: &KeptNode,
    deadline: Instant,
    timeout: Duration,
) -> Result<cmux_tailnet_join::Joined, String> {
    exec_ok(
        guest,
        &cmux_tailnet_join::prepare_command(cmux_cloud_start_core::machine_bootstrap::USER),
        "prepared",
    )?;
    guest
        .write(SCRIPT_FILE, handoff::vm_adopt_script().as_bytes(), 0o700)
        .map_err(|e| format!("writing the adopt script: {e}"))?;
    guest
        .write(handoff::STAGED_STATE_FILE, handoff::staged_contents(&kept.state).as_bytes(), 0o600)
        .map_err(|e| format!("writing the node state: {e}"))?;
    exec_ok(guest, &cmux_tailnet_join::start_command(), "started")?;
    let (node, _) = await_detached(guest, deadline, timeout, Duration::from_millis(250), "adopt")?;
    Ok(node)
}

/// Before the VM goes (`vm rm`): stop its node, hand the state to the vault, then delete the VM's
/// copy, so the node is never up twice and outlives the VM. If the vault does not take it, the node
/// starts again on the VM and `Err` says why (the caller then signs it out as before).
pub(super) fn release_to_vault(
    guest: &mut dyn Guest,
    vault: &dyn NodeVault,
    vm: &str,
    name: &str,
) -> Result<u64, String> {
    let answer = guest.exec(&handoff::release_command())?;
    if answer.exit_code != 0 {
        return Err(format!(
            "the VM did not release its node (exit {}): {}",
            answer.exit_code,
            answer.stderr.trim()
        ));
    }
    let released = handoff::parse_released(&answer.stdout)?;
    match vault.put(name, &released.state) {
        Ok(revision) => {
            // Best effort: the VM is about to go, and its stopped copy goes with it.
            let _ = exec_ok(guest, &handoff::forget_command(), "cmux-tailnet-forgot");
            // The node is down and kept: no VM holds it until one adopts it.
            let _ = let_go(vault, vm);
            Ok(revision)
        }
        Err(why) => {
            let back = match exec_ok(guest, &handoff::restore_command(), "cmux-tailnet-restored") {
                Ok(()) => "the node is running on the VM again".to_owned(),
                Err(e) => format!("restarting it on the VM failed too: {e}"),
            };
            Err(format!("{why}; {back}"))
        }
    }
}
