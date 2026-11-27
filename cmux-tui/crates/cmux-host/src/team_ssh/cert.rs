//! The user certificate of an sshd session, from the `SSH_AUTH_INFO_0`
//! PAM variable sshd sets (one `<method> <details>` line per successful
//! authentication method; a public key line is `publickey <type> <base64>`).

use base64::Engine;
use base64::engine::general_purpose::STANDARD;

/// One certificate a session authenticated with.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct SessionCert {
    /// `<type> <base64>`: a valid OpenSSH public key line for `ssh-keygen -Q`.
    pub line: String,
    pub serial: u64,
    pub key_id: String,
}

struct Reader<'a>(&'a [u8]);

impl<'a> Reader<'a> {
    fn take(&mut self, n: usize) -> Option<&'a [u8]> {
        let (head, rest) = self.0.split_at_checked(n)?;
        self.0 = rest;
        Some(head)
    }
    fn u32(&mut self) -> Option<u32> {
        Some(u32::from_be_bytes(self.take(4)?.try_into().ok()?))
    }
    fn u64(&mut self) -> Option<u64> {
        Some(u64::from_be_bytes(self.take(8)?.try_into().ok()?))
    }
    fn string(&mut self) -> Option<&'a [u8]> {
        let n = usize::try_from(self.u32()?).ok()?;
        self.take(n)
    }
}

/// Serial and key id of an OpenSSH user certificate blob (PROTOCOL.certkeys).
fn parse_blob(kind: &str, blob: &[u8]) -> Option<(u64, String)> {
    let mut r = Reader(blob);
    if r.string()? != kind.as_bytes() {
        return None;
    }
    r.string()?; // nonce
    match kind {
        "ssh-ed25519-cert-v01@openssh.com" => {
            r.string()?;
        }
        "ecdsa-sha2-nistp256-cert-v01@openssh.com"
        | "ecdsa-sha2-nistp384-cert-v01@openssh.com"
        | "ecdsa-sha2-nistp521-cert-v01@openssh.com" => {
            r.string()?; // curve
            r.string()?; // point
        }
        _ => return None,
    }
    let serial = r.u64()?;
    let cert_type = r.u32()?;
    if cert_type != 1 {
        return None; // host certificate
    }
    let key_id = String::from_utf8(r.string()?.to_vec()).ok()?;
    Some((serial, key_id))
}

/// The certificates in `SSH_AUTH_INFO_0`. Plain keys and other methods are
/// skipped; a certificate line that does not parse is an error, so a
/// session is never left unrecorded by accident.
pub fn session_certs(auth_info: &str) -> Result<Vec<SessionCert>, String> {
    let mut certs = Vec::new();
    for line in auth_info.lines() {
        let mut parts = line.split(' ');
        let (Some("publickey"), Some(kind), Some(body)) =
            (parts.next(), parts.next(), parts.next())
        else {
            continue;
        };
        if !kind.ends_with("-cert-v01@openssh.com") {
            continue;
        }
        let blob = STANDARD.decode(body).ok().ok_or("certificate is not base64")?;
        let (serial, key_id) =
            parse_blob(kind, &blob).ok_or_else(|| format!("unsupported certificate {kind}"))?;
        certs.push(SessionCert { line: format!("{kind} {body}"), serial, key_id });
    }
    Ok(certs)
}

/// `session_certs` for session open: a session with no certificate is an
/// error, because the image's sshd allows only certificate logins
/// (`AuthorizedKeysFile none`), so an empty list means the PAM environment
/// was altered. The one other login is the platform's own short-lived key
/// ([`platform_key_session`]), which session open checks first.
pub fn required_session_certs(auth_info: &str) -> Result<Vec<SessionCert>, String> {
    let certs = session_certs(auth_info)?;
    if certs.is_empty() {
        return Err("no certificate in SSH_AUTH_INFO_0".into());
    }
    Ok(certs)
}

/// The platform's ssh endpoint (cmux-platform `SshEndpoint.ts`, `SSH_PATHS.keysDir`)
/// adds its root-owned key file per user to sshd's `AuthorizedKeysFile` list and
/// writes `restrict,expiry-time=…[,command=…] ssh-ed25519 <blob> cmux-ssh:…` lines
/// to it: the ssh backup carrier and `cmux ssh` to a Cloud machine log in with them.
pub const PLATFORM_KEYS_DIR: &str = "/etc/ssh/cmux-authorized-keys";

/// A session that authenticated only with plain public keys, each one a key
/// in the platform's key file for the user (`keys`, that file's text). Such a
/// session has no certificate to record or revoke: the key expires on its own
/// (`expiry-time`, enforced by sshd) and the platform revokes it by removing
/// its line. Any certificate, other method, or key the file does not list
/// answers false, so session open still refuses it.
pub fn platform_key_session(auth_info: &str, keys: &str) -> bool {
    let listed: Vec<(&str, &str)> = keys
        .lines()
        .filter(|line| !line.trim_start().starts_with('#'))
        .flat_map(|line| {
            let words: Vec<&str> = line.split_whitespace().collect();
            (1..words.len()).map(move |i| (words[i - 1], words[i])).collect::<Vec<_>>()
        })
        .filter(|(kind, _)| kind.starts_with("ssh-") || kind.starts_with("ecdsa-"))
        .collect();
    let mut any = false;
    for line in auth_info.lines().filter(|line| !line.is_empty()) {
        let mut parts = line.split(' ');
        let (Some("publickey"), Some(kind), Some(blob), None) =
            (parts.next(), parts.next(), parts.next(), parts.next())
        else {
            return false;
        };
        if kind.ends_with("-cert-v01@openssh.com") || !listed.contains(&(kind, blob)) {
            return false;
        }
        any = true;
    }
    any
}

#[cfg(test)]
#[path = "cert_tests.rs"]
mod tests;
