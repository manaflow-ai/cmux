use super::*;

fn mac(name: &str, id: &str, machine: &str, online: bool, this: bool) -> Value {
    json!({"name": name, "device_id": id, "machine_id": machine, "online": online, "this": this})
}

#[test]
fn traffic_lists_busy_services_first_and_the_total() {
    let answer = json!({
        "ok": true, "uptime_s": 42,
        "total": {"service": "total", "in_bytes": 1_260_000, "out_bytes": 5_000,
                  "in_per_s_10s": 126_000, "out_per_s_10s": 500, "in_per_s_60s": 21_000, "out_per_s_60s": 83},
        "services": [
            {"service": "terminal", "in_bytes": 0, "out_bytes": 5_000,
             "in_per_s_10s": 0, "out_per_s_10s": 500, "in_per_s_60s": 0, "out_per_s_60s": 83},
            {"service": "chat", "in_bytes": 0, "out_bytes": 0,
             "in_per_s_10s": 0, "out_per_s_10s": 0, "in_per_s_60s": 0, "out_per_s_60s": 0},
            {"service": "remote", "in_bytes": 1_260_000, "out_bytes": 0,
             "in_per_s_10s": 126_000, "out_per_s_10s": 0, "in_per_s_60s": 21_000, "out_per_s_60s": 0},
        ],
    });
    let table = traffic_table(&answer);
    let lines: Vec<&str> = table.lines().collect();
    assert!(lines.first().is_some_and(|l| l.starts_with("service")), "{table}");
    assert!(
        lines.get(1).is_some_and(|l| l.starts_with("remote") && l.contains("126.0 KB/s")),
        "{table}"
    );
    assert!(lines.get(2).is_some_and(|l| l.starts_with("terminal")), "{table}");
    assert!(
        lines.get(3).is_some_and(|l| l.starts_with("total") && l.contains("1.3 MB")),
        "{table}"
    );
    assert!(!table.contains("chat"), "{table}");
    assert_eq!(human_bytes(999), "999 B");
    assert_eq!(human_bytes(1_500_000_000), "1.5 GB");
}

#[test]
fn a_name_picks_one_mac_and_never_this_one() {
    let list = vec![
        mac("Studio", "11111111-1111-1111-1111-111111111111", "aa", true, true),
        mac("MacBook", "22222222-2222-2222-2222-222222222222", "bb", true, false),
        mac("MacBook", "33333333-3333-3333-3333-333333333333", "bb", false, false),
    ];
    // Two builds of one computer: the online one.
    assert_eq!(
        pick(&list, "macbook").unwrap()["device_id"],
        "22222222-2222-2222-2222-222222222222"
    );
    assert_eq!(pick(&list, "33333333-3333-3333-3333-333333333333").unwrap()["online"], false);
    // This Mac is never a target.
    assert!(pick(&list, "Studio").unwrap_err().contains("no Mac named Studio"));
    // Nor is another build of this same computer (same machine id).
    let mut with_sibling = list.clone();
    with_sibling.push(mac("Studio DEV", "44444444-4444-4444-4444-444444444444", "aa", true, false));
    assert!(pick(&with_sibling, "Studio DEV").is_err());
    assert!(!pick(&with_sibling, "nope").unwrap_err().contains("Studio DEV"));
    assert!(pick(&list, "nope").unwrap_err().contains("MacBook"));
}

#[test]
fn only_selector_first_doctor_is_ours() {
    let words = |w: &[&str]| w.iter().map(|s| (*s).to_owned()).collect::<Vec<_>>();
    // The joined-machine doctor keeps `machine doctor [MACHINE]`.
    assert_eq!(run_if_requested(&words(&["machine", "doctor"])), None);
    assert_eq!(run_if_requested(&words(&["machine", "doctor", "x"])), None);
    assert_eq!(run_if_requested(&words(&["machine", "x", "show"])), None);
    assert_eq!(link_socket(Path::new("/t/main.sock")), PathBuf::from("/t/main.link.sock"));
}
