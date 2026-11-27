use super::*;

fn machine(id: &str, status: &str) -> Machine {
    Machine { id: id.into(), title: format!("{id} box"), status: status.into() }
}

fn chat() -> Chat {
    Chat {
        offered: true,
        started: true,
        machines: vec![
            machine("a", "running"),
            machine("b", "stopped"),
            machine("c", "failed"),
            machine("d", "deleting"),
        ],
        ..Chat::default()
    }
}

fn ids(targets: &[Target]) -> Vec<&str> {
    targets.iter().map(|target| target.id.as_str()).collect()
}

#[test]
fn a_chat_of_this_mac_lists_every_live_cloud_machine() {
    let targets = targets(&chat());
    assert_eq!(ids(&targets), ["a", "b"]);
    assert_eq!(targets[1].status, "stopped");
    assert_eq!(targets[0].kind, "cloud");
}

#[test]
fn a_cloud_chat_lists_this_mac_first_and_never_its_own_machine() {
    let chat = Chat { running: Some("a".into()), back_home: true, ..chat() };
    let targets = targets(&chat);
    assert_eq!(ids(&targets), ["local", "b"]);
    assert_eq!((targets[0].kind, targets[0].label.as_str()), ("local", ""));
}

#[test]
fn a_cloud_chat_that_cannot_come_back_lists_only_machines() {
    let chat = Chat { running: Some("b".into()), ..chat() };
    assert_eq!(ids(&targets(&chat)), ["a"]);
}

#[test]
fn nothing_moves_unstarted_chief_unloaded_or_elsewhere() {
    for chat in [
        Chat { started: false, ..chat() },
        Chat { chief: true, ..chat() },
        Chat { offered: false, ..chat() },
        Chat { elsewhere: true, ..chat() },
    ] {
        assert!(targets(&chat).is_empty(), "{chat:?}");
    }
}
