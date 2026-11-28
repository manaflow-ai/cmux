use super::*;

/// Only the person's own local connection reaches these methods.
#[test]
fn consent_grant_methods_refuse_a_connection_that_is_not_the_persons_local_one() {
    assert!(person_local(true, Origin::Local).is_ok());
    for (person, origin) in [
        (false, Origin::Local),
        (true, Origin::Web),
        (true, Origin::Peer),
        (true, Origin::LocalApp),
        (false, Origin::Peer),
    ] {
        let refused = person_local(person, origin).unwrap_err();
        assert_eq!(
            refused.data.as_ref().and_then(|d| d.get("reason")).and_then(Value::as_str),
            Some("permission.person_required"),
            "{person} {origin:?}"
        );
    }
}
