//! This machine as the device hub's `machine` (docs/device-hub/PROTOCOL.md, "Permissions are per
//! Mac"): the lowercase hex HMAC-SHA256 of `cmux.device-hub.machine\n` and the machine's hardware
//! id, keyed by 32 random bytes in a file only this user reads. The Mac app computes the same value
//! (`CmuxNextDevices/DeviceMachine.swift`) from the same file, so the acpmux daemon's share host and
//! every build of the app name one Mac, and the hub keeps one device for it (Leo, 2026-11-18: "i
//! should be able to see into any connected mac or linux machine").
//!
//! - macOS: the hardware id is IOPlatformExpertDevice's `IOPlatformUUID` (`ioreg`), and the key
//!   `~/Library/Application Support/cmux-device-hub/machine.key`, the file the app reads.
//! - Linux: `/etc/machine-id` (or `/var/lib/dbus/machine-id`), and
//!   `$XDG_DATA_HOME/cmux-device-hub/machine.key` (`~/.local/share/...`).
//! - Elsewhere: none, and the device names no machine.
//!
//! The hardware id alone is no secret (any process can read it), so the key is what stops a device
//! elsewhere from naming this machine. The key file is written whole under a temporary name and
//! hard-linked into place, as the app does: two writers starting together both read the one that won.

use ring::hmac;
use std::path::{Path, PathBuf};

/// What the HMAC covers before the hardware id.
const DOMAIN: &str = "cmux.device-hub.machine\n";
/// The key's length; a file of any other length is not a key.
const SECRET_LEN: usize = 32;

/// What `machineKey`'s SHA-256 covers before the hardware id (PROTOCOL.md, One record per machine).
const KEY_DOMAIN: &str = "cmux-device-hub machine v1\n";

/// The `machineKey` for `hardware_id` (PROTOCOL.md, One record per machine): the lowercase hex
/// SHA-256 of `cmux-device-hub machine v1\n` and the uppercased id, the value the Mac app sends
/// (`CmuxNextDevices/DeviceIdentity+MachineKey.swift`), so the hub gives the daemon's device and the
/// app's one `machineId` and apps list them as one device. None without a hardware id.
pub fn machine_key(hardware_id: &str) -> Option<String> {
    let id = hardware_id.trim().to_uppercase();
    if id.is_empty() {
        return None;
    }
    Some(crate::hex(ring::digest::digest(&ring::digest::SHA256, format!("{KEY_DOMAIN}{id}").as_bytes()).as_ref()))
}

/// This machine's `machineKey`, read once per process; None where there is no hardware id.
pub fn current_key() -> Option<String> {
    static CURRENT: std::sync::OnceLock<Option<String>> = std::sync::OnceLock::new();
    CURRENT.get_or_init(|| machine_key(&hardware_id()?)).clone()
}

/// The `machine` for `hardware_id` under `secret`: None without a hardware id or a 32-byte key.
/// The id is trimmed and uppercased first, as the app does.
pub fn machine_id(hardware_id: &str, secret: &[u8]) -> Option<String> {
    let id = hardware_id.trim().to_uppercase();
    if id.is_empty() || secret.len() < SECRET_LEN {
        return None;
    }
    let key = hmac::Key::new(hmac::HMAC_SHA256, secret);
    Some(crate::hex(hmac::sign(&key, format!("{DOMAIN}{id}").as_bytes()).as_ref()))
}

/// This machine's `machine`, read once per process; None where there is no hardware id or no key.
pub fn current() -> Option<String> {
    static CURRENT: std::sync::OnceLock<Option<String>> = std::sync::OnceLock::new();
    CURRENT
        .get_or_init(|| {
            let id = hardware_id()?;
            let secret = load_secret(&secret_path()?)?;
            machine_id(&id, &secret)
        })
        .clone()
}

/// `IOPlatformUUID` from `ioreg -rd1 -c IOPlatformExpertDevice`'s text.
pub fn platform_uuid_in(ioreg: &str) -> Option<String> {
    ioreg.lines().find_map(|line| {
        let (key, value) = line.split_once('=')?;
        if key.trim() != "\"IOPlatformUUID\"" {
            return None;
        }
        let value = value.trim().trim_matches('"').trim();
        (!value.is_empty()).then(|| value.to_owned())
    })
}

