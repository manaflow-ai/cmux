use super::*;

const ALIVE: Probe = Probe { process_alive: true, socket_accepts: true };
const STARTING: Probe = Probe { process_alive: true, socket_accepts: false };
const DOWN: Probe = Probe { process_alive: false, socket_accepts: false };

#[test]
fn a_slow_daemon_is_busy_and_never_offers_a_restart() {
    // Leo's case: a daemon that listens and answers late.
    assert_eq!(classify(ALIVE), Verdict { state: WaitState::Busy, offers_restart: false });
}

#[test]
fn a_listener_without_a_pid_file_is_busy() {
    let probe = Probe { process_alive: false, socket_accepts: true };
    assert_eq!(classify(probe), Verdict { state: WaitState::Busy, offers_restart: false });
}

#[test]
fn a_process_whose_socket_refuses_is_starting_without_a_restart() {
    assert_eq!(classify(STARTING), Verdict { state: WaitState::Starting, offers_restart: false });
}

#[test]
fn no_process_and_no_listener_is_down_and_offers_restart() {
    assert_eq!(classify(DOWN), Verdict { state: WaitState::Down, offers_restart: true });
}

#[test]
fn the_op_answers_json_and_refuses_a_partial_request() {
    let busy = json!({"process_alive": true, "socket_accepts": true, "waited_ms": 600_000});
    assert_eq!(call(&busy).unwrap(), json!({"state": "busy", "restart": false}));
    let down = call(&json!({"process_alive": false, "socket_accepts": false})).unwrap();
    assert_eq!(down, json!({"state": "down", "restart": true}));
    assert!(call(&json!({"process_alive": true})).is_none());
    assert!(call(&json!({"process_alive": true, "socket_accepts": "yes"})).is_none());
}
