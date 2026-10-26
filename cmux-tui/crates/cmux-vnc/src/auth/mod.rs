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

/// VeNCrypt subtypes this client can finish without TLS.
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
    let (user, pass) = (credentials.username.is_some(), credentials.password.is_some());
    if offered.contains(&vencrypt::PLAIN) && user && pass {
        return Ok(vencrypt::PLAIN);
    }
    if offered.contains(&vencrypt::VNC) && pass {
        return Ok(vencrypt::VNC);
    }
    if offered.contains(&vencrypt::PLAIN) {
        return Err(crate::VncError::CredentialsRequired { username: true });
    }
    if offered.contains(&vencrypt::VNC) {
        return Err(crate::VncError::CredentialsRequired { username: false });
    }
    Err(crate::VncError::Protocol(format!(
        "VeNCrypt offers only TLS subtypes {offered:?}; allow VncAuth or None on the server"
    )))
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::VncError;

    fn creds(user: Option<&str>, pass: Option<&str>) -> Credentials {
        Credentials { username: user.map(Into::into), password: pass.map(Into::into) }
    }

    #[test]
    fn choice_per_guest_os() {
        // Linux devbox (TigerVNC, SecurityTypes None).
        assert_eq!(choose(&[1], &creds(None, None)).unwrap(), 1);
        // macOS Screen Sharing.
        assert_eq!(choose(&[30, 33, 36, 35], &creds(Some("me"), Some("pw"))).unwrap(), 30);
        assert!(matches!(
            choose(&[30, 33, 36, 35], &creds(None, Some("pw"))),
            Err(VncError::CredentialsRequired { username: true })
        ));
        // macOS with "VNC viewers may control screen with password".
        assert_eq!(choose(&[30, 2], &creds(None, Some("pw"))).unwrap(), 2);
        // Windows TightVNC / UltraVNC.
        assert_eq!(choose(&[2], &creds(None, Some("pw"))).unwrap(), 2);
        assert!(matches!(
            choose(&[2], &creds(None, None)),
            Err(VncError::CredentialsRequired { username: false })
        ));
        // RealVNC with only its own RA2 types.
        assert!(matches!(
            choose(&[5, 6], &creds(None, None)),
            Err(VncError::UnsupportedSecurity(_))
        ));
        // TigerVNC default: VeNCrypt.
        assert_eq!(choose(&[19, 2], &creds(None, None)).unwrap(), 19);
    }

    #[test]
    fn vencrypt_refuses_tls_only() {
        assert_eq!(choose_vencrypt(&[257, 2], &creds(None, Some("p"))).unwrap(), 2);
        assert_eq!(choose_vencrypt(&[256], &creds(Some("u"), Some("p"))).unwrap(), 256);
        assert!(matches!(
            choose_vencrypt(&[257, 258, 262], &creds(None, None)),
            Err(VncError::Protocol(_))
        ));
        assert!(matches!(
            choose_vencrypt(&[2], &creds(None, None)),
            Err(VncError::CredentialsRequired { username: false })
        ));
    }

    #[test]
    fn debug_never_prints_the_password() {
        let text = format!("{:?}", creds(Some("u"), Some("secret")));
        assert!(!text.contains("secret"));
    }
}