#[cfg(target_os = "macos")]
fn hardware_id() -> Option<String> {
    let out = std::process::Command::new("/usr/sbin/ioreg")
        .args(["-rd1", "-c", "IOPlatformExpertDevice"])
        .stdin(std::process::Stdio::null())
        .stderr(std::process::Stdio::null())
        .output()
        .ok()?;
    platform_uuid_in(&String::from_utf8_lossy(&out.stdout))
}

#[cfg(all(unix, not(target_os = "macos")))]
fn hardware_id() -> Option<String> {
    ["/etc/machine-id", "/var/lib/dbus/machine-id"].iter().find_map(|path| {
        let text = std::fs::read_to_string(path).ok()?;
        let id = text.trim();
        (!id.is_empty()).then(|| id.to_owned())
    })
}

#[cfg(not(unix))]
fn hardware_id() -> Option<String> {
    None
}

/// This user's home: `HOME`, else the password entry's.
#[cfg(unix)]
fn home() -> Option<PathBuf> {
    if let Some(home) = std::env::var_os("HOME").filter(|v| !v.is_empty()) {
        return Some(PathBuf::from(home));
    }
    // SAFETY: getpwuid returns a pointer into static storage or null; it is read at once.
    unsafe {
        let entry = libc::getpwuid(libc::geteuid());
        if entry.is_null() || (*entry).pw_dir.is_null() {
            return None;
        }
        let dir = std::ffi::CStr::from_ptr((*entry).pw_dir);
        Some(PathBuf::from(<std::ffi::OsStr as std::os::unix::ffi::OsStrExt>::from_bytes(
            dir.to_bytes(),
        )))
    }
}

/// Where this machine's key lives (see the module doc).
#[cfg(target_os = "macos")]
pub fn secret_path() -> Option<PathBuf> {
    Some(home()?.join("Library/Application Support/cmux-device-hub/machine.key"))
}

/// Where this machine's key lives (see the module doc).
#[cfg(all(unix, not(target_os = "macos")))]
pub fn secret_path() -> Option<PathBuf> {
    let base = std::env::var_os("XDG_DATA_HOME")
        .filter(|v| !v.is_empty())
        .map(PathBuf::from)
        .or_else(|| home().map(|h| h.join(".local/share")))?;
    Some(base.join("cmux-device-hub/machine.key"))
}

/// Where this machine's key lives: nowhere off Unix.
#[cfg(not(unix))]
pub fn secret_path() -> Option<PathBuf> {
    None
}

/// The key at `path`, made first when there is none; None when it can be neither read nor made.
#[cfg(unix)]
pub fn load_secret(path: &Path) -> Option<Vec<u8>> {
    if let Some(existing) = read_secret(path) {
        return Some(existing);
    }
    use ring::rand::SecureRandom;
    use std::io::Write;
    use std::os::unix::fs::{DirBuilderExt, OpenOptionsExt};
    let dir = path.parent()?;
    let _ = std::fs::DirBuilder::new().recursive(true).mode(0o700).create(dir);
    let rng = ring::rand::SystemRandom::new();
    let mut bytes = [0u8; SECRET_LEN];
    rng.fill(&mut bytes).ok()?;
    let mut nonce = [0u8; 8];
    rng.fill(&mut nonce).ok()?;
    let name = path.file_name()?.to_string_lossy().into_owned();
    let temp = dir.join(format!(".{name}.{}", crate::hex(&nonce)));
    let written = std::fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o600)
        .custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC)
        .open(&temp)
        .and_then(|mut file| file.write_all(&bytes).and_then(|()| file.sync_all()));
    if written.is_ok() {
        // link(2) fails when the name exists: the first writer wins, the rest read its key.
        let _ = std::fs::hard_link(&temp, path);
    }
    let _ = std::fs::remove_file(&temp);
    read_secret(path)
}

/// The key at `path`: nothing off Unix.
#[cfg(not(unix))]
pub fn load_secret(_path: &Path) -> Option<Vec<u8>> {
    None
}

