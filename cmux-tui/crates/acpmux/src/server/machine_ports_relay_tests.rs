use super::*;
use crate::server::Origin;
use crate::server::conn_auth::ConnAuth;

#[test]
fn machine_ports_call_names_one_machine() {
    assert_eq!(parse(&json!({"machine": " studio "})).unwrap(), "studio");
    let code = |v: Value| parse(&v).unwrap_err().data.unwrap()["code"].clone();
    assert_eq!(code(json!({})), "invalid_arguments");
    assert_eq!(code(json!({"machine": " "})), "invalid_arguments");
    assert_eq!(code(json!({"machine": "a\nb"})), "invalid_arguments");
    assert_eq!(code(json!({"machine": "x".repeat(257)})), "invalid_arguments");
}

#[test]
fn machine_ports_call_is_sent_on_from_the_local_socket_only() {
    // The relay's gate is `admit`'s Forward, the same as machine_files_call's.
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
