use super::*;

#[test]
fn only_remote_callers_are_refused_private_ranges() {
    assert!(!CallerLocality::Local.refuses_private_ranges());
    for class in
        [PrincipalClass::User, PrincipalClass::Mux, PrincipalClass::Agent, PrincipalClass::Run]
    {
        let remote = CallerLocality::Remote {
            principal: RemotePrincipal {
                user: "u".into(),
                install: "i".into(),
                class,
                interactive: true,
            },
        };
        assert!(remote.refuses_private_ranges(), "{class:?}");
    }
}