/// A key file: exactly 32 bytes, this user's, read without following a symlink.
#[cfg(unix)]
fn read_secret(path: &Path) -> Option<Vec<u8>> {
    use std::io::Read;
    use std::os::unix::fs::{MetadataExt, OpenOptionsExt};
    let mut file = std::fs::OpenOptions::new()
        .read(true)
        .custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC)
        .open(path)
        .ok()?;
    let meta = file.metadata().ok()?;
    // SAFETY: geteuid has no preconditions.
    if !meta.is_file() || meta.uid() != unsafe { libc::geteuid() } {
        return None;
    }
    let mut bytes = Vec::with_capacity(SECRET_LEN);
    file.by_ref().take(SECRET_LEN as u64 + 1).read_to_end(&mut bytes).ok()?;
    (bytes.len() == SECRET_LEN).then_some(bytes)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn the_value_is_the_apps_for_the_same_key_and_hardware_uuid() {
        // The same vector as CmuxNextDevicesTests/DeviceHubClientTests (DeviceMachine): HMAC-SHA256
        // keyed by 32 bytes 0x01..0x20 of "cmux.device-hub.machine\n" and the uppercased UUID.
        let secret: Vec<u8> = (1..=32).collect();
        let expected = "fbc56a076aca949302e3be7b9de232591fd3db3894b26781fd7aca57f672e6c6";
        assert_eq!(
            machine_id(" 12345678-abcd-ef01-2345-6789abcdef01\n", &secret).as_deref(),
            Some(expected)
        );
        assert_eq!(
            machine_id("12345678-ABCD-EF01-2345-6789ABCDEF01", &secret).as_deref(),
            Some(expected)
        );
    }

    #[test]
    fn the_machine_key_is_the_apps_for_the_same_hardware_uuid() {
        // DeviceIdentity.machineKey(platformUUID:): SHA-256 of "cmux-device-hub machine v1\n" and
        // the uppercased UUID, never keyed, so every build and the daemon send the same value.
        let expected = "61fd245706a49b5848b55b38c1f994413e198fbb51cc075cebd38436572b652f";
        assert_eq!(machine_key(" 12345678-abcd-ef01-2345-6789abcdef01\n").as_deref(), Some(expected));
        assert_eq!(machine_key("  "), None);
        assert_eq!(machine_key("A").map(|k| k.len()), Some(64));
    }

    #[test]
    fn no_value_without_a_hardware_id_or_a_whole_key() {
        assert_eq!(machine_id("  ", &[7; 32]), None);
        assert_eq!(machine_id("UUID", &[7; 31]), None);
        assert_ne!(machine_id("A", &[7; 32]), machine_id("B", &[7; 32]));
        assert_ne!(machine_id("A", &[7; 32]), machine_id("A", &[8; 32]));
    }

    #[test]
    fn reads_the_platform_uuid_from_ioreg() {
        let text = "+-o J314sAP  <class IOPlatformExpertDevice, id 0x100000215>\n    {\n      \"IOPlatformSerialNumber\" = \"X\"\n      \"IOPlatformUUID\" = \"0A1B2C3D-0000-1111-2222-333344445555\"\n    }\n";
        assert_eq!(platform_uuid_in(text).as_deref(), Some("0A1B2C3D-0000-1111-2222-333344445555"));
        assert_eq!(platform_uuid_in("\"IOPlatformSerialNumber\" = \"X\""), None);
    }

    #[cfg(unix)]
    #[test]
    fn the_key_is_made_once_and_read_back_by_every_writer() {
        use std::os::unix::fs::PermissionsExt;
        let dir = std::env::temp_dir().join(format!("cmux-machine-key-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        let path = dir.join("cmux-device-hub/machine.key");
        let first = load_secret(&path).expect("made");
        assert_eq!(first.len(), SECRET_LEN);
        assert_eq!(load_secret(&path), Some(first));
        let mode = std::fs::metadata(&path).unwrap().permissions().mode() & 0o777;
        assert_eq!(mode, 0o600);
        // No temporary file is left beside it.
        let names: Vec<_> = std::fs::read_dir(path.parent().unwrap())
            .unwrap()
            .flatten()
            .map(|e| e.file_name())
            .collect();
        assert_eq!(names, vec![std::ffi::OsString::from("machine.key")]);
        // A file that is not a whole key is never used as one, nor replaced.
        std::fs::write(&path, b"short").unwrap();
        assert_eq!(load_secret(&path), None);
        let _ = std::fs::remove_dir_all(&dir);
    }
}
