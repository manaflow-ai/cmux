use super::*;
use crate::server::Origin;
use crate::server::conn_auth::ConnAuth;

#[test]
fn machine_files_call_names_one_machine_and_a_listed_action() {
    let (machine, action, inner) =
        parse(&json!({"machine": "studio", "action": "exec", "params": {"argv": ["uname"]}}))
            .unwrap();
    assert_eq!((machine.as_str(), action.as_str()), ("studio", "exec"));
    assert_eq!(inner, json!({"argv": ["uname"]}));
    let code = |v: Value| parse(&v).unwrap_err().data.unwrap()["code"].clone();
    assert_eq!(code(json!({"action": "exec"})), "invalid_arguments");
    assert_eq!(code(json!({"machine": " ", "action": "exec"})), "invalid_arguments");
    assert_eq!(code(json!({"machine": "studio", "action": "agent.start"})), "unknown_action");
    assert_eq!(
        code(json!({"machine": "studio", "action": "exec", "params": {"_level": "full"}})),
        "machine_call_denied"
    );
}

#[test]
fn machine_files_call_is_sent_on_from_the_local_socket_only() {
    assert!(matches!(admit(Origin::Local, ConnAuth::LocalSocket, None), Admission::Forward));
    for (origin, auth) in [
        (Origin::Peer, ConnAuth::PeerToken),
        (Origin::Peer, ConnAuth::Device),
        (Origin::Web, ConnAuth::LocalSocket),
        (Origin::LocalApp, ConnAuth::LocalSocket),
    ] {
        assert!(!matches!(admit(origin, auth, None), Admission::Forward), "{origin:?} {auth:?}");
    }
}
