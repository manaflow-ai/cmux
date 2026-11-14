//! Keeps this Mac's Cloud tunnel ([`super::tunnel`]) running while the
//! device is joined and someone is signed in, so the ssh backup carrier has
//! its hub on `<workspace state dir>/carrier/tunnel.sock`
//! ([`super::ssh::default_hub`], the socket a dial and `carrier capabilities`
//! read). The cmux link runs it (`link/carrier_tunnel.rs`): the link is the
//! one process on a Mac that holds the machine's WireGuard key (#39120), so
//! the key never leaves its holder.
//!
//! - **Joined**: [`Keeper::joined`] says who the device is now (the join
//!   record, the node key read under the held lock, the device's install
//!   key), or `None` (not joined, left, revoked, a copied home).
//! - **Signed in**: [`Keeper::token`] asks the signed-in app for the person's
//!   token (`auth.token`); it is asked again for every attach, and every
//!   [`KeeperTiming::sign_in_every`] while the hub runs. No answer (signed
//!   out, no app) stops the hub.
//! - **Restart**: a supervisor that ends by itself (out of attempts, refused)
//!   starts again after a doubling, jittered wait; a team with no provider
//!   mesh waits [`KeeperTiming::unavailable_wait`]. A hub process that is
//!   killed is restarted by the supervisor itself, on its retry backoff.
//! - A second supervisor on the same socket ([`tunnel::StartError::Held`])
//!   is left to serve it; this one looks again later.
//!
//! Nothing here logs a key or a token.

use std::path::PathBuf;
use std::sync::Arc;
use std::time::Duration;

use cmux_server_core::install_key::InstallKey;
use zeroize::Zeroizing;

use super::answer::{Credential, HttpSource};
use super::tunnel::{self, HubLauncher, TunnelIdentity, TunnelPlan, TunnelStatus, TunnelTiming};

/// This device as the tunnel enrolls it, read afresh each time.
pub(crate) struct Joined {
    /// The joined machine (`machine_…`).
    pub machine_id: String,
    /// The device name the enrollment signs ([`device_name`]).
    pub name: String,
    /// The machine's team (`team_…`): the token is asked for it and sent as
    /// `x-cmux-team`.
    pub team: String,
    /// The cmux-platform origin the machine joined through (attach).
    pub platform: String,
    /// The node key, read under the held key lock.
    pub wg_private: Zeroizing<[u8; 32]>,
    /// The device's own install key (ES256), which signs every mesh request.
    pub install: Arc<InstallKey>,
}

impl Joined {
    /// Whether `other` is the same device of the same team on the same
    /// platform (a rekey changes only the key, which the supervisor follows).
    fn same_device(&self, other: &Self) -> bool {
        self.machine_id == other.machine_id
            && self.team == other.team
            && self.platform == other.platform
    }
}

/// Who the device is now; `Ok(None)` when the tunnel must not run.
pub(crate) type JoinedSource = Arc<dyn Fn() -> Result<Option<Joined>, String> + Send + Sync>;

/// The signed-in person's token for `team`, to send to `platform`; `Err`
/// when there is none (signed out, no app, another deployment's sign-in).
/// It may block: it is always called off the async runtime.
pub(crate) type TokenSource =
    Arc<dyn Fn(&str, &str) -> Result<Zeroizing<String>, String> + Send + Sync>;

/// What the keeper did, for the link's log and for tests.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) enum KeeperEvent {
    /// A supervisor started for this device.
    Started,
    /// Its tunnel is up: the hub serves the socket.
    Ready,
    /// It ended by itself, with its final status.
    Ended(TunnelStatus),
    /// It was stopped: `left` (no longer joined) or `signed_out`.
    Stopped(&'static str),
    /// The wait before the next start.
    Waiting(Duration),
    /// Another supervisor serves the socket.
    Held,
    /// A supervisor could not be set up (no VM API, no lock); the keeper
    /// looks again later.
    Unstarted(String),
}

/// Delays; [`KeeperTiming::default`] for real use.
#[derive(Clone, Copy, Debug)]
pub(crate) struct KeeperTiming {
    /// How often the join is looked at (a file read), while the hub runs and
    /// while it waits for a join or a sign-in.
    pub check_every: Duration,
    /// How often the app is asked whether someone is still signed in while
    /// the hub runs (one token mint by the app).
    pub sign_in_every: Duration,
    pub restart_floor: Duration,
    pub restart_ceiling: Duration,
    /// The wait after the team was found to have no provider mesh.
    pub unavailable_wait: Duration,
    pub tunnel: TunnelTiming,
}

