use super::*;
use crate::backend::Backend;

const VM: &str = "vm_abcdefghij0123456789";

fn prod(team: Option<&str>) -> Scope {
    Scope::new(Backend::Production.owner_api(), team).expect("prod scope")
}

#[test]
fn a_machine_named_on_one_backend_is_refused_by_another_before_sending() {
    let machine = prod(Some("team_a")).machine(VM).expect("handle");
    let dev = Scope::new(Backend::Development.owner_api(), Some("team_a")).expect("dev scope");
    let refused = dev.route(&machine, "/exec").expect_err("another backend");
    assert_eq!(refused.machine, machine);
    assert!(refused.to_string().contains("nothing was sent"));
}

#[test]
fn a_machine_named_for_one_team_is_refused_for_another() {
    let machine = prod(Some("team_a")).machine(VM).expect("handle");
    assert!(prod(Some("team_b")).id_of(&machine).is_err());
    assert!(prod(None).id_of(&machine).is_err());
}

#[test]
fn its_own_scope_routes_it_on_its_backend() {
    let scope = prod(Some("team_a"));
    let machine = scope.machine(VM).expect("handle");
    assert_eq!(
        scope.route(&machine, "/client-session").expect("own scope"),
        format!("{}/v1/cloud/machines/{VM}/client-session", Backend::Production.owner_api())
    );
}

#[test]
fn two_spellings_of_one_origin_are_one_scope() {
    let a = Scope::new("https://Cloud-API.cmux.dev:443/", None).expect("a");
    let b = Scope::new("https://cloud-api.cmux.dev", None).expect("b");
    assert_eq!(a, b);
    assert_eq!(a.origin(), "https://cloud-api.cmux.dev");
}

#[test]
fn only_bare_secure_origins_make_a_scope() {
    for bad in [
        "http://cloud-api.cmux.dev",
        "https://user:pw@cloud-api.cmux.dev",
        "https://cloud-api.cmux.dev/v1",
        "https://cloud-api.cmux.dev?x=1",
        "cloud-api.cmux.dev",
        "",
    ] {
        assert_eq!(Scope::new(bad, None), Err(HandleError::Origin), "{bad}");
    }
    assert!(Scope::new("http://127.0.0.1:8787", None).is_ok());
    assert_eq!(Scope::new("https://x.example", Some("a b")), Err(HandleError::Team));
    assert_eq!(prod(None).machine("vm_ABC"), Err(HandleError::MachineId));
    assert_eq!(prod(None).machine("../x"), Err(HandleError::MachineId));
}

#[test]
fn a_saved_handle_reads_back_as_the_same_machine_and_is_checked_on_read() {
    let machine = prod(Some("team_a")).machine(VM).expect("handle");
    let saved = serde_json::to_value(&machine).expect("save");
    assert_eq!(
        saved,
        serde_json::json!({ "id": VM, "origin": Backend::Production.owner_api(), "team": "team_a" })
    );
    let back: Machine = serde_json::from_value(saved).expect("read");
    assert_eq!(back, machine);
    let tampered = serde_json::json!({ "id": VM, "origin": "http://evil.example" });
    assert!(serde_json::from_value::<Machine>(tampered).is_err());
}
