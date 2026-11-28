use super::*;

fn peer(name: &str, url: &str, connected: bool) -> Value {
    json!({"name": name, "url": url, "connected": connected})
}

fn book(rows: &[(&str, &str)]) -> Vec<(String, String)> {
    rows.iter().map(|(k, h)| (k.to_string(), h.to_string())).collect()
}

#[test]
fn a_cloud_machine_the_carrier_reaches_is_a_target() {
    let got = routes(&[], Some((true, book(&[("d-cloud", "cloud-a")]))));
    assert_eq!(got, vec![("cloud-a".to_owned(), Ok(Route::Carrier("cloud-a".to_owned())))]);
}

#[test]
fn an_ssh_peer_still_goes_over_ssh_and_is_not_listed_twice() {
    let peers = [peer("box", "ssh://me@box", true)];
    let got = routes(&peers, Some((true, book(&[("d-box", "box")]))));
    assert_eq!(got.len(), 1);
    assert!(matches!(&got[0].1, Ok(Route::Ssh(_))), "{got:?}");
}

#[test]
fn a_disconnected_ssh_peer_falls_back_to_the_carrier_or_is_refused() {
    let peers = [peer("box", "ssh://me@box", false)];
    let none = routes(&peers, Some((true, Vec::new())));
    assert_eq!(none, vec![("box".to_owned(), Err("not connected now".to_owned()))]);
    let carried = routes(&peers, Some((true, book(&[("d-box", "box")]))));
    assert_eq!(carried[0].1, Ok(Route::Carrier("box".to_owned())));
}

#[test]
fn the_carrier_off_or_a_shared_host_name_refuses() {
    let off = routes(&[], Some((false, book(&[("d-cloud", "cloud-a")]))));
    assert!(off[0].1.as_ref().unwrap_err().contains("carrier is off"), "{off:?}");
    // Two machines share a host: each goes by its id, which names exactly one.
    let shared = routes(&[], Some((true, book(&[("d1", "vm"), ("d2", "vm")]))));
    let names: Vec<&str> = shared.iter().map(|(n, _)| n.as_str()).collect();
    assert_eq!(names, vec!["d1", "d2"]);
    assert!(shared.iter().all(|(_, r)| r.is_ok()), "{shared:?}");
}

#[test]
fn without_the_carrier_a_non_ssh_peer_is_refused() {
    let got = routes(&[peer("hub-peer", "wss://x", true)], None);
    assert_eq!(got[0].1, Err("reached without ssh or the hub carrier".to_owned()));
}

#[test]
fn the_carrier_task_runs_the_hidden_runner_then_removes_the_script() {
    let me = crate::self_command::SelfCommand::new("/opt/acpmux".into(), Vec::new());
    let task = re::carrier_task_command(&me, "cloud-a", std::path::Path::new("/h/r1.sh"));
    assert_eq!(
        task,
        "'/opt/acpmux' 'run-elsewhere-carrier' '--machine' 'cloud-a' '--script' '/h/r1.sh'; rc=$?; rm -f '/h/r1.sh'; exit $rc"
    );
}
