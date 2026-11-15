//! Security types and the credentials they need.

pub mod ard;
pub mod des;
pub mod md5;

/// Security types (RFC 6143 7.2 and the IANA registry).
pub mod security {
    pub const INVALID: u8 = 0;
    pub const NONE: u8 = 1;
    pub const VNC: u8 = 2;
    pub const VENCRYPT: u8 = 19;
    pub const APPLE_DH: u8 = 30;
}

/// VeNCrypt subtypes: None and VNC can be used over RFB. Plain is recognized
/// only to report an explicit refusal: its account password requires TLS.
pub mod vencrypt {
    pub const NONE: u32 = 1;
    pub const VNC: u32 = 2;
    pub const PLAIN: u32 = 256;
}

/// What the person typed. A Windows or Linux server usually needs only a
/// password; macOS Screen Sharing needs the Mac's user name too.
#[derive(Clone, Default, PartialEq, Eq)]
pub struct Credentials {
    pub username: Option<String>,
    pub password: Option<String>,
}

impl std::fmt::Debug for Credentials {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("Credentials")
            .field("username", &self.username)
            .field("password", &self.password.as_ref().map(|_| "<redacted>"))
            .finish()
    }
}

/// The security type to use from what the server offers, most capable
/// first: no authentication when the server allows it, then Apple DH when a
/// user name is known (macOS), then the VNC password, then VeNCrypt.
/// `Err` says what is missing: credentials (with whether a user name is
/// needed) or any supported type at all.
pub fn choose(offered: &[u8], credentials: &Credentials) -> Result<u8, crate::VncError> {
    use security::*;
    let has_password = credentials.password.is_some();
    let has_user = credentials.username.is_some();
    if offered.contains(&NONE) {
        return Ok(NONE);
    }
    if offered.contains(&APPLE_DH) && has_password && has_user {
        return Ok(APPLE_DH);
    }
    if offered.contains(&VNC) && has_password {
        return Ok(VNC);
    }
    if offered.contains(&VENCRYPT) {
        return Ok(VENCRYPT);
    }
    if offered.contains(&APPLE_DH) {
        return Err(crate::VncError::CredentialsRequired { username: true });
    }
    if offered.contains(&VNC) {
        return Err(crate::VncError::CredentialsRequired { username: false });
    }
    Err(crate::VncError::UnsupportedSecurity(offered.to_vec()))
}

/// The VeNCrypt subtype to use; TLS and X.509 subtypes are refused.
pub fn choose_vencrypt(offered: &[u32], credentials: &Credentials) -> Result<u32, crate::VncError> {
    if offered.contains(&vencrypt::NONE) {
        return Ok(vencrypt::NONE);
    }
    let pass = credentials.password.is_some();
    // This client has no TLS transport. VeNCrypt Plain puts the full user name and
    // reusable password on the wire; never select it, including when offered beside VNC.
    if offered.contains(&vencrypt::VNC) && pass {
        return Ok(vencrypt::VNC);
    }
    if offered.contains(&vencrypt::VNC) {
        return Err(crate::VncError::CredentialsRequired { username: false });
    }
    if offered.contains(&vencrypt::PLAIN) {
        return Err(crate::VncError::Protocol(
            "VeNCrypt Plain would send your account password without encryption; the server must offer VNC authentication or a TLS-protected method".into(),
        ));
    }
    Err(crate::VncError::Protocol(format!(
        "VeNCrypt offers only unsupported TLS subtypes {offered:?}; configure VncAuth or None on the server"
    )))
}

#[cfg(test)]
mod tests;
