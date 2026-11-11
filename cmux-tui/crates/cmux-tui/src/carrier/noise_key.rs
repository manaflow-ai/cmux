//! The device's Noise static key for carrier sessions.
//!
//! On a Mac the key lasts, so the device id a grant admits (`carrier:<user>:
//! <key fingerprint>`) stays the same across dials. Where it lasts depends on
//! this binary's code signature, never on the environment:
//!
//! - A Team-signed build (release, NIGHTLY, RC), or one whose signature could
//!   not be read (fail closed): the login Keychain, the way the other device
//!   keys are kept (a generic password, not synchronized, accessible after
//!   first unlock on this device only). Keychain calls run with user
//!   interaction off, so an item that needs the person's approval fails at
//!   once with a reason instead of waiting on a prompt nobody can answer.
//! - A build with no Team ID (an ad-hoc signed DEV build): a 0600 file in
//!   that build's own 0700 folder,
//!   `~/Library/Application Support/cmux-next/builds/<build key>/carrier/noise-key`.
//!   A login-Keychain item trusts the code that made it, and an ad-hoc
//!   binary's identity is its code hash: every rebuild is another app to the
//!   Keychain, so each read raised an access prompt the headless helper could
//!   not answer (the read blocked, or failed with -128), and the one shared
//!   service name made one tag's item block every other tag. Such a build
//!   never touches the Keychain item, not even to read it, since the read is
//!   what raises the prompt. The build key comes from the app bundle around
//!   this executable (bundle id and shipped tag, `BuildIdentity`), so every
//!   rebuild of one tag finds the same file and two tags never share one.
//!   This is the same trust decision `MacInstallStore.files` makes for the
//!   install keys of a debug build without a Team ID: any process of this
//!   user can read the file, as it could ask an ad-hoc build for the key.
//!
//! Elsewhere (a Linux dial, tests) the key is made for this one dial and
//! never written down: each dial asks for a grant naming its own key.

#[cfg(unix)]
use std::path::{Path, PathBuf};

use cmux_remote::crypto::StaticIdentity;

/// The Keychain service and account of the carrier key.
#[cfg(target_os = "macos")]
const SERVICE: &str = "com.cmuxterm.app.next.carrier-noise-key";
#[cfg(target_os = "macos")]
const ACCOUNT: &str = "device";

/// The device's lasting carrier identity, for `cmux carrier key --public`:
/// on a Mac the key dial and serve use, made the same way when it does not
/// exist yet. Elsewhere there is none (each dial makes its own), so no key
/// printed there could match a later dial's.
pub(super) fn lasting_identity() -> Result<StaticIdentity, String> {
    #[cfg(target_os = "macos")]
    {
        device_identity()
    }
    #[cfg(not(target_os = "macos"))]
    {
        Err("this platform keeps no device key: each dial makes its own".into())
    }
}

/// The device's carrier identity.
pub(super) fn device_identity() -> Result<StaticIdentity, String> {
    #[cfg(target_os = "macos")]
    {
        let exe = std::env::current_exe().ok();
        let home = cmux_tui_core::platform::home_dir();
        let store =
            store_for(cmux_link::app_caller::signed_app_build(), exe.as_deref(), home.as_deref())?;
        match store {
            Store::Keychain => keychain::load_or_create(SERVICE, ACCOUNT),
            Store::File(path) => file_key::load_or_create(&path),
        }
        .map(StaticIdentity::from_private)
    }
    #[cfg(not(target_os = "macos"))]
    {
        StaticIdentity::generate().map_err(|e| format!("no Noise key: {e}"))
    }
}

/// Where a build keeps its carrier key.
#[cfg(unix)]
#[derive(Debug, PartialEq, Eq)]
#[cfg_attr(not(target_os = "macos"), allow(dead_code))]
enum Store {
    /// The login Keychain item (a Team-signed build).
    Keychain,
    /// The 0600 file of this build (a build with no Team ID).
    File(PathBuf),
}

