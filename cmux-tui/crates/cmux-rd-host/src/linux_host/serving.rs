//! Which account this desktop's host serves (review F1 of #45369). One invariant, kept here and
//! only here: the host serves only the identity it last signed in as, and on a joined machine
//! that is the current join's. Every sign-in goes through [`join`] or [`person`]:
//!
//! - Before a sign-in for any other identity, and when a sign-in fails, the previous identity
//!   is torn down ([`tear_down`]), in this order: the host unit stopped, the hub asked to sign
//!   the old device out (an offline hub is asked again later, [`PENDING_FILE`]), its local
//!   records deleted. Only then does the new identity sign in, and the caller starts the unit.
//! - A sign-in that fails leaves the host off, never on the old account.
//! - A joined machine's identity is its join ([`machine::Joined::is`]: the acpmux home, machine
//!   id and credential generation), checked here before the host is installed and by `run`
//!   before it serves, so a host started for an earlier join never serves.
//! - A person's own `enable` is refused while the machine has a live join ([`join_owner`]).

use super::machine;
use super::{machine_renewal, with_fresh_identity, Fatal};
use crate::Res;
use cmux_hub_host::hub::{Hub, HubError};
use cmux_hub_host::identity::{self, Account, Device};
use serde::{Deserialize, Serialize};
use std::path::Path;

/// Stops the host unit before an identity changes.
pub(super) trait Unit {
    fn stop(&self) -> Res<()>;
}

/// The user's `cmux-screen-host.service`.
pub(super) struct HostUnit;

impl Unit for HostUnit {
    fn stop(&self) -> Res<()> {
        super::setup::stop_host()
    }
}

/// The unit is this process, at `run`'s start, before it has served anything.
pub(super) struct ThisProcess;

impl Unit for ThisProcess {
    fn stop(&self) -> Res<()> {
        Ok(())
    }
}

/// The devices whose hub sign-out did not reach the hub: asked again at the next sign-in and at
/// the host's start.
pub(super) const PENDING_FILE: &str = "pending-sign-out.json";
/// At most this many are kept; older ones are dropped (their device keys are deleted, so the
/// host cannot serve them either way).
const PENDING_KEPT: usize = 8;

#[derive(Serialize, Deserialize, Clone)]
struct Pending {
    hub: String,
    user_id: String,
    device: Device,
}

/// What this desktop is signed in as now: any of its records.
struct Previous {
    account: Option<Account>,
    device: Option<Device>,
    joined: Option<machine::Joined>,
}

impl Previous {
    fn load(dir: &Path) -> Res<Option<Self>> {
        let previous = Self {
            account: Account::load(dir)?,
            device: Device::load(dir)?,
            joined: machine::Joined::load(dir)?,
        };
        let any =
            previous.account.is_some() || previous.device.is_some() || previous.joined.is_some();
        Ok(any.then_some(previous))
    }
}

/// The account a live join signed this desktop in as: Some while the join's credential is still
/// there (from [`machine::JOINED_FILE`], or `ACPMUX_HOME` when the join has not signed it in yet).
pub(super) fn join_owner(dir: &Path) -> Res<Option<String>> {
    let recorded = match machine::Joined::load(dir)? {
        Some(joined) => machine::load(&joined.acpmux_home)?.is_some(),
        None => false,
    };
    if !recorded && machine::current()?.is_none() {
        return Ok(None);
    }
    let account = match (recorded, Account::load(dir)?) {
        (true, Some(account)) => account.user_id,
        _ => "this machine's account".to_owned(),
    };
    Ok(Some(account))
}

/// The host as the join `credential` from `home`: its device, signed in. The same join keeps its
/// device once the hub still signs it in as the recorded account; anything else is torn down
/// first. On an error the host is off.
pub(super) fn join(
    dir: &Path,
    hub_url: &str,
    home: &Path,
    credential: machine::MachineCredential,
    unit: &dyn Unit,
) -> Res<Device> {
    retry_pending(dir);
    let previous = Previous::load(dir)?;
    if let Some(Previous { account: Some(account), device: Some(device), joined: Some(joined) }) =
        &previous
    {
        if joined.is(home, &credential) && account.hub == hub_url {
            let renewal = machine_renewal(credential.clone());
            let checked = Hub::with_renewal(hub_url, device.clone(), None, renewal)
                .and_then(|hub| hub.session().map(|_| hub.user_id()));
            match checked {
                Ok(Some(user)) if user == account.user_id => return Ok(device.clone()),
                Ok(_) => {}
                Err(e) => {
                    tear_down(dir, previous, unit)?;
                    return Err(e);
                }
            }
        }
    }
    tear_down(dir, previous, unit)?;
    match super::sign_in_machine(dir, hub_url, home, credential) {
        Ok((hub, _)) => Ok(hub.device),
        Err(e) => {
            tear_down(dir, Previous::load(dir)?, unit)?;
            Err(e)
        }
    }
}

