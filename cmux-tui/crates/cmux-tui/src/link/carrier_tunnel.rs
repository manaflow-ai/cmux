//! The Cloud tunnel hub for the ssh backup carrier, run by `cmux link serve`
//! ([`crate::carrier::tunnel_keeper`]). The link is the one process on a Mac
//! that holds the machine's WireGuard key (#39120), and the tunnel enrolls that
//! same key, so it runs here and the key never leaves its holder:
//!
//! - **Key**: the node key, read with [`acpmux::cli::mesh_node_key::read_held`]
//!   under the key lock this link holds, and only when that lock is in the
//!   acpmux home the app recorded (the node key's own directory). The keeper
//!   keeps no share of the lock ([`Weak`]): a link that lets go of it stops
//!   the tunnel at its next read.
//! - **Join**: acpmux's join record in that home
//!   ([`acpmux::cli::cloud_join::joined_device_at`]): the machine, its team,
//!   its name and its platform origin. Not joined, left, revoked or copied:
//!   no tunnel.
//! - **Install key**: the device's own ES256 key, made once and kept 0600 in
//!   the link's state directory ([`INSTALL_KEY_FILE`]); the platform takes the
//!   install key an enrollment signs with (cmux-platform `mesh.ts`).
//! - **Sign-in**: the signed-in app's `auth.token` for the machine's team
//!   ([`crate::cli::app_token`]), asked for every attach and while the hub
//!   runs; a token is sent only to the platform of the deployment that issued
//!   it ([`same_deployment`]). No answer stops the hub.

use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex, PoisonError, Weak};

use cmux_link::key_holder::KeyHolder;
use cmux_server_core::install_key::{InstallKey, SystemRandom};
use zeroize::Zeroizing;

use crate::carrier::tunnel::ProcessHubLauncher;
use crate::carrier::tunnel_keeper::{self, Joined, Keeper, KeeperEvent, KeeperTiming};

/// The device install key's file in the link's state directory: PKCS#8, 0600.
pub(super) const INSTALL_KEY_FILE: &str = "carrier-device.key";

/// Keeps the tunnel for as long as the link serves; never returns unless it
/// cannot run at all (then it waits for good, as the other serve arms do).
pub(super) async fn keep(state_dir: PathBuf, key: Weak<KeyHolder>, acpmux_home: Option<PathBuf>) {
    match keeper(&state_dir, key, acpmux_home) {
        Ok(keeper) => keeper.run().await,
        Err(why) => eprintln!("cmux link: no Cloud tunnel: {why}"),
    }
    std::future::pending::<()>().await;
}

fn keeper(
    state_dir: &Path,
    key: Weak<KeyHolder>,
    acpmux_home: Option<PathBuf>,
) -> Result<Keeper, String> {
    let home = acpmux_home.ok_or("the app recorded no acpmux home")?;
    let held_dir = key.upgrade().map(|holder| holder.dir().to_path_buf()).ok_or("no key lock")?;
    if canonical(&held_dir) != canonical(&home) {
        return Err(format!(
            "the key lock is in {}, not the node key's home {}",
            held_dir.display(),
            home.display()
        ));
    }
    let socket = tunnel_keeper::default_socket().ok_or("no workspace state directory")?;
    let exe = std::env::current_exe().map_err(|_| "this cmux binary's path is unknown")?;
    let launcher = ProcessHubLauncher::new(exe)?;
    // Made on first need: a link of a machine that never joins writes no key.
    let install =
        DeviceInstallKey { path: state_dir.join(INSTALL_KEY_FILE), key: Mutex::new(None) };
    let joined: tunnel_keeper::JoinedSource =
        Arc::new(move || joined_device(&home, &key, &install));
    Ok(Keeper {
        joined,
        token: Arc::new(|team: &str, platform: &str| person_token(team, platform)),
        socket,
        launcher: Arc::new(launcher),
        vm_api: None,
        timing: KeeperTiming::default(),
        jitter: tunnel_keeper::jitter,
        on_event: Arc::new(log_event),
    })
}

fn canonical(path: &Path) -> PathBuf {
    std::fs::canonicalize(path).unwrap_or_else(|_| path.to_path_buf())
}

/// The device install key, loaded (or made) the first time a joined device needs it.
struct DeviceInstallKey {
    path: PathBuf,
    key: Mutex<Option<Arc<InstallKey>>>,
}