/// The store of a build: the Keychain when `team_signed` (which is true when
/// the signature could not be read), else the file of the build whose app
/// bundle contains `exe` (`unbundled` outside any bundle) under `home`. A
/// build with no Team ID and no home has no store: it never falls back to
/// the Keychain, whose prompt is the failure this avoids.
#[cfg(unix)]
#[cfg_attr(not(target_os = "macos"), allow(dead_code))]
fn store_for(team_signed: bool, exe: Option<&Path>, home: Option<&Path>) -> Result<Store, String> {
    if team_signed {
        return Ok(Store::Keychain);
    }
    let home = home.ok_or("no home folder for this build's carrier key")?;
    // A link to the bundled `cmux` from outside the bundle (a PATH shim) is that bundle's build.
    let identity = crate::app_identity::AppIdentity::from_bundle(exe).or_else(|| {
        let real = std::fs::canonicalize(exe?).ok()?;
        crate::app_identity::AppIdentity::from_bundle(Some(&real))
    });
    let build = identity.map_or_else(
        || cmux_agent_pane_policy::build_identity::BuildIdentity::new(None, None),
        |identity| identity.build(),
    );
    Ok(Store::File(
        home.join("Library")
            .join("Application Support")
            .join("cmux-next")
            .join("builds")
            .join(build.key())
            .join("carrier")
            .join(file_key::FILE),
    ))
}

/// The key file of a build with no Team ID (module docs): 32 raw bytes, mode
/// 0600, owned by this user, in a 0700 folder; never read or written through
/// a symbolic link; made atomically (an exclusive temporary file, then a
/// hard link that never replaces an existing key).
#[cfg(unix)]
#[cfg_attr(not(target_os = "macos"), allow(dead_code))]
mod file_key {
    use std::fs::{DirBuilder, File, OpenOptions, Permissions};
    use std::io::{ErrorKind, Read as _, Write as _};
    use std::os::unix::fs::{
        DirBuilderExt as _, MetadataExt as _, OpenOptionsExt as _, PermissionsExt as _,
    };
    use std::path::Path;

    use zeroize::Zeroizing;

    /// The key file's name in the build's `carrier` folder.
    pub(crate) const FILE: &str = "noise-key";

    fn own_uid() -> u32 {
        // SAFETY: geteuid has no preconditions.
        unsafe { libc::geteuid() }
    }

    /// The key at `path`, made there when there is none.
    pub(crate) fn load_or_create(path: &Path) -> Result<[u8; 32], String> {
        let folder = path.parent().ok_or("the carrier key path has no folder")?;
        private_folder(folder)?;
        if let Some(key) = read(path)? {
            return Ok(*key);
        }
        let identity = cmux_remote::crypto::StaticIdentity::generate()
            .map_err(|e| format!("no Noise key: {e}"))?;
        let key = Zeroizing::new(*identity.private_key());
        let mut nonce = [0_u8; 8];
        getrandom::fill(&mut nonce).map_err(|e| format!("no Noise key: {e}"))?;
        let nonce: String = nonce.iter().map(|b| format!("{b:02x}")).collect();
        let temporary = folder.join(format!(".{FILE}.{}.{nonce}.tmp", std::process::id()));
        let written = write_new(&temporary, &key);
        let linked = written.and_then(|()| {
            // A hard link never replaces what is at `path`: when two first
            // dials race, the one whose link loses reads the key the other
            // stored, so the build keeps one key.
            match std::fs::hard_link(&temporary, path) {
                Ok(()) => Ok(true),
                Err(e) if e.kind() == ErrorKind::AlreadyExists => Ok(false),
                Err(e) => Err(format!("the carrier key file could not be stored: {e}")),
            }
        });
        let _ = std::fs::remove_file(&temporary);
        if linked? {
            if let Ok(folder) = File::open(folder) {
                let _ = folder.sync_all();
            }
            return Ok(*key);
        }
        read(path)?
            .map(|key| *key)
            .ok_or_else(|| "the carrier key file vanished while it was stored".to_owned())
    }