/// The host as the person `token` signs in: their device, registered, anchored and shared. The
/// same person on the same hub keeps the device; anything else is torn down first. Refused on a
/// joined machine. On an error the host is off.
pub(super) fn person(
    dir: &Path,
    hub_url: &str,
    token: &str,
    name: Option<&str>,
    encoder: &dyn Fn() -> String,
    unit: &dyn Unit,
) -> Res<(Device, String)> {
    if let Some(account) = join_owner(dir)? {
        return Err(format!(
            "this machine is joined to {account}; run `acpmux machine leave` first"
        )
        .into());
    }
    retry_pending(dir);
    let previous = Previous::load(dir)?;
    let device_name = name
        .map(str::to_owned)
        .or_else(|| previous.as_ref().and_then(|p| p.device.as_ref()).map(|d| d.name.clone()))
        .unwrap_or_else(identity::host_name);
    // Whose token it is: `/v1/auth/stack` is unsigned, so no device signs in for this.
    let user = match Hub::new(hub_url, Device::generate(&device_name)?, None)
        .and_then(|hub| hub.sign_in_with_stack(token))
    {
        Ok(user) => user,
        Err(e) => {
            tear_down(dir, previous, unit)?;
            return Err(e);
        }
    };
    let kept = match &previous {
        Some(Previous { account: Some(account), device: Some(device), joined: None })
            if account.user_id == user && account.hub == hub_url =>
        {
            Some(device.clone())
        }
        _ => None,
    };
    let device = match kept {
        Some(mut device) => {
            device.name = device_name;
            device
        }
        None => {
            tear_down(dir, previous, unit)?;
            Device::generate(&device_name)?
        }
    };
    let signed_in = with_fresh_identity(device, |device| {
        device.save(dir)?;
        let hub = Hub::new(hub_url, device.clone(), None)?;
        let user_id = hub.sign_in_with_stack(token)?;
        hub.register("linux")?;
        Ok((hub, user_id))
    })
    .and_then(|(_, (hub, user_id))| {
        let anchored_until = hub.anchor()?;
        // The encoder before sharing turns on: a viewer must not reach a host that cannot encode.
        let encoder = encoder();
        hub.set_shared(true)?;
        Account { hub: hub_url.to_owned(), user_id, anchored_until }.save(dir)?;
        machine::Joined::clear(dir)?;
        Ok((hub.device, encoder))
    });
    match signed_in {
        Ok(done) => Ok(done),
        Err(e) => {
            tear_down(dir, Previous::load(dir)?, unit)?;
            Err(e)
        }
    }
}

/// Right before the host unit starts for a join: the join it signed in as must still be the
/// current one (a leave or another join may have replaced it while the host was set up), else
/// the sign-in is torn down and the unit is not started.
pub(super) fn still_current(dir: &Path, unit: &dyn Unit) -> Res<()> {
    let current = match (machine::Joined::load(dir)?, machine::current()?) {
        (Some(joined), Some((home, credential))) => joined.is(&home, &credential),
        _ => false,
    };
    if current {
        return Ok(());
    }
    tear_down(dir, Previous::load(dir)?, unit)?;
    Err("this machine's join changed while its host was set up; the host is off".into())
}

/// The host this desktop serves at `run`'s start: a joined desktop's must be the current
/// join's, or it serves nothing (a unit started for an earlier join, or after a leave).
pub(super) fn current_join(
    dir: &Path,
    joined: &machine::Joined,
) -> Res<machine::MachineCredential> {
    let credential = machine::load(&joined.acpmux_home)?
        .ok_or_else(|| Fatal::needs("This machine's join was revoked or removed", Fatal::JOIN))?;
    if !joined.is(&joined.acpmux_home, &credential) {
        return Err(Fatal(format!(
            "This machine was joined again since this host signed in ({}). The host stopped and will not restart by itself; the acpmux daemon sets it up for the new join at its next start",
            dir.join(machine::JOINED_FILE).display()
        ))
        .into());
    }
    retry_pending(dir);
    Ok(credential)
}

