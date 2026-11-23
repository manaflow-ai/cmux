use super::*;

fn words(args: &[&str]) -> Vec<String> {
    args.iter().map(|word| (*word).to_owned()).collect()
}

fn routes(carrier: bool, machines: Value) -> Value {
    json!({"carrier": carrier, "carrierReason": null, "machines": machines})
}

fn ready(host: &str, key: &str, socket: &str) -> Value {
    json!({"host": host, "daemonId": key, "via": "hub", "route": "unix", "socket": socket,
        "state": "ready", "refusal": null})
}

#[test]
fn carrier_and_ssh_flags_choose_the_way_and_leave_the_rest() {
    assert_eq!(split_way(&words(&["box"])).unwrap(), (Way::Auto, words(&["box"])));
    assert_eq!(
        split_way(&words(&["box", "--carrier"])).unwrap(),
        (Way::CarrierOnly, words(&["box"]))
    );
    assert_eq!(split_way(&words(&["--ssh", "box"])).unwrap(), (Way::SshOnly, words(&["box"])));
    // A word after --ssh-arg is ssh's, not ours.
    assert_eq!(
        split_way(&words(&["box", "--ssh-arg", "--ssh"])).unwrap(),
        (Way::Auto, words(&["box", "--ssh-arg", "--ssh"]))
    );
    assert!(split_way(&words(&["box", "--carrier", "--ssh"])).is_err());
}

#[test]
fn only_a_bare_machine_name_with_no_option_tries_the_carrier() {
    assert_eq!(carrier_host(&words(&["buildbox"])), Some("buildbox"));
    assert_eq!(carrier_host(&words(&["air-blue.local"])), Some("air-blue.local"));
    for ssh_only in [
        words(&["leo@box"]),
        words(&["box:2222"]),
        words(&["box", "--session", "work"]),
        words(&["box", "--ssh-arg", "-v"]),
        words(&["-box"]),
        words(&[]),
    ] {
        assert_eq!(carrier_host(&ssh_only), None, "{ssh_only:?}");
    }
}

#[test]
fn a_listed_machine_resolves_to_its_route_socket_by_name_in_any_case() {
    let answer = routes(
        true,
        json!([
            ready("air-blue", "k1", "/home/u/.acpmux/m1"),
            ready("Lane-2", "k2", "/home/u/.acpmux/m2")
        ]),
    );
    assert_eq!(
        pick(&answer, "lane-2").unwrap(),
        Route { daemon_id: "k2".into(), socket: "/home/u/.acpmux/m2".into() }
    );
}

#[test]
fn an_unlisted_name_is_quiet_and_goes_to_ssh() {
    let refusal =
        pick(&routes(true, json!([ready("air-blue", "k1", "/s")])), "example.com").unwrap_err();
    assert_eq!(refusal.reason, "machine.unlisted");
    assert!(refusal.is_quiet());
    // No acpmux on this machine is quiet too: ssh users who never joined see nothing new.
    assert!(Refusal::new("acpmux.off", "x").is_quiet());
}

#[test]
fn a_listed_machine_with_the_carrier_off_says_so() {
    let refusal = pick(&routes(false, json!([ready("box", "k", "/s")])), "box").unwrap_err();
    assert_eq!(refusal.reason, "carrier.off");
    assert!(!refusal.is_quiet());
}

#[test]
fn a_route_that_could_not_bind_carries_its_recorded_refusal() {
    let answer = routes(
        true,
        json!([{"host": "box", "daemonId": "k", "via": "hub", "route": null, "state": "unavailable",
            "refusal": {"reason": "route.folder", "error": "not private"}}]),
    );
    assert_eq!(pick(&answer, "box").unwrap_err(), Refusal::new("route.folder", "not private"));
}

#[test]
fn a_refused_attach_reads_the_far_ends_reason_from_the_route() {
    let mut machine = ready("box", "k", "/s");
    machine["state"] = json!("refused");
    machine["refusal"] = json!({"reason": "consent_required", "error": "waiting for the person"});
    let answer = routes(true, json!([machine]));
    // A refused route is still tried: the person may have allowed it since.
    assert!(pick(&answer, "box").is_ok());
    assert_eq!(
        recorded_refusal(&answer, "k"),
        Some(Refusal::new("consent_required", "waiting for the person"))
    );
    assert_eq!(recorded_refusal(&answer, "other"), None);
}

#[test]
fn carrier_only_without_a_bare_machine_name_is_refused_before_any_dial() {
    let error = reach(&words(&["leo@box"]), Way::CarrierOnly).err().unwrap();
    assert!(error.to_string().contains("--carrier"), "{error:#}");
    assert!(reach(&words(&["leo@box"]), Way::Auto).unwrap().is_none());
}
