use super::*;
use crate::VncError;

fn io() -> VncError {
    VncError::Io(std::io::Error::from(std::io::ErrorKind::ConnectionRefused))
}

#[test]
fn backoff_doubles_caps_and_resets_after_a_healthy_session() {
    let mut backoff = Backoff::default();
    let quick = Duration::from_millis(5);
    let delays: Vec<_> = (0..8).map(|_| backoff.after_failure(quick, &io()).unwrap()).collect();
    assert_eq!(delays[0], Duration::from_millis(250));
    assert_eq!(delays[1], Duration::from_millis(500));
    assert_eq!(delays[6], Duration::from_secs(10));
    assert_eq!(delays[7], Duration::from_secs(10));
    assert_eq!(
        backoff.after_failure(Duration::from_secs(60), &io()).unwrap(),
        Duration::from_millis(250)
    );
}

#[test]
fn repeated_protocol_errors_stop_unless_a_session_was_healthy() {
    let mut backoff = Backoff::default();
    let quick = Duration::from_millis(5);
    let protocol = || VncError::Protocol("encoding 99".into());
    assert!(backoff.after_failure(quick, &protocol()).is_some());
    assert!(backoff.after_failure(Duration::from_secs(60), &protocol()).is_some());
    assert!(backoff.after_failure(quick, &protocol()).is_some());
    assert_eq!(backoff.after_failure(quick, &protocol()), None);
    backoff.reset();
    assert!(backoff.after_failure(quick, &protocol()).is_some());
}

#[test]
fn auth_failures_never_retry() {
    let mut backoff = Backoff::default();
    assert_eq!(backoff.after_failure(Duration::ZERO, &VncError::AuthFailed("no".into())), None);
    assert_eq!(
        backoff.after_failure(Duration::ZERO, &VncError::CredentialsRequired { username: false }),
        None
    );
}
