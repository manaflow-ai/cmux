//! The user certificate of an sshd session, from the `SSH_AUTH_INFO_0`
//! PAM variable sshd sets (one `<method> <details>` line per successful
//! authentication method; a public key line is `publickey <type> <base64>`).

use super::b64;

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
        let blob = b64::decode(body).ok_or("certificate is not base64")?;
        let (serial, key_id) =
            parse_blob(kind, &blob).ok_or_else(|| format!("unsupported certificate {kind}"))?;
        certs.push(SessionCert { line: format!("{kind} {body}"), serial, key_id });
    }
    Ok(certs)
}

/// `session_certs` for session open: a session with no certificate is an
/// error, because sshd allows only certificate logins (`AuthorizedKeysFile
/// none`), so an empty list means the PAM environment was altered.
pub fn required_session_certs(auth_info: &str) -> Result<Vec<SessionCert>, String> {
    let certs = session_certs(auth_info)?;
    if certs.is_empty() {
        return Err("no certificate in SSH_AUTH_INFO_0".into());
    }
    Ok(certs)
}
