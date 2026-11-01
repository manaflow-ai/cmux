//! Read the existing VM identity without rotating keys or repairing permissions.
//! Directory handles and openat(O_NOFOLLOW) keep every component pinned while
//! reading. Only the role's uid may own or write the private files.

use std::ffi::CString;
use std::fs::{File, OpenOptions};
use std::io::Read;
use std::os::fd::{AsRawFd, FromRawFd};
use std::os::unix::fs::{MetadataExt, OpenOptionsExt};

use base64::{Engine as _, engine::general_purpose::STANDARD};
use cmux_server_core::install_key::{InstallKey, SystemRandom};
use serde::Deserialize;
use serde_json::Value;
use x25519_dalek::{PublicKey, StaticSecret};
use zeroize::{Zeroize, Zeroizing};

use super::client::{CloudClient, Http};
use super::wire::Bound;
use crate::config::Paths;

const UNAVAILABLE: &str = "protected VM identity unavailable";

pub(super) struct ReceiverIdentity {
    pub bound: Bound,
    pub install_public_jwk: Value,
    pub wg_public: String,
    wg_private: Zeroizing<[u8; 32]>,
}

impl PartialEq for ReceiverIdentity {
    fn eq(&self, other: &Self) -> bool {
        self.bound == other.bound
            && self.install_public_jwk == other.install_public_jwk
            && self.wg_public == other.wg_public
            && self.wg_private.as_slice() == other.wg_private.as_slice()
    }
}

#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct SavedInstall {
    instance_id: String,
    pkcs8: String,
}
impl Drop for SavedInstall {
    fn drop(&mut self) {
        self.pkcs8.zeroize();
    }
}
#[derive(Deserialize)]
#[serde(deny_unknown_fields)]
struct SavedWg {
    instance_id: String,
    private_key: String,
    public_key: String,
}
impl Drop for SavedWg {
    fn drop(&mut self) {
        self.private_key.zeroize();
    }
}

fn child(dir: &File, name: &str, directory: bool, uid: u32) -> Result<File, String> {
    let name = CString::new(name).map_err(|_| UNAVAILABLE)?;
    let flags = libc::O_RDONLY
        | libc::O_CLOEXEC
        | libc::O_NOFOLLOW
        | libc::O_NONBLOCK
        | if directory { libc::O_DIRECTORY } else { 0 };
    // SAFETY: the directory descriptor and nul-terminated component are live;
    // successful openat returns a new owned descriptor.
    let fd = unsafe { libc::openat(dir.as_raw_fd(), name.as_ptr(), flags) };
    if fd < 0 {
        return Err(UNAVAILABLE.into());
    }
    // SAFETY: fd was just returned by openat and has exactly one owner.
    let file = unsafe { File::from_raw_fd(fd) };
    check(&file, directory, uid)?;
    Ok(file)
}

fn check(file: &File, directory: bool, uid: u32) -> Result<(), String> {
    let meta = file.metadata().map_err(|_| UNAVAILABLE)?;
    if meta.uid() != uid
        || meta.mode() & 0o7022 != 0
        || (directory && !meta.is_dir())
        || (!directory
            && (!meta.is_file()
                || meta.mode() & 0o077 != 0
                || meta.nlink() != 1
                || meta.len() > 65536))
    {
        return Err(UNAVAILABLE.into());
    }
    Ok(())
}

fn read<T: serde::de::DeserializeOwned>(mut file: File) -> Result<T, String> {
    let mut bytes = Zeroizing::new(Vec::new());
    file.by_ref().take(65537).read_to_end(&mut bytes).map_err(|_| UNAVAILABLE)?;
    if bytes.len() > 65536 {
        return Err(UNAVAILABLE.into());
    }
    serde_json::from_slice(&bytes).map_err(|_| UNAVAILABLE.into())
}