    /// Makes `folder` (0700) when missing; refuses one that is a symbolic
    /// link, not a folder, or another user's, and narrows its mode to 0700.
    fn private_folder(folder: &Path) -> Result<(), String> {
        DirBuilder::new()
            .recursive(true)
            .mode(0o700)
            .create(folder)
            .map_err(|e| format!("the carrier key folder could not be made: {e}"))?;
        let meta = std::fs::symlink_metadata(folder)
            .map_err(|e| format!("the carrier key folder could not be read: {e}"))?;
        if meta.file_type().is_symlink() || !meta.is_dir() {
            return Err(format!("{} is not a folder; refused", folder.display()));
        }
        if meta.uid() != own_uid() {
            return Err(format!("{} belongs to another user; refused", folder.display()));
        }
        if meta.mode() & 0o777 != 0o700 {
            std::fs::set_permissions(folder, Permissions::from_mode(0o700))
                .map_err(|e| format!("the carrier key folder could not be made private: {e}"))?;
        }
        Ok(())
    }

    /// The key at `path`, `None` when there is no file. A symbolic link, a
    /// file that is not regular, another user's, one others may read or
    /// write, or one that is not 32 bytes is refused, never used.
    fn read(path: &Path) -> Result<Option<Zeroizing<[u8; 32]>>, String> {
        let mut file = match OpenOptions::new()
            .read(true)
            .custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC | libc::O_NONBLOCK)
            .open(path)
        {
            Ok(file) => file,
            Err(e) if e.kind() == ErrorKind::NotFound => return Ok(None),
            Err(e) if e.raw_os_error() == Some(libc::ELOOP) => {
                return Err(format!("{} is a symbolic link; refused", path.display()));
            }
            Err(e) => return Err(format!("{} could not be read: {e}", path.display())),
        };
        let shown = path.display();
        let meta = file.metadata().map_err(|e| format!("{shown} could not be read: {e}"))?;
        if !meta.is_file() {
            return Err(format!("{shown} is not a regular file; refused"));
        }
        if meta.uid() != own_uid() {
            return Err(format!("{shown} belongs to another user; refused"));
        }
        if meta.mode() & 0o077 != 0 {
            return Err(format!("{shown} is open to other users; refused"));
        }
        if meta.len() != 32 {
            return Err(format!("{shown} is not 32 bytes; remove it to make a new key"));
        }
        let mut key = Zeroizing::new([0_u8; 32]);
        file.read_exact(key.as_mut()).map_err(|e| format!("{shown} could not be read: {e}"))?;
        Ok(Some(key))
    }

    /// Writes `key` to a new 0600 file at `path` (created exclusively,
    /// never through a symbolic link) and syncs it.
    fn write_new(path: &Path, key: &[u8; 32]) -> Result<(), String> {
        let stored = |e: std::io::Error| format!("the carrier key file could not be stored: {e}");
        let mut file = OpenOptions::new()
            .write(true)
            .create_new(true)
            .mode(0o600)
            .custom_flags(libc::O_NOFOLLOW | libc::O_CLOEXEC)
            .open(path)
            .map_err(stored)?;
        file.set_permissions(Permissions::from_mode(0o600)).map_err(stored)?;
        file.write_all(key).map_err(stored)?;
        file.sync_all().map_err(stored)
    }
}

#[cfg(target_os = "macos")]
mod keychain {
    use core_foundation::base::TCFType;
    use core_foundation::data::CFData;
    use core_foundation::dictionary::CFDictionary;
    use core_foundation::string::{CFString, CFStringRef};
    use security_framework::os::macos::keychain::SecKeychain;
    use security_framework::passwords::generic_password;
    use security_framework::passwords_options::PasswordOptions;
    use security_framework_sys::access_control::kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly;
    use security_framework_sys::base::{errSecDuplicateItem, errSecItemNotFound, errSecSuccess};
    use security_framework_sys::item::kSecValueData;
    use security_framework_sys::keychain_item::SecItemAdd;

    #[link(name = "Security", kind = "framework")]
    unsafe extern "C" {
        static kSecAttrAccessible: CFStringRef;
    }