impl Default for KeeperTiming {
    fn default() -> Self {
        Self {
            check_every: Duration::from_secs(30),
            sign_in_every: Duration::from_secs(5 * 60),
            restart_floor: Duration::from_secs(2),
            restart_ceiling: Duration::from_secs(5 * 60),
            unavailable_wait: Duration::from_secs(30 * 60),
            tunnel: TunnelTiming::default(),
        }
    }
}

/// One keeper's inputs.
pub(crate) struct Keeper {
    pub joined: JoinedSource,
    pub token: TokenSource,
    /// The hub's socket ([`default_socket`] for real use).
    pub socket: PathBuf,
    pub launcher: Arc<dyn HubLauncher>,
    /// The VM API origin; `None` derives it from the platform origin
    /// ([`super::tunnel_cli::vm_api_of`]).
    pub vm_api: Option<String>,
    pub timing: KeeperTiming,
    /// The retry delay for a ceiling (full jitter).
    pub jitter: fn(Duration) -> Duration,
    pub on_event: Arc<dyn Fn(&KeeperEvent) + Send + Sync>,
}

/// `<workspace state dir>/carrier/tunnel.sock`, the socket the dial reads.
pub(crate) fn default_socket() -> Option<PathBuf> {
    super::ssh::default_hub()
}

/// The session's full-jitter draw, as `carrier tunnel` uses.
pub(crate) fn jitter(ceiling: Duration) -> Duration {
    super::jitter(ceiling)
}

/// `name` as the VM API takes a device name (`tunnel_cli::valid_name`):
/// other characters dropped, at most 63 bytes, starting alphanumeric; a name
/// with nothing left is `cmux-mac`.
pub(crate) fn device_name(name: &str) -> String {
    let kept: String = name
        .chars()
        .filter(|c| c.is_ascii_alphanumeric() || "._ -".contains(*c))
        .skip_while(|c| !c.is_ascii_alphanumeric())
        .take(63)
        .collect();
    let kept = kept.trim_end().to_owned();
    if super::tunnel_cli::valid_name(&kept) { kept } else { "cmux-mac".to_owned() }
}

/// How one supervisor's run ended.
enum Run {
    Ended { status: TunnelStatus, ready: bool },
    Stopped(&'static str),
}

impl Keeper {
    /// Runs for good: the caller drops it to stop (the link's serve ends).
    /// A hub it runs stops with it (`TunnelHandle` and the hub's owner).
    pub(crate) async fn run(self) {
        // The hub is this process's child: an inherited `SIGCHLD = SIG_IGN`
        // would let the kernel reap it behind its owner thread.
        if !tunnel::reap_own_children() {
            self.emit(KeeperEvent::Unstarted("cannot reset SIGCHLD".into()));
            return;
        }
        let mut restarts = 0u32;
        loop {
            let Some(joined) = self.joined_now() else {
                tokio::time::sleep(self.timing.check_every).await;
                continue;
            };
            if self.ask(&joined).await.is_err() {
                tokio::time::sleep(self.timing.check_every).await;
                continue;
            }
            let plan = match self.plan(&joined) {
                Ok(plan) => plan,
                Err(why) => {
                    self.emit(KeeperEvent::Unstarted(why));
                    tokio::time::sleep(self.timing.unavailable_wait).await;
                    continue;
                }
            };
            let handle = match tunnel::start(plan) {
                Ok(handle) => handle,
                Err(tunnel::StartError::Held { .. }) => {
                    self.emit(KeeperEvent::Held);
                    tokio::time::sleep(self.timing.check_every).await;
                    continue;
                }
                Err(error) => {
                    self.emit(KeeperEvent::Unstarted(error.to_string()));
                    restarts = restarts.saturating_add(1);
                    self.wait(self.restart_delay(restarts)).await;
                    continue;
                }
            };
            self.emit(KeeperEvent::Started);
            match self.watch(handle, &joined).await {
                Run::Stopped(why) => {
                    restarts = 0;
                    self.emit(KeeperEvent::Stopped(why));
                }
                Run::Ended { status, ready } => {
                    if ready {
                        restarts = 0;
                    }
                    restarts = restarts.saturating_add(1);
                    let delay = match status {
                        TunnelStatus::Unavailable(_) => self.timing.unavailable_wait,
                        _ => self.restart_delay(restarts),
                    };
                    self.emit(KeeperEvent::Ended(status));
                    self.wait(delay).await;
                }
            }
        }
    }

