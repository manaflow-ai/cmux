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
    let chat = Chat { running: Some("a".into()), moved_here: true, back_home: true, ..chat() };
    let targets = targets(&chat);
    assert_eq!(ids(&targets), ["local", "b"]);
    assert_eq!((targets[0].kind, targets[0].label.as_str()), ("local", ""));
}

#[test]
fn a_cloud_chat_that_cannot_come_back_lists_only_machines() {
    let chat = Chat { running: Some("b".into()), moved_here: true, ..chat() };
    assert_eq!(ids(&targets(&chat)), ["a"]);
}

#[test]
fn nothing_moves_unstarted_chief_unloaded_or_elsewhere() {
    for chat in [
        Chat { started: false, ..chat() },
        Chat { chief: true, ..chat() },
        Chat { offered: false, ..chat() },
        Chat { elsewhere: true, ..chat() },
        Chat { running: Some("a".into()), back_home: true, ..chat() },
    ] {
        assert!(targets(&chat).is_empty(), "{chat:?}");
    }
}

fn ssh_machine(id: &str, names: &[&str]) -> SshMachine {
    SshMachine {
        id: id.into(),
        title: String::new(),
        online: true,
        names: names.iter().map(|n| (*n).into()).collect(),
    }
}

#[test]
fn an_ssh_machine_without_a_title_is_labelled_by_its_first_name() {
    let chat =
        Chat { offered: false, ssh: vec![ssh_machine("ssh-a", &["a.example", "a"])], ..chat() };
    let targets = targets(&chat);
    assert_eq!((ids(&targets), targets[0].label.as_str()), (vec!["ssh-a"], "a.example"));
}

#[test]
fn a_peer_is_matched_by_name_before_url_and_any_case() {
    let machine = ssh_machine("ssh-a", &["A.example."]);
    let peers = [
        Peer { name: "other".into(), url: "ssh://me@a.example".into() },
        Peer { name: "a.example".into(), url: "ssh://elsewhere".into() },
    ];
    assert_eq!(peer_of(&machine, &peers), Some("a.example"));
    assert_eq!(peer_of(&machine, &peers[..1]), Some("other"));
    assert_eq!(peer_of(&machine, &[]), None);
}
