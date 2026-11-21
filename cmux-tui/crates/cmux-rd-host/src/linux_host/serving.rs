//! Which account this desktop's host serves (review F1 of #45369). One invariant, kept here and
//! only here: the host serves only the identity it last signed in as, and on a joined machine
//! that is the current join's. Every sign-in goes through [`join`] or [`person`]:
//!
//! - Before a sign-in for any other identity, and when a sign-in fails, the previous identity
//!   is torn down ([`tear_down`]), in this order: the hub asked to sign the old device out (an
//!   offline hub is asked again later, [`PENDING_FILE`]), the host unit stopped and its process
//!   verified gone, its local records deleted (only once one of the two worked). Only then does
//!   the new identity sign in, and the caller starts the unit.
//! - A sign-in that fails leaves the host off, never on the old account.
//! - The running host keeps it itself: its hub link checks its records and its join every
//!   [`WATCH_EVERY`] and stops its session and exits the moment they are not what it started as
//!   ([`Serving::changed`], [`wait_serving`]), so no caller's failure (a `systemctl` that
//!   failed, a unit started by hand) leaves it serving.
//! - Every writer of the records holds [`Lock`], so two sign-ins never interleave.
//! - A joined machine's identity is its join ([`machine::Joined::is`]: the acpmux home, machine
//!   id and credential generation), checked here before the host is installed and by `run`
//!   before it serves, so a host started for an earlier join never serves.
//! - A person's own `enable` is refused while the machine has a live join ([`join_owner`]).

use super::machine;
use super::{machine_renewal, with_fresh_identity, Fatal};
use crate::Res;
use cmux_file_lock::{FileLock, Kind};
use cmux_hub_host::hub::{Hub, HubError};
use cmux_hub_host::identity::{self, Account, Device};
use serde::{Deserialize, Serialize};
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

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
/// the host's start. Each keeps its device key (it signs the sign-out), so the file is this
/// user's 0600 file, written only under [`Lock`], and kept short: an entry the hub answers
/// (signed out, or a device it does not know) goes, and so does one older than
/// [`PENDING_MAX_AGE_MS`].
pub(super) const PENDING_FILE: &str = "pending-sign-out.json";
/// At most this many are kept; older ones are dropped (their device keys are deleted, so the
/// host cannot serve them either way).
const PENDING_KEPT: usize = 8;
/// How long an unanswered sign-out is asked again: 30 days, the longest a desktop's sign-in is
/// anchored, after which the hub has ended that device's sign-in by itself.
pub(super) const PENDING_MAX_AGE_MS: u64 = 30 * 24 * 60 * 60 * 1000;

#[derive(Serialize, Deserialize, Clone)]
struct Pending {
    hub: String,
    user_id: String,
    device: Device,
    /// When it was first asked (ms since the epoch); an entry with none is dropped.
    #[serde(default)]
    since_ms: u64,
}

