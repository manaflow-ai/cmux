use super::Keepers;

fn idle() -> Keepers {
    Keepers {
        armed: true,
        clients: 0,
        browser_host: false,
        app_servers: 0,
        chief_brains: 0,
        terminals: Some(0),
    }
}

#[test]
fn an_armed_owner_with_nothing_kept_may_stop() {
    assert!(idle().none());
}

#[test]
fn an_owner_its_app_never_reached_is_kept() {
    assert!(!Keepers { armed: false, ..idle() }.none());
}

#[test]
fn each_keeper_alone_keeps_the_owner() {
    assert!(!Keepers { clients: 1, ..idle() }.none());
    assert!(!Keepers { browser_host: true, ..idle() }.none());
    assert!(!Keepers { app_servers: 1, ..idle() }.none());
    assert!(!Keepers { chief_brains: 1, ..idle() }.none());
    assert!(!Keepers { terminals: Some(1), ..idle() }.none());
}

#[test]
fn an_unread_terminal_count_keeps_the_owner() {
    assert!(!Keepers { terminals: None, ..idle() }.none());
}

#[test]
fn terminals_are_read_only_when_nothing_cheaper_keeps_the_owner() {
    assert!(idle().terminals_decide());
    assert!(!Keepers { armed: false, ..idle() }.terminals_decide());
    assert!(!Keepers { clients: 1, ..idle() }.terminals_decide());
    assert!(!Keepers { browser_host: true, ..idle() }.terminals_decide());
    assert!(!Keepers { app_servers: 2, ..idle() }.terminals_decide());
    assert!(!Keepers { chief_brains: 1, ..idle() }.terminals_decide());
}
