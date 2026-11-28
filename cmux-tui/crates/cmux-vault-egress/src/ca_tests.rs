use super::*;

#[test]
fn a_kept_ca_signs_as_the_first_did() {
    let first = Authority::generate().unwrap();
    let kept = Authority::from_kept(&first.key_pem(), first.pem()).unwrap();
    assert_eq!(kept.pem(), first.pem());
    assert_eq!(*kept.key_pem(), *first.key_pem());
    assert!(kept.server_config("api.example.com").is_ok());
}

#[test]
fn a_kept_ca_is_refused_when_not_a_pair_or_expiring() {
    let a = Authority::generate().unwrap();
    let b = Authority::generate().unwrap();
    assert_eq!(Authority::from_kept(&a.key_pem(), b.pem()).err(), Some(NotKept::NotOurs));
    assert_eq!(Authority::from_kept("nope", a.pem()).err(), Some(NotKept::Key));
    assert_eq!(Authority::from_kept(&a.key_pem(), "nope").err(), Some(NotKept::Certificate));
    let short = Authority::generate_for(30).unwrap();
    assert_eq!(Authority::from_kept(&short.key_pem(), short.pem()).err(), Some(NotKept::Expiring));
}

#[test]
fn debug_never_shows_the_key() {
    let a = Authority::generate().unwrap();
    assert_eq!(format!("{a:?}"), "Authority(..)");
    assert!(!a.pem().contains("PRIVATE KEY"));
}