impl Pending {
    fn fresh(&self, now_ms: u64) -> bool {
        now_ms.saturating_sub(self.since_ms) <= PENDING_MAX_AGE_MS
    }
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
/// there (from [`machine::JOINED_FILE`]; or [`JOINING_FILE`], kept when a join's sign-in failed
/// or has not finished; or `ACPMUX_HOME` when the join has not begun).
pub(super) fn join_owner(dir: &Path) -> Res<Option<String>> {
    let recorded = match machine::Joined::load(dir)? {
        Some(joined) => machine::load(&joined.acpmux_home)?.is_some(),
        None => false,
    };
    let joining = match joining_home(dir)? {
        Some(home) => machine::load(&home)?.is_some(),
        None => false,
    };
    if !recorded && !joining && machine::current()?.is_none() {
        return Ok(None);
    }
    let account = match (recorded, Account::load(dir)?) {
        (true, Some(account)) => account.user_id,
        _ => "this machine's account".to_owned(),
    };
    Ok(Some(account))
}

/// The host as the join `credential` from `home`: its device, signed in. The same join keeps its
/// device once the hub still signs it in as the recorded account, and so does a record from
/// before joins were marked, which is then marked; anything else is torn down first. On an
/// error the host is off.
pub(super) fn join(
    dir: &Path,
    hub_url: &str,
    home: &Path,
    credential: machine::MachineCredential,
    unit: &dyn Unit,
) -> Res<Device> {
    save_joining(dir, home)?;
    retry_pending(dir);
    let previous = Previous::load(dir)?;
    if let Some(Previous { account: Some(account), device: Some(device), joined: Some(joined) }) =
        &previous
    {
        let unmarked = joined.unmarked_from(home);
        if (joined.is(home, &credential) || unmarked) && account.hub == hub_url {
            let renewal = machine_renewal(credential.clone());
            let checked = Hub::with_renewal(hub_url, device.clone(), None, renewal)
                .and_then(|hub| hub.session().map(|_| hub.user_id()));
            match checked {
                // The hub signs the join in as the recorded account: the host serves the join's.
                Ok(Some(user)) if user == account.user_id => {
                    let marked = if unmarked {
                        machine::Joined::of(home, &credential).save(dir)
                    } else {
                        Ok(())
                    };
                    match marked {
                        Ok(()) => return Ok(device.clone()),
                        Err(e) => {
                            tear_down(dir, previous, unit)?;
                            return Err(e);
                        }
                    }
                }
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
/// join's, or it serves nothing (a unit started for an earlier join, or after a leave). A
/// record from before joins were marked goes through [`join`] instead, so an update heals the
/// host at once rather than leaving it off until the daemon's next start.
pub(super) fn current_join(
    dir: &Path,
    hub_url: &str,
    joined: &machine::Joined,
) -> Res<machine::MachineCredential> {
    let credential = machine::load(&joined.acpmux_home)?
        .ok_or_else(|| Fatal::needs("This machine's join was revoked or removed", Fatal::JOIN))?;
    if joined.unmarked_from(&joined.acpmux_home) {
        // Nothing serves yet at `run`'s start, so there is no unit to stop first.
        join(dir, hub_url, &joined.acpmux_home, credential.clone(), &ThisProcess)?;
        return Ok(credential);
    }
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

/// Takes `previous` off this desktop, in this order (review F1 of #45369, third round): the hub
/// asked to sign its device out, which ends its sessions there even if its process never hears;
/// the unit stopped and its process verified gone; then its records deleted. The records go
/// only once the hub signed the device out or its process is gone, never when both failed (a
/// hub that cannot be reached is asked again later). A host process that is still running
/// stops itself once its records change ([`Serving::changed`]). An error unless the host
/// process is verified gone.
fn tear_down(dir: &Path, previous: Option<Previous>, unit: &dyn Unit) -> Res<()> {
    let revoked = match &previous {
        Some(previous) => sign_out(dir, previous),
        None => true,
    };
    let stopped = unit.stop();
    if revoked || stopped.is_ok() {
        super::forget_sign_in(dir)?;
    }
    match stopped {
        Ok(()) => Ok(()),
        Err(e) if revoked => Err(format!(
            "the earlier sign-in is signed out and deleted, but its host may still be running ({e}); it stops by itself within {} s now that its records are gone",
            WATCH_EVERY.as_secs()
        )
        .into()),
        Err(e) => Err(format!(
            "nothing was deleted: the hub did not sign the earlier device out and its host may still be running ({e})"
        )
        .into()),
    }
}

/// Asks the hub to sign `previous`'s device out: ends its sessions and drops its anchor. A
/// person's device signs out with its own key; a join's with its credential when that is still
/// the one it signed in with (once the join is replaced its credential is gone, and no session
/// can be made for its device again). Whether the hub no longer takes that device: it signed it
/// out, or answered that it does not know it or let it in; or there was none.
fn sign_out(dir: &Path, previous: &Previous) -> bool {
    let (Some(account), Some(device)) = (&previous.account, &previous.device) else { return true };
    let hub = match &previous.joined {
        None => Hub::new(&account.hub, device.clone(), Some(account.user_id.clone())),
        Some(joined) => match machine::load(&joined.acpmux_home) {
            Ok(Some(credential)) if joined.is(&joined.acpmux_home, &credential) => {
                Hub::with_renewal(&account.hub, device.clone(), None, machine_renewal(credential))
            }
            _ => {
                eprintln!(
                    "cmux-rd linux-host: the earlier join's credential is gone, so its device ({}) cannot be signed out from here",
                    device.id
                );
                return false;
            }
        },
    };
    let answered = hub.and_then(|hub| hub_sign_out(&hub));
    if signed_out(&answered) {
        if let Err(e) = answered {
            eprintln!(
                "cmux-rd linux-host: the hub does not take the earlier device ({}) any more ({e})",
                device.id
            );
        }
        return true;
    }
    let Err(e) = answered else { return true };
    match e.downcast_ref::<HubError>() {
        // A person's device signs out with its own key, kept until the hub confirms it.
        _ if previous.joined.is_none() => {
            eprintln!(
                "cmux-rd linux-host: the hub did not sign the earlier device ({}) out ({e}); asked again later",
                device.id
            );
            let pending = Pending {
                hub: account.hub.clone(),
                user_id: account.user_id.clone(),
                device: device.clone(),
                since_ms: cmux_hub_host::hub::now_ms(),
            };
            if let Err(e) = add_pending(dir, pending) {
                eprintln!("cmux-rd linux-host: {}: {e}", dir.join(PENDING_FILE).display());
            }
            false
        }
        Some(_) => {
            eprintln!(
                "cmux-rd linux-host: the hub refused to sign the earlier join's device ({}) out ({e})",
                device.id
            );
            false
        }
        None => {
            eprintln!(
                "cmux-rd linux-host: the hub did not answer the earlier join's sign-out ({e})"
            );
            false
        }
    }
}

/// How often the running host checks that it still is the identity it started as.
pub(super) const WATCH_EVERY: Duration = Duration::from_secs(2);

/// The identity `run` serves as: what any change of identity rewrites or deletes.
#[derive(PartialEq, Debug)]
pub(super) struct Serving {
    device: String,
    hub: String,
    user_id: String,
    joined: Option<machine::Joined>,
}

impl Serving {
    /// What this desktop's records sign it in as now; an error when it is not signed in.
    pub(super) fn now(dir: &Path) -> Res<Self> {
        let device = Device::load(dir)?.ok_or("no device record")?;
        let account = Account::load(dir)?.ok_or("no account record")?;
        Ok(Self {
            device: device.id,
            hub: account.hub,
            user_id: account.user_id,
            joined: machine::Joined::load(dir)?,
        })
    }

    /// Why a host serving as this must stop now, if it must: its records changed, went away or
    /// cannot be read, or (a join) the join's credential is gone or replaced. This is what makes
    /// the host itself keep the invariant, whatever failed in whoever tore it down.
    pub(super) fn changed(&self, dir: &Path) -> Option<String> {
        match Self::now(dir) {
            Ok(now) if now == *self => {}
            Ok(_) => return Some("this desktop's sign-in changed".into()),
            Err(e) => return Some(format!("this desktop's sign-in is gone ({e})")),
        }
        let joined = self.joined.as_ref()?;
        match machine::load(&joined.acpmux_home) {
            Ok(Some(credential)) if joined.is(&joined.acpmux_home, &credential) => None,
            Ok(Some(_)) => Some("this machine was joined again".into()),
            Ok(None) => Some("this machine's join was removed".into()),
            Err(e) => Some(format!("this machine's join cannot be read ({e})")),
        }
    }
}

/// Waits `wait`, checking every `every` that the host still is `serving`; why it is not, the
/// first time it is not (then at once). The host's hub link checks the same between its reads,
/// so it stops serving and exits within [`WATCH_EVERY`] whether its link is up or it waits to
/// connect again.
pub(super) fn wait_serving(
    serving: &Serving,
    dir: &Path,
    wait: Duration,
    every: Duration,
) -> Option<String> {
    let until = Instant::now() + wait;
    loop {
        if let Some(why) = serving.changed(dir) {
            return Some(why);
        }
        let left = until.saturating_duration_since(Instant::now());
        if left.is_zero() {
            return None;
        }
        std::thread::sleep(left.min(every));
    }
}

/// Next to the records: what every writer of them holds.
const LOCK_FILE: &str = "identity.lock";

/// This desktop's identity, held for one sign-in, enable or teardown: every writer of its
/// records takes it, so a person's `enable` and a join's never interleave. Released when
/// dropped, and by the kernel when the process ends.
pub(super) struct Lock {
    _held: FileLock,
}

/// Takes [`Lock`], waiting for whoever holds it.
pub(super) fn lock(dir: &Path) -> Res<Lock> {
    use std::os::unix::fs::OpenOptionsExt;
    identity::private_dir(dir)?;
    let file = std::fs::OpenOptions::new()
        .create(true)
        .truncate(false)
        .write(true)
        .mode(0o600)
        .custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC)
        .open(dir.join(LOCK_FILE))?;
    Ok(Lock { _held: FileLock::take(file, Kind::Exclusive)? })
}

/// Names the acpmux home of the last join that began signing this desktop in. It outlives a
/// failed join's teardown, so a person's `enable` stays refused while that home is joined
/// ([`join_owner`]), wherever it runs from.
pub(super) const JOINING_FILE: &str = "joining.json";

fn save_joining(dir: &Path, home: &Path) -> Res<()> {
    let record = machine::Joined { acpmux_home: home.to_owned(), ..Default::default() };
    identity::write_private(&dir.join(JOINING_FILE), &serde_json::to_vec_pretty(&record)?)
}

fn joining_home(dir: &Path) -> Res<Option<PathBuf>> {
    let Some(bytes) = identity::read_private(&dir.join(JOINING_FILE))? else { return Ok(None) };
    Ok(Some(serde_json::from_slice::<machine::Joined>(&bytes)?.acpmux_home))
}

/// Whether the hub confirmed a sign-out: it signed the device out, or answered that it does not
/// know the device or does not let it in (401, 403, 404), so it is gone there. Anything else
/// (no answer, a 5xx, a 429, another refusal) has not signed it out.
fn signed_out(answered: &Res<()>) -> bool {
    match answered {
        Ok(()) => true,
        Err(e) => e.downcast_ref::<HubError>().is_some_and(|h| matches!(h.status, 401 | 403 | 404)),
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
    let now = cmux_hub_host::hub::now_ms();
    let mut pending = load_pending(dir).unwrap_or_default();
    pending.retain(|p| p.device.id != entry.device.id && p.fresh(now));
    pending.push(entry);
    let extra = pending.len().saturating_sub(PENDING_KEPT);
    pending.drain(..extra);
    save_pending(dir, &pending)
}

/// Asks the hub again for each pending sign-out; one it confirms ([`signed_out`]) is dropped,
/// any other kept, and one past [`PENDING_MAX_AGE_MS`] is dropped unasked.
fn retry_pending(dir: &Path) {
    retry_pending_at(dir, cmux_hub_host::hub::now_ms());
}

fn retry_pending_at(dir: &Path, now_ms: u64) {
    let Ok(pending) = load_pending(dir) else { return };
    if pending.is_empty() {
        return;
    }
    let left: Vec<Pending> = pending
        .into_iter()
        .filter(|p| p.fresh(now_ms))
        .filter(|p| {
            let answered = Hub::new(&p.hub, p.device.clone(), Some(p.user_id.clone()))
                .and_then(|hub| hub_sign_out(&hub));
            !signed_out(&answered)
        })
        .collect();
    if let Err(e) = save_pending(dir, &left) {
        eprintln!("cmux-rd linux-host: {}: {e}", dir.join(PENDING_FILE).display());
    }
}

#[cfg(test)]
#[path = "serving_tests.rs"]
mod tests;