    fn emit(&self, event: KeeperEvent) {
        (self.on_event)(&event);
    }

    async fn wait(&self, delay: Duration) {
        self.emit(KeeperEvent::Waiting(delay));
        tokio::time::sleep(delay).await;
    }

    /// The wait before start number `restarts` (1-based): the floor doubling
    /// up to the ceiling, full jitter, never under half the floor.
    fn restart_delay(&self, restarts: u32) -> Duration {
        let timing = &self.timing;
        let exponent = restarts.saturating_sub(1).min(16);
        let ceiling =
            timing.restart_floor.saturating_mul(1 << exponent).min(timing.restart_ceiling);
        (self.jitter)(ceiling).max(timing.restart_floor.checked_div(2).unwrap_or_default())
    }

    fn joined_now(&self) -> Option<Joined> {
        match (self.joined)() {
            Ok(joined) => joined,
            Err(why) => {
                self.emit(KeeperEvent::Unstarted(why));
                None
            }
        }
    }

    /// Asks for the person's token for `joined`, off the runtime.
    async fn ask(&self, joined: &Joined) -> Result<Zeroizing<String>, String> {
        let token = Arc::clone(&self.token);
        let (team, platform) = (joined.team.clone(), joined.platform.clone());
        tokio::task::spawn_blocking(move || token(&team, &platform))
            .await
            .map_err(|_| "the sign-in could not be asked for".to_owned())?
    }

    fn plan(&self, joined: &Joined) -> Result<TunnelPlan, String> {
        let platform = crate::cli::secure_cloud_origin(joined.platform.trim())?;
        let vm_api = match &self.vm_api {
            Some(vm_api) => vm_api.clone(),
            None => super::tunnel_cli::vm_api_of(&platform)
                .map(str::to_owned)
                .ok_or_else(|| format!("no VM API is known for {platform}"))?,
        };
        let token = Arc::clone(&self.token);
        let (team, asked_at) = (joined.team.clone(), platform.clone());
        let ask: super::answer::AskCredential = Arc::new(move || token(&team, &asked_at));
        let source = HttpSource::new(platform, Credential::Ask(ask), Some(joined.team.clone()))?;
        let source_of = Arc::clone(&self.joined);
        let machine = joined.machine_id.clone();
        let identity: tunnel::IdentitySource = Arc::new(move || match source_of()? {
            Some(now) if now.machine_id == machine => Ok(TunnelIdentity {
                machine_id: now.machine_id,
                name: now.name,
                wg_private: now.wg_private,
                install: now.install,
            }),
            _ => Err("this device is no longer joined".to_owned()),
        });
        Ok(TunnelPlan {
            identity,
            platform: Arc::new(source),
            vm_api,
            socket: self.socket.clone(),
            launcher: Arc::clone(&self.launcher),
            timing: self.timing.tunnel,
            jitter: self.jitter,
        })
    }

    /// Follows one supervisor until it ends, the device leaves, or nobody is
    /// signed in any more.
    async fn watch(&self, handle: tunnel::TunnelHandle, joined: &Joined) -> Run {
        let mut status = handle.status();
        let mut ready = false;
        let start = tokio::time::Instant::now();
        let mut check = tokio::time::interval_at(
            start + self.timing.check_every,
            self.timing.check_every.max(Duration::from_millis(1)),
        );
        let mut sign_in = tokio::time::interval_at(
            start + self.timing.sign_in_every,
            self.timing.sign_in_every.max(Duration::from_millis(1)),
        );
        check.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);
        sign_in.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Delay);
        loop {
            tokio::select! {
                changed = status.changed() => {
                    let now = status.borrow_and_update().clone();
                    if changed.is_err() || now.is_final() {
                        let status = handle.finished().await;
                        return Run::Ended { status, ready };
                    }
                    if matches!(now, TunnelStatus::Ready { .. }) && !ready {
                        ready = true;
                        self.emit(KeeperEvent::Ready);
                    }
                }
                _ = check.tick() => {
                    let still = self.joined_now().is_some_and(|now| now.same_device(joined));
                    if !still {
                        handle.stop().await;
                        return Run::Stopped("left");
                    }
                }
                _ = sign_in.tick() => {
                    if self.ask(joined).await.is_err() {
                        handle.stop().await;
                        return Run::Stopped("signed_out");
                    }
                }
            }
        }
    }
}

#[cfg(test)]
#[path = "tunnel_keeper_tests.rs"]
mod tests;