    /// The item's service, for the refusal's recovery step.
    const SERVICE_NAME: &str = super::SERVICE;
    /// `errSecUserCanceled`: a prompt for the item was dismissed or denied.
    const USER_CANCELED: i32 = -128;
    /// `errSecInteractionNotAllowed`: the item needs a prompt, and prompts are off.
    const INTERACTION_NOT_ALLOWED: i32 = -25308;
    /// `errSecAuthFailed`: the Keychain refused the access.
    const AUTH_FAILED: i32 = -25293;

    fn options(service: &str, account: &str) -> PasswordOptions {
        let mut options = PasswordOptions::new_generic_password(service, account);
        options.set_access_synchronized(Some(false));
        options
    }

    /// The error for a Keychain status, in words the connect line can show.
    fn refused(code: i32) -> String {
        match code {
            INTERACTION_NOT_ALLOWED | USER_CANCELED | AUTH_FAILED => format!(
                "the login Keychain is locked or asks to approve the carrier key, which the Cloud \
                 connection helper cannot do; unlock it, or remove the Keychain item \
                 {SERVICE_NAME} (another cmux build made it) so a new key is made ({code})"
            ),
            _ => format!("the Keychain refused the carrier key ({code})"),
        }
    }

    fn read(service: &str, account: &str) -> Result<Option<[u8; 32]>, String> {
        match generic_password(options(service, account)) {
            Ok(bytes) => bytes
                .try_into()
                .map(Some)
                .map_err(|_| "the Keychain carrier key is not 32 bytes".to_owned()),
            Err(e) if e.code() == errSecItemNotFound => Ok(None),
            Err(e) => Err(refused(e.code())),
        }
    }

    /// The key in the Keychain item, made when there is none. Keychain user
    /// interaction is off for the whole call (`SecKeychainSetUserInteractionAllowed`,
    /// as CmuxNext `LoginKeychain.withoutUI` does): only that stops the login
    /// Keychain's access prompt, and then a read that needs the person's
    /// approval answers `errSecInteractionNotAllowed` at once instead of
    /// blocking the connect path on a prompt nobody can answer. The switch is
    /// the process's and its guard turns prompts back on (not to what they
    /// were): every caller (`prepare` of dial and serve, `secrets`, `key`)
    /// runs once, before its async runtime starts, in a one-shot process.
    pub(super) fn load_or_create(service: &str, account: &str) -> Result<[u8; 32], String> {
        let _no_prompt = SecKeychain::disable_user_interaction()
            .map_err(|e| format!("the Keychain could not turn its prompts off ({})", e.code()))?;
        if let Some(key) = read(service, account)? {
            return Ok(key);
        }
        let identity = cmux_remote::crypto::StaticIdentity::generate()
            .map_err(|e| format!("no Noise key: {e}"))?;
        let key = *identity.private_key();
        let mut add = options(service, account);
        // SAFETY: all three are static CFStrings the Security framework exports.
        let (accessible, after_first_unlock, value_data) = unsafe {
            (
                CFString::wrap_under_get_rule(kSecAttrAccessible),
                CFString::wrap_under_get_rule(kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly),
                CFString::wrap_under_get_rule(kSecValueData),
            )
        };
        #[allow(deprecated)] // `query` is the only way to set kSecAttrAccessible.
        let query = &mut add.query;
        query.push((accessible, after_first_unlock.into_CFType()));
        query.push((value_data, CFData::from_buffer(&key).into_CFType()));
        let attributes = CFDictionary::from_CFType_pairs(query);
        // Add only, never update: when two first dials race, the one whose
        // add loses reads the key the other stored, so the device keeps one key.
        // SAFETY: `attributes` is a live dictionary; no result is asked for.
        let status = unsafe { SecItemAdd(attributes.as_concrete_TypeRef(), std::ptr::null_mut()) };
        if status == errSecDuplicateItem {
            return read(service, account)?
                .ok_or_else(|| "the Keychain carrier key vanished while it was stored".to_owned());
        }
        if status != errSecSuccess {
            return Err(refused(status));
        }
        Ok(key)
    }
}

#[cfg(all(test, unix))]
#[path = "noise_key_tests.rs"]
mod tests;
