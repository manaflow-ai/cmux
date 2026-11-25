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
    assert!(matches!(choose(&[5, 6], &creds(None, None)), Err(VncError::UnsupportedSecurity(_))));
    // TigerVNC default: VeNCrypt.
    assert_eq!(choose(&[19, 2], &creds(None, None)).unwrap(), 19);
}

#[test]
fn vencrypt_refuses_plaintext_passwords_and_tls_only() {
    assert_eq!(choose_vencrypt(&[257, 2], &creds(None, Some("p"))).unwrap(), 2);
    assert!(matches!(
        choose_vencrypt(&[256], &creds(Some("u"), Some("p"))),
        Err(VncError::Protocol(message)) if message.contains("VeNCrypt Plain")
    ));
    assert_eq!(choose_vencrypt(&[256, 2], &creds(Some("u"), Some("p"))).unwrap(), 2);
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
