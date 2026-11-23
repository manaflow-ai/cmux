use super::*;

#[test]
fn the_code_challenge_is_rfc_7636_s256() {
    // RFC 7636 appendix B.
    assert_eq!(
        code_challenge("dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk"),
        "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM"
    );
}

#[test]
fn random_strings_are_alphanumeric_of_the_length_asked() {
    let one = random_string(64).unwrap();
    assert_eq!(one.len(), 64);
    assert!(one.bytes().all(|b| b.is_ascii_alphanumeric()));
    assert_ne!(one, random_string(64).unwrap());
}

#[test]
fn a_callback_reads_its_code_or_error() {
    assert_eq!(OAuthCallback::parse("cmux://s?code=a%20b"), OAuthCallback::Code("a b".into()));
    assert_eq!(
        OAuthCallback::parse("cmux://e?error=access_denied&error_description=no"),
        OAuthCallback::Error { code: "access_denied".into(), description: Some("no".into()) }
    );
    assert_eq!(OAuthCallback::parse("cmux://s"), OAuthCallback::MissingCode);
    assert_eq!(OAuthCallback::parse("not a url"), OAuthCallback::MissingCode);
    assert!(!format!("{:?}", OAuthCallback::Code("secret".into())).contains("secret"));
}