impl DeviceInstallKey {
    fn get(&self) -> Result<Arc<InstallKey>, String> {
        let mut held = self.key.lock().unwrap_or_else(PoisonError::into_inner);
        if let Some(key) = held.as_ref() {
            return Ok(Arc::clone(key));
        }
        let key = Arc::new(load_or_create_install_key(&self.path)?);
        *held = Some(Arc::clone(&key));
        Ok(key)
    }
}

/// This device now: the join record, the node key under the held lock and the
/// device install key.
fn joined_device(
    home: &Path,
    key: &Weak<KeyHolder>,
    install: &DeviceInstallKey,
) -> Result<Option<Joined>, String> {
    let Some(holder) = key.upgrade() else { return Ok(None) };
    let Some(device) = acpmux::cli::cloud_join::joined_device_at(home) else { return Ok(None) };
    let wg_private = acpmux::cli::mesh_node_key::read_held(home, &holder)
        .map_err(|error| format!("the node key could not be read: {error:#}"))?;
    Ok(Some(Joined {
        machine_id: device.machine_id,
        name: tunnel_keeper::device_name(&device.name),
        team: device.team_id,
        platform: device.hub_origin,
        wg_private,
        install: install.get()?,
    }))
}

/// The signed-in person's token for `team`, from the app, only when the app's
/// sign-in is the deployment `platform` belongs to and the token acts in `team`.
fn person_token(team: &str, platform: &str) -> Result<Zeroizing<String>, String> {
    let token = crate::cli::app_token(team)?;
    if token.team != team {
        return Err("the app's sign-in is for another team".into());
    }
    if !same_deployment(platform, &token.api_origin) {
        return Err("the app's sign-in is for another cmux deployment".into());
    }
    Ok(token.token)
}

/// Whether the owner API `api` (where the app's token was issued) and the
/// platform origin `platform` (where the machine joined) are one deployment.
/// An unknown platform (a local one) takes only a token from a loopback API.
pub(super) fn same_deployment(platform: &str, api: &str) -> bool {
    use cmux_cloud_environment as env;
    let (platform, api) = (platform.trim_end_matches('/'), api.trim_end_matches('/'));
    let deployments =
        [env::PRODUCTION_DEPLOYMENT, env::STAGING_DEPLOYMENT, env::DEVELOPMENT_DEPLOYMENT];
    match deployments.iter().find(|deployment| deployment.platform_origin == platform) {
        Some(deployment) => deployment.api_origin.trim_end_matches('/') == api,
        None => loopback(platform) && loopback(api),
    }
}

fn loopback(origin: &str) -> bool {
    reqwest::Url::parse(origin)
        .ok()
        .is_some_and(|url| matches!(url.host_str(), Some("127.0.0.1" | "localhost" | "[::1]")))
}

/// The device install key at `path`, made (0600, synced) when there is none.
/// A file that is not a regular file, or not a key, is refused, never replaced:
/// the platform knows the device by it.
pub(super) fn load_or_create_install_key(path: &Path) -> Result<InstallKey, String> {
    let rng = SystemRandom::new();
    match std::fs::symlink_metadata(path) {
        Ok(meta) if !meta.file_type().is_file() => {
            return Err(format!("{} is not a regular file", path.display()));
        }
        Ok(_) => {
            let bytes = Zeroizing::new(
                std::fs::read(path).map_err(|e| format!("read {}: {e}", path.display()))?,
            );
            return InstallKey::from_pkcs8(&bytes, &rng)
                .map_err(|_| format!("{} is not an install key", path.display()));
        }
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => {}
        Err(error) => return Err(format!("{}: {error}", path.display())),
    }
    let key = InstallKey::generate(&rng)?;
    super::state::write_private_synced(path, key.pkcs8())
        .map_err(|e| format!("write {}: {e}", path.display()))?;
    Ok(key)
}

fn log_event(event: &KeeperEvent) {
    match event {
        // Quiet ones: the wait follows a line already written.
        KeeperEvent::Waiting(_) => {}
        KeeperEvent::Started => eprintln!("cmux link: Cloud tunnel starting"),
        KeeperEvent::Ready => eprintln!("cmux link: Cloud tunnel ready"),
        KeeperEvent::Ended(status) => eprintln!("cmux link: Cloud tunnel ended: {status:?}"),
        KeeperEvent::Stopped(why) => eprintln!("cmux link: Cloud tunnel stopped: {why}"),
        KeeperEvent::Held => eprintln!("cmux link: another process serves the Cloud tunnel"),
        KeeperEvent::Unstarted(why) => eprintln!("cmux link: Cloud tunnel not started: {why}"),
    }
}

#[cfg(test)]
#[path = "carrier_tunnel_tests.rs"]
mod tests;