pub(super) fn load(paths: &Paths, instance: &str) -> Result<ReceiverIdentity, String> {
    // The system root is kernel-owned; a test root is a private temporary dir.
    let root = OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_DIRECTORY | libc::O_NOFOLLOW | libc::O_CLOEXEC)
        .open(paths.root())
        .map_err(|_| UNAVAILABLE)?;
    // SAFETY: geteuid has no arguments or memory effects.
    let uid = if paths.is_system_root() { 0 } else { unsafe { libc::geteuid() } };
    check(&root, true, uid)?;
    let var = child(&root, "var", true, uid)?;
    let lib = child(&var, "lib", true, uid)?;
    let state = child(&lib, "cmux", true, uid)?;
    if state.metadata().map_err(|_| UNAVAILABLE)?.mode() & 0o077 != 0 {
        return Err(UNAVAILABLE.into());
    }
    let bound = read(child(&state, "bound.json", false, uid)?)?;
    let install_dir = child(&state, "install", true, uid)?;
    let install: SavedInstall = read(child(&install_dir, "key.json", false, uid)?)?;
    let wg_dir = child(&state, "wg", true, uid)?;
    let wg: SavedWg = read(child(&wg_dir, "key.json", false, uid)?)?;
    if install.instance_id != instance || wg.instance_id != instance {
        return Err(UNAVAILABLE.into());
    }
    let key = InstallKey::from_pkcs8_base64url(&install.pkcs8, &SystemRandom::new())
        .map_err(|_| UNAVAILABLE)?;
    let decoded = Zeroizing::new(STANDARD.decode(&wg.private_key).map_err(|_| UNAVAILABLE)?);
    let private =
        Zeroizing::new(<[u8; 32]>::try_from(decoded.as_slice()).map_err(|_| UNAVAILABLE)?);
    if Zeroizing::new(STANDARD.encode(private.as_slice())).as_str() != wg.private_key
        || private.iter().all(|b| *b == 0)
        || STANDARD.encode(PublicKey::from(&StaticSecret::from(*private)).as_bytes())
            != wg.public_key
    {
        return Err(UNAVAILABLE.into());
    }
    Ok(ReceiverIdentity {
        bound,
        install_public_jwk: key.public_jwk(),
        wg_public: wg.public_key.clone(),
        wg_private: private,
    })
}

/// Check the protected files both before and after the bounded Cloud read.
/// Rebinding, clone detection or key replacement invalidates the whole reply.
pub(super) fn reply<H: Http>(
    paths: &Paths,
    instance: &str,
    client: &mut CloudClient<H>,
    now_wall_ms: u64,
) -> Result<Value, String> {
    checked_snapshot(paths, instance, client, now_wall_ms)?
        .1
        .public_reply(std::time::Instant::now())
}

fn checked_snapshot<H: Http>(
    paths: &Paths,
    instance: &str,
    client: &mut CloudClient<H>,
    now_wall_ms: u64,
) -> Result<(ReceiverIdentity, super::receiver::ReceiverSnapshot), String> {
    let elapsed = cmux_link::elapsed::Elapsed::system().ok_or(UNAVAILABLE)?;
    let started = std::time::Instant::now();
    let before = load(paths, instance)?;
    if &before.bound != client.bound() || before.install_public_jwk != client.install_public_jwk() {
        client.clear_token();
        return Err(UNAVAILABLE.into());
    }
    let snapshot =
        client.receiving_policy_with_elapsed(&before.wg_public, now_wall_ms, started, elapsed)?;
    if before != load(paths, instance)? {
        client.clear_token();
        return Err(UNAVAILABLE.into());
    }
    snapshot.time(std::time::Instant::now()).ok_or(UNAVAILABLE)?;
    Ok((before, snapshot))
}

/// Kept separate from the public agent reply: private bootstrap is available
/// only to the root role's authenticated child chain.
pub(super) fn bootstrap<H: Http>(
    paths: &Paths,
    instance: &str,
    client: &mut CloudClient<H>,
    now_wall_ms: u64,
) -> Result<super::private_bootstrap::NativeBootstrap, String> {
    let (identity, snapshot) = checked_snapshot(paths, instance, client, now_wall_ms)?;
    let binding = super::receiver::ReceiverBinding::from_original(
        &identity.bound,
        &identity.wg_public,
        &identity.install_public_jwk,
    )?;
    super::private_bootstrap::NativeBootstrap::new(
        binding,
        snapshot.keys().clone(),
        identity.wg_private,
        snapshot.policy().receiver_generation.clone().ok_or(UNAVAILABLE)?,
    )
}
