use super::*;

#[test]
fn only_a_service_manager_term_ends_the_host() {
    assert!(honors(libc::SIGTERM, 1));
    for sender in [0, 2, 4242] {
        assert!(!honors(libc::SIGTERM, sender), "TERM from {sender}");
    }
    for signal in [libc::SIGHUP, libc::SIGINT, libc::SIGQUIT] {
        assert!(!honors(signal, 1), "signal {signal} from PID 1");
    }
}
