//! SSH host keys: fingerprints, the link-owned known-hosts file and the
//! offered-key observer (transport.md 12c item 1, finder.md 3.4).
//!
//! The link runs OpenSSH with `StrictHostKeyChecking yes` and its own
//! known-hosts file, so OpenSSH never prompts and never writes a key. To
//! learn which key a host offered, the link passes a `KnownHostsCommand`
//! that appends `%H %t %K` (lookup name, key type, key) to a private file
//! and prints nothing, so the decision stays with the known-hosts files.

use std::io::Write as _;
use std::path::{Path, PathBuf};

use base64::Engine as _;
use base64::engine::general_purpose::{STANDARD, STANDARD_NO_PAD};
use serde::{Deserialize, Serialize};
use sha2::{Digest as _, Sha256};

/// A host key as OpenSSH saw it.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct HostKey {
    /// The name OpenSSH looks the key up under (`host` or `[host]:port`).
    pub lookup_host: String,
    pub key_type: String,
    /// The public key blob, base64, as in a known-hosts line.
    pub key_base64: String,
    /// `SHA256:` and the unpadded base64 SHA-256 of the blob, as
    /// `ssh-keygen -l` prints it.
    pub fingerprint: String,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum HostKeyError {
    LookupHostInvalid,
    KeyTypeInvalid,
    KeyInvalid,
    PathInvalid(PathBuf),
}

impl std::fmt::Display for HostKeyError {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::LookupHostInvalid => formatter.write_str("host key lookup name is invalid"),
            Self::KeyTypeInvalid => formatter.write_str("host key type is invalid"),
            Self::KeyInvalid => formatter.write_str("host key blob is invalid"),
            Self::PathInvalid(path) => {
                write!(formatter, "path cannot be passed to ssh: {}", path.display())
            }
        }
    }
}

impl std::error::Error for HostKeyError {}

impl HostKey {
    /// Builds a key from the three known-hosts fields and checks that the
    /// blob decodes and names the same key type.
    pub fn new(lookup_host: &str, key_type: &str, key_base64: &str) -> Result<Self, HostKeyError> {
        if lookup_host.is_empty()
            || lookup_host.len() > 512
            || lookup_host.starts_with(['#', '@', '|'])
            || lookup_host.chars().any(|character| {
                character.is_whitespace() || character.is_control() || character == ','
            })
        {
            return Err(HostKeyError::LookupHostInvalid);
        }
        if key_type.is_empty()
            || key_type.len() > 128
            || !key_type.bytes().all(|byte| byte.is_ascii_alphanumeric() || b"@.-_".contains(&byte))
        {
            return Err(HostKeyError::KeyTypeInvalid);
        }
        let blob = STANDARD.decode(key_base64).map_err(|_| HostKeyError::KeyInvalid)?;
        if blob_key_type(&blob) != Some(key_type.as_bytes()) {
            return Err(HostKeyError::KeyInvalid);
        }
        Ok(Self {
            lookup_host: lookup_host.to_owned(),
            key_type: key_type.to_owned(),
            key_base64: key_base64.to_owned(),
            fingerprint: fingerprint(&blob),
        })
    }

    /// The known-hosts line for this key.
    #[must_use]
    pub fn known_hosts_line(&self) -> String {
        format!("{} {} {}", self.lookup_host, self.key_type, self.key_base64)
    }
}

/// `SHA256:<unpadded base64>` of a key blob.
#[must_use]
pub fn fingerprint(blob: &[u8]) -> String {
    format!("SHA256:{}", STANDARD_NO_PAD.encode(Sha256::digest(blob)))
}

/// The first SSH string of a key blob, which names its type.
fn blob_key_type(blob: &[u8]) -> Option<&[u8]> {
    let length = u32::from_be_bytes(blob.get(..4)?.try_into().ok()?);
    blob.get(4..4 + usize::try_from(length).ok()?)
}

/// Writes the link's known-hosts file: one line per key, 0600, replaced
/// atomically.
pub fn write_known_hosts<'a>(
    path: &Path,
    keys: impl IntoIterator<Item = &'a HostKey>,
) -> std::io::Result<()> {
    let mut contents = String::from("# Written by cmux link. Edits are overwritten.\n");
    for key in keys {
        contents.push_str(&key.known_hosts_line());
        contents.push('\n');
    }
    crate::conn::store::write_private_file(path, contents.as_bytes())
}

/// Reads observer output: the last complete `%H %t %K` line, if any.
/// Lines with an empty type or key come from OpenSSH's key-order lookup,
/// which runs before a key is offered.
#[must_use]
pub fn parse_observation(contents: &str) -> Option<HostKey> {
    contents.lines().rev().find_map(|line| {
        let mut fields = line.split(' ');
        let (host, key_type, key) = (fields.next()?, fields.next()?, fields.next()?);
        if fields.next().is_some() {
            return None;
        }
        HostKey::new(host, key_type, key).ok()
    })
}

/// Escapes a path for an ssh `-o` value: wrapped in double quotes, with
/// `%` doubled for OpenSSH's token expansion. Paths with quotes,
/// backslashes, `$` or line breaks are refused.
pub fn ssh_config_path(path: &Path) -> Result<String, HostKeyError> {
    let text = path.to_str().ok_or_else(|| HostKeyError::PathInvalid(path.to_owned()))?;
    if !path.is_absolute()
        || text
            .chars()
            .any(|character| matches!(character, '"' | '\'' | '\\' | '$') || character.is_control())
    {
        return Err(HostKeyError::PathInvalid(path.to_owned()));
    }
    Ok(format!("\"{}\"", text.replace('%', "%%")))
}