/// Takes `previous` off this desktop: the unit stopped first, then the hub asked to sign its
/// device out, then its records deleted. A hub that cannot be reached is asked again later;
/// the local part never waits on it. Nothing previous: the unit is still stopped.
fn tear_down(dir: &Path, previous: Option<Previous>, unit: &dyn Unit) -> Res<()> {
    let stopped = unit.stop();
    if let Some(previous) = previous {
        sign_out(dir, &previous);
    }
    super::forget_sign_in(dir)?;
    if let Err(e) = stopped {
        return Err(
            format!("the earlier sign-in is deleted, but its host unit did not stop: {e}").into()
        );
    }
    Ok(())
}

/// Asks the hub to sign `previous`'s device out: ends its sessions and drops its anchor. A
/// person's device signs out with its own key; a join's with its credential when that is still
/// the one it signed in with (once the join is replaced its credential is gone, and no session
/// can be made for its device again).
fn sign_out(dir: &Path, previous: &Previous) {
    let (Some(account), Some(device)) = (&previous.account, &previous.device) else { return };
    let hub = match &previous.joined {
        None => Hub::new(&account.hub, device.clone(), Some(account.user_id.clone())),
        Some(joined) => match machine::load(&joined.acpmux_home) {
            Ok(Some(credential)) if joined.is(&joined.acpmux_home, &credential) => {
                Hub::with_renewal(&account.hub, device.clone(), None, machine_renewal(credential))
            }
            _ => {
                eprintln!(
                    "cmux-rd linux-host: the earlier join's credential is gone, so its device ({}) cannot sign in again; its records are deleted",
                    device.id
                );
                return;
            }
        },
    };
    match hub.and_then(|hub| hub_sign_out(&hub)) {
        Ok(()) => {}
        Err(e) if e.is::<HubError>() => eprintln!(
            "cmux-rd linux-host: the hub refused to sign the earlier device ({}) out ({e}); it cannot sign in with its deleted key",
            device.id
        ),
        Err(e) if previous.joined.is_none() => {
            eprintln!(
                "cmux-rd linux-host: the hub did not answer the earlier device's sign-out ({e}); asked again later"
            );
            let pending =
                Pending { hub: account.hub.clone(), user_id: account.user_id.clone(), device: device.clone() };
            if let Err(e) = add_pending(dir, pending) {
                eprintln!("cmux-rd linux-host: {}: {e}", dir.join(PENDING_FILE).display());
            }
        }
        Err(e) => eprintln!(
            "cmux-rd linux-host: the hub did not answer the earlier join's sign-out ({e}); its credential signs nothing in here again"
        ),
    }
}

fn hub_sign_out(hub: &Hub) -> Res<()> {
    hub.call("POST", &format!("/v1/devices/{}/sign-out", hub.device.id), None).map(|_| ())
}

fn load_pending(dir: &Path) -> Res<Vec<Pending>> {
    match identity::read_private(&dir.join(PENDING_FILE))? {
        Some(bytes) => Ok(serde_json::from_slice(&bytes)?),
        None => Ok(Vec::new()),
    }
}

fn save_pending(dir: &Path, pending: &[Pending]) -> Res<()> {
    if pending.is_empty() {
        return match std::fs::remove_file(dir.join(PENDING_FILE)) {
            Err(e) if e.kind() != std::io::ErrorKind::NotFound => Err(e.into()),
            _ => Ok(()),
        };
    }
    identity::write_private(&dir.join(PENDING_FILE), &serde_json::to_vec_pretty(pending)?)
}

fn add_pending(dir: &Path, entry: Pending) -> Res<()> {
    let mut pending = load_pending(dir).unwrap_or_default();
    pending.retain(|p| p.device.id != entry.device.id);
    pending.push(entry);
    let extra = pending.len().saturating_sub(PENDING_KEPT);
    pending.drain(..extra);
    save_pending(dir, &pending)
}

/// Asks the hub again for each pending sign-out; one it answers (done or refused) is dropped.
fn retry_pending(dir: &Path) {
    let Ok(pending) = load_pending(dir) else { return };
    if pending.is_empty() {
        return;
    }
    let left: Vec<Pending> = pending
        .into_iter()
        .filter(|p| {
            let answered = Hub::new(&p.hub, p.device.clone(), Some(p.user_id.clone()))
                .and_then(|hub| hub_sign_out(&hub));
            matches!(answered, Err(e) if !e.is::<HubError>())
        })
        .collect();
    if let Err(e) = save_pending(dir, &left) {
        eprintln!("cmux-rd linux-host: {}: {e}", dir.join(PENDING_FILE).display());
    }
}

#[cfg(test)]
#[path = "serving_tests.rs"]
mod tests;
