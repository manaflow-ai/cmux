//! The pure trust rules: snapshot validation, the monotonic apply decision
//! and the fail-closed freshness check.

use serde::{Deserialize, Serialize};

use super::b64;

/// A sync older than this refuses new logins (seconds).
pub const STALE_AFTER_SECS: u64 = 120;
/// A sync time this far in the future is treated as stale (clock jump).
pub const FUTURE_SKEW_SECS: u64 = 60;
/// Upper bound on a KRL we accept (the backend caps live revocations at
/// 20,000 serials, a few hundred KiB).
pub const MAX_KRL_BYTES: usize = 4 * 1024 * 1024;
const KRL_MAGIC: &[u8; 8] = b"SSHKRL\n\0";
const KRL_FORMAT_VERSION: u32 = 1;

/// The `team_vm.ssh_ca` read value (also what bind writes for a personal
/// machine's CA). Unknown fields such as `team` are ignored.
#[derive(Clone, Debug, Deserialize)]
pub struct Snapshot {
    pub generation: u64,
    pub trusted_ca_keys: Vec<String>,
    /// The KRL, standard base64.
    pub krl: String,
    pub krl_version: u64,
}

/// A validated snapshot.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Verified {
    pub generation: u64,
    pub ca_keys: Vec<String>,
    pub krl: Vec<u8>,
    pub krl_version: u64,
}

/// What `trust.json` holds after an apply.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct TrustState {
    pub krl_version: u64,
    pub generation: u64,
    /// Unix seconds of the last accepted snapshot.
    pub synced_at: u64,
}

fn valid_ca_line(line: &str) -> bool {
    let mut parts = line.split(' ');
    let (Some(kind), Some(body)) = (parts.next(), parts.next()) else { return false };
    kind == "ssh-ed25519"
        && !line.contains(['\n', '\r', '\0'])
        && b64::decode(body).is_some_and(|blob| blob.len() == 51)
}

/// The version in an OpenSSH KRL header (format 1), `None` when `krl` is
/// not a KRL.
pub fn krl_header_version(krl: &[u8]) -> Option<u64> {
    if krl.len() < 20 || &krl[..8] != KRL_MAGIC {
        return None;
    }
    if u32::from_be_bytes([krl[8], krl[9], krl[10], krl[11]]) != KRL_FORMAT_VERSION {
        return None;
    }
    let mut version = [0u8; 8];
    version.copy_from_slice(&krl[12..20]);
    Some(u64::from_be_bytes(version))
}

/// Checks a snapshot: Ed25519 CA lines only, a decodable KRL whose header
/// carries the same `krl_version`.
pub fn verify(snapshot: &Snapshot) -> Result<Verified, String> {
    for line in &snapshot.trusted_ca_keys {
        if !valid_ca_line(line) {
            return Err(
                "trusted_ca_keys: each entry must be one ssh-ed25519 public key line".into()
            );
        }
    }
    if snapshot.krl.len() > MAX_KRL_BYTES / 3 * 4 + 4 {
        return Err("krl: too large".into());
    }
    let krl = b64::decode(&snapshot.krl).ok_or("krl: not standard base64")?;
    let version = krl_header_version(&krl).ok_or("krl: not an OpenSSH KRL (format 1)")?;
    if version != snapshot.krl_version {
        return Err("krl: header version differs from krl_version".into());
    }
    Ok(Verified {
        generation: snapshot.generation,
        ca_keys: snapshot.trusted_ca_keys.clone(),
        krl,
        krl_version: snapshot.krl_version,
    })
}

/// Whether `next` may replace `current`: neither the KRL version nor the
/// CA generation may go backwards. Equal versions are a refresh (the
/// backend drops expired serials from the KRL without a new version).
pub fn decide(current: Option<&TrustState>, next: &Verified) -> Result<(), String> {
    let Some(current) = current else { return Ok(()) };
    if next.krl_version < current.krl_version {
        return Err(format!(
            "krl_version {} is older than the applied {}",
            next.krl_version, current.krl_version
        ));
    }
    if next.generation < current.generation {
        return Err(format!(
            "CA generation {} is older than the applied {}",
            next.generation, current.generation
        ));
    }
    Ok(())
}

/// Fail closed: trust is usable only after a sync within
/// [`STALE_AFTER_SECS`] (and not from the future).
pub fn fresh(state: Option<&TrustState>, now: u64) -> Result<(), &'static str> {
    let Some(state) = state else { return Err("no trust state: nothing was applied") };
    if state.synced_at > now.saturating_add(FUTURE_SKEW_SECS) {
        return Err("trust state is from the future");
    }
    if now.saturating_sub(state.synced_at) > STALE_AFTER_SECS {
        return Err("trust state is stale");
    }
    Ok(())
}

/// A Linux user name sshd may pass as `%u` (no path characters).
pub fn valid_user(user: &str) -> bool {
    let mut chars = user.chars();
    chars.next().is_some_and(|c| c.is_ascii_lowercase() || c == '_')
        && user.len() <= 32
        && chars.all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == '_' || c == '-')
}

/// The `AuthorizedPrincipalsCommand` output: the principals file's lines
/// while trust is fresh, else nothing.
pub fn principals_output(state: Option<&TrustState>, now: u64, file: &str) -> String {
    if fresh(state, now).is_err() {
        return String::new();
    }
    file.lines().map(str::trim).filter(|line| !line.is_empty() && !line.starts_with('#')).fold(
        String::new(),
        |mut out, line| {
            out.push_str(line);
            out.push('\n');
            out
        },
    )
}
