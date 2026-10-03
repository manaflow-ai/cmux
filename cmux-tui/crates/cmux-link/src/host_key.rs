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
        if !crate::names::valid_lookup_host(lookup_host) {
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

/// What the user's own known-hosts files say about a host.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct KnownElsewhere {
    /// A key the user trusts for the host, of any type (the offered type
    /// first). Any known key that differs from the offer makes the offer a
    /// change, so a key-type downgrade is a hard stop too. When the host is
    /// trusted only through a `@cert-authority` line, this is the CA key: a
    /// plain key offered by such a host is a change, never an unknown the
    /// sheet could confirm.
    pub key: Option<HostKey>,
    /// The offered key is marked `@revoked`.
    pub revoked: bool,
}

/// Reads the user's own known-hosts files (never writes them) through
/// `ssh-keygen -F`, so hashed entries match too. A tool that cannot run, or
/// that fails other than "not found", is an error: the link never treats an
/// unreadable file as "nothing known".
pub async fn find_known_elsewhere(
    ssh_keygen: &Path,
    files: &[PathBuf],
    offered: &HostKey,
) -> std::io::Result<KnownElsewhere> {
    let mut found = KnownElsewhere::default();
    for file in files {
        if !file.is_file() {
            continue;
        }
        let output = tokio::process::Command::new(ssh_keygen)
            .arg("-F")
            .arg(&offered.lookup_host)
            .arg("-f")
            .arg(file)
            .stdin(std::process::Stdio::null())
            .stderr(std::process::Stdio::null())
            .kill_on_drop(true)
            .output()
            .await?;
        // ssh-keygen -F exits 1 when the host is not in the file.
        match output.status.code() {
            Some(0) => {}
            Some(1) if output.stdout.is_empty() => continue,
            _ => {
                return Err(std::io::Error::other(format!(
                    "ssh-keygen -F failed on {}",
                    file.display()
                )));
            }
        }
        let parsed = parse_keygen_lines(&String::from_utf8_lossy(&output.stdout), offered);
        found.revoked |= parsed.revoked;
        let better = |candidate: &HostKey| candidate.key_type == offered.key_type;
        match (&found.key, parsed.key) {
            (None, Some(key)) => found.key = Some(key),
            (Some(current), Some(key)) if !better(current) && better(&key) => found.key = Some(key),
            _ => {}
        }
    }
    Ok(found)
}

/// Reads `ssh-keygen -F` output for `offered`.
#[must_use]
pub fn parse_keygen_lines(text: &str, offered: &HostKey) -> KnownElsewhere {
    let mut found = KnownElsewhere::default();
    let mut authority = None;
    for line in text.lines() {
        if line.starts_with('#') {
            continue;
        }
        let mut fields = line.split_whitespace();
        let Some(first) = fields.next() else { continue };
        let marker = first.starts_with('@').then_some(first);
        if marker.is_some() {
            fields.next();
        }
        let (Some(found_type), Some(key)) = (fields.next(), fields.next()) else { continue };
        match marker {
            Some("@revoked") => found.revoked |= key == offered.key_base64,
            Some("@cert-authority") => {
                if authority.is_none() {
                    authority = HostKey::new(&offered.lookup_host, found_type, key).ok();
                }
            }
            Some(_) => {}
            None => {
                if let Ok(known) = HostKey::new(&offered.lookup_host, found_type, key) {
                    let replace = found.key.as_ref().is_none_or(|current| {
                        current.key_type != offered.key_type && known.key_type == offered.key_type
                    });
                    if replace {
                        found.key = Some(known);
                    }
                }
            }
        }
    }
    if found.key.is_none() {
        found.key = authority;
    }
    found
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
        for host in ["", "a b", "#x", "|1|hash", "a,b", "*", "h?", "!h", "h;id"] {
            assert_eq!(
                HostKey::new(host, "ssh-ed25519", &ed25519_blob(1)),
                Err(HostKeyError::LookupHostInvalid),
                "{host:?}"
            );
        }
    }

    fn blob_of(key_type: &str, fill: u8) -> String {
        let mut blob = Vec::new();
        blob.extend_from_slice(&u32::try_from(key_type.len()).unwrap().to_be_bytes());
        blob.extend_from_slice(key_type.as_bytes());
        blob.extend_from_slice(&[fill; 40]);
        STANDARD.encode(blob)
    }

    #[test]
    fn any_known_key_type_counts_and_revoked_keys_are_seen() {
        let offered = HostKey::new("[h]:22", "ssh-rsa", &blob_of("ssh-rsa", 1)).unwrap();
        // A downgrade: only an ed25519 key is known, the host offers RSA.
        let text =
            format!("# Host [h]:22 found: line 1\n|1|salt|hash ssh-ed25519 {}\n", ed25519_blob(5));
        let found = parse_keygen_lines(&text, &offered);
        assert_eq!(found.key.unwrap().key_type, "ssh-ed25519", "a key of another type is known");
        assert!(!found.revoked);
        // The offered type wins when both are known.
        let text = format!(
            "[h]:22 ssh-ed25519 {}\n[h]:22 ssh-rsa {}\n",
            ed25519_blob(5),
            blob_of("ssh-rsa", 2)
        );
        assert_eq!(parse_keygen_lines(&text, &offered).key.unwrap().key_type, "ssh-rsa");
        let text = format!(
            "@revoked * ssh-rsa {}\n@cert-authority * ssh-rsa {}\n",
            offered.key_base64,
            blob_of("ssh-rsa", 3)
        );
        let found = parse_keygen_lines(&text, &offered);
        assert!(found.revoked);
        // A host trusted only through a CA reports the CA key, so a plain
        // key it offers is a change, never an unknown.
        let authority = blob_of("ssh-rsa", 3);
        assert_eq!(found.key.as_ref().map(|key| key.key_base64.as_str()), Some(authority.as_str()));
        let text = format!(
            "@cert-authority * ssh-rsa {authority}\n[h]:22 ssh-rsa {}\n",
            blob_of("ssh-rsa", 4)
        );
        assert_eq!(
            parse_keygen_lines(&text, &offered).key.unwrap().key_base64,
            blob_of("ssh-rsa", 4),
            "a plain known key wins over the CA"
        );
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