/// The `KnownHostsCommand` value that appends the offered key to
/// `observation_file` and prints nothing.
pub fn observer_command(observation_file: &Path) -> Result<String, HostKeyError> {
    let file = ssh_config_path(observation_file)?;
    // OpenSSH splits this into words (honoring quotes), then expands `%`
    // tokens in every word after the first; `%%` is a literal `%`.
    Ok(format!(
        "/bin/sh -c 'printf \"%%s %%s %%s\\n\" \"$1\" \"$2\" \"$3\" >> \"$0\"' {file} %H %t %K"
    ))
}

/// Finds a key of `key_type` for `lookup_host` in the user's own
/// known-hosts files, which the link reads but never writes. Uses
/// `ssh-keygen -F` so hashed entries match too.
pub async fn find_known_elsewhere(
    ssh_keygen: &Path,
    files: &[PathBuf],
    lookup_host: &str,
    key_type: &str,
) -> Option<HostKey> {
    for file in files {
        if !file.is_file() {
            continue;
        }
        let output = tokio::process::Command::new(ssh_keygen)
            .arg("-F")
            .arg(lookup_host)
            .arg("-f")
            .arg(file)
            .stdin(std::process::Stdio::null())
            .stderr(std::process::Stdio::null())
            .kill_on_drop(true)
            .output()
            .await
            .ok()?;
        let text = String::from_utf8_lossy(&output.stdout);
        for line in text.lines() {
            if line.starts_with(['#', '@']) {
                continue;
            }
            let mut fields = line.split_whitespace();
            let (Some(_), Some(found_type), Some(key)) =
                (fields.next(), fields.next(), fields.next())
            else {
                continue;
            };
            if found_type == key_type
                && let Ok(found) = HostKey::new(lookup_host, found_type, key)
            {
                return Some(found);
            }
        }
    }
    None
}

/// Creates an empty observation file, 0600, and returns its path.
pub fn new_observation_file(directory: &Path) -> std::io::Result<PathBuf> {
    let path = directory.join(format!("{}.keys", crate::ids::random_id("obs_")));
    let mut options = std::fs::OpenOptions::new();
    options.write(true).create_new(true);
    #[cfg(unix)]
    std::os::unix::fs::OpenOptionsExt::mode(&mut options, 0o600);
    options.open(&path)?.flush()?;
    Ok(path)
}

#[cfg(test)]
mod tests {
    use super::*;

    /// An Ed25519 public key blob with the given 32 key bytes.
    pub(crate) fn ed25519_blob(fill: u8) -> String {
        let mut blob = Vec::new();
        blob.extend_from_slice(&11_u32.to_be_bytes());
        blob.extend_from_slice(b"ssh-ed25519");
        blob.extend_from_slice(&32_u32.to_be_bytes());
        blob.extend_from_slice(&[fill; 32]);
        STANDARD.encode(blob)
    }

    #[test]
    fn host_keys_check_type_and_fingerprint() {
        let key = HostKey::new("[127.0.0.1]:2222", "ssh-ed25519", &ed25519_blob(7)).unwrap();
        assert!(key.fingerprint.starts_with("SHA256:"));
        assert_eq!(key.fingerprint.len(), "SHA256:".len() + 43);
        assert_eq!(
            key.known_hosts_line(),
            format!("[127.0.0.1]:2222 ssh-ed25519 {}", ed25519_blob(7))
        );
        assert_ne!(
            key.fingerprint,
            HostKey::new("h", "ssh-ed25519", &ed25519_blob(8)).unwrap().fingerprint
        );
        assert_eq!(
            HostKey::new("h", "ssh-rsa", &ed25519_blob(7)),
            Err(HostKeyError::KeyInvalid),
            "a blob of another type is refused"
        );
        assert_eq!(HostKey::new("h", "ssh-ed25519", "!!"), Err(HostKeyError::KeyInvalid));
        for host in ["", "a b", "#x", "|1|hash", "a,b"] {
            assert_eq!(
                HostKey::new(host, "ssh-ed25519", &ed25519_blob(1)),
                Err(HostKeyError::LookupHostInvalid),
                "{host:?}"
            );
        }
    }

    #[test]
    fn observation_takes_the_last_complete_line() {
        let key = ed25519_blob(3);
        let contents = format!("host  \nhost ssh-ed25519 {key}\n[h]:2 ssh-ed25519 {key}\n  \n");
        let observed = parse_observation(&contents).unwrap();
        assert_eq!(observed.lookup_host, "[h]:2");
        assert_eq!(parse_observation("h  \n"), None);
        assert_eq!(parse_observation(""), None);
    }

    #[test]
    fn config_paths_are_quoted_and_escaped() {
        assert_eq!(ssh_config_path(Path::new("/a b/100%/known")).unwrap(), "\"/a b/100%%/known\"");
        for bad in ["relative", "/a\"b", "/a$b", "/a\nb", "/a\\b"] {
            assert!(ssh_config_path(Path::new(bad)).is_err(), "{bad:?}");
        }
        let command = observer_command(Path::new("/tmp/link dir/o.keys")).unwrap();
        assert!(command.starts_with("/bin/sh -c '"));
        assert!(command.ends_with("\"/tmp/link dir/o.keys\" %H %t %K"));
    }
}
