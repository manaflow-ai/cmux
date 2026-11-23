use std::sync::Arc;
use std::time::{Duration, Instant};

use super::model::{Available, Found};
use super::reach::{self, Dial, Probe, SshReach};
use super::{available_lines, probe_available};

#[test]
fn ssh_g_names_the_host_name_and_port_ssh_dials() {
    let out = "user leo\nhostname build-box.tail1234.ts.net\nport 2222\nidentityfile ~/.ssh/id\n";
    assert_eq!(
        reach::dial_of("bb", out),
        Dial::Direct { host: "build-box.tail1234.ts.net".into(), port: 2222 }
    );
}

#[test]
fn a_host_ssh_reaches_through_a_proxy_is_not_dialed_directly() {
    assert_eq!(
        reach::dial_of("inner", "hostname 10.0.0.4\nport 22\nproxyjump bastion\n"),
        Dial::Proxied
    );
    assert_eq!(
        reach::dial_of("inner", "hostname 10.0.0.4\nproxycommand nc %h %p\n"),
        Dial::Proxied
    );
    assert_eq!(
        reach::dial_of("leo@mini-7", "port 22\nproxycommand none\n"),
        Dial::Direct { host: "mini-7".into(), port: 22 }
    );
}

fn hosts(n: usize) -> Vec<String> {
    (0..n).map(|i| format!("host-{i}")).collect()
}

#[test]
fn every_host_gets_its_own_answer_in_order() {
    let probe: Probe = Arc::new(|host: &str, _| match host {
        "host-1" => SshReach::Open,
        "host-2" => SshReach::Unprobed,
        _ => SshReach::NoAnswer,
    });
    let got = reach::probe_all(&hosts(4), Duration::from_secs(2), &probe);
    assert_eq!(got, [SshReach::NoAnswer, SshReach::Open, SshReach::Unprobed, SshReach::NoAnswer]);
}

/// 57 hosts that all hang (a tailnet ACL drops tcp:22) cost the budget once, not 57 times.
#[test]
fn hung_hosts_cost_one_budget_whatever_their_count() {
    let probe: Probe = Arc::new(|host: &str, _| {
        if host == "host-0" {
            return SshReach::Open;
        }
        std::thread::sleep(Duration::from_secs(30));
        SshReach::Open
    });
    let budget = Duration::from_millis(300);
    let started = Instant::now();
    let got = reach::probe_all(&hosts(57), budget, &probe);
    let took = started.elapsed();
    assert!(took >= budget && took < budget * 4, "took {took:?}");
    assert_eq!(got[0], SshReach::Open);
    assert!(got[1..].iter().all(|r| *r == SshReach::NoAnswer));
}

#[test]
fn a_pass_with_every_answer_in_returns_before_its_budget() {
    let probe: Probe = Arc::new(|_: &str, _| SshReach::Open);
    let started = Instant::now();
    let got = reach::probe_all(&hosts(57), Duration::from_secs(10), &probe);
    assert!(started.elapsed() < Duration::from_secs(5));
    assert!(got.iter().all(|r| *r == SshReach::Open));
}

#[test]
fn hosts_past_the_cap_keep_their_add_command() {
    let probe: Probe = Arc::new(|_: &str, _| SshReach::NoAnswer);
    let got = reach::probe_all(&hosts(reach::MAX_HOSTS + 3), Duration::from_secs(2), &probe);
    assert_eq!(got[reach::MAX_HOSTS - 1], SshReach::NoAnswer);
    assert!(got[reach::MAX_HOSTS..].iter().all(|r| *r == SshReach::Unprobed));
}

/// The real probe against a port on this machine: a listener answers, a closed port does not.
#[test]
fn the_tcp_probe_tells_a_listening_port_from_a_closed_one() {
    let listener = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
    let open = listener.local_addr().unwrap().port();
    let closed = {
        let l = std::net::TcpListener::bind("127.0.0.1:0").unwrap();
        l.local_addr().unwrap().port()
    };
    let deadline = Instant::now() + Duration::from_secs(2);
    assert_eq!(
        reach::dial_probe(&Dial::Direct { host: "127.0.0.1".into(), port: open }, deadline),
        SshReach::Open
    );
    assert_eq!(
        reach::dial_probe(&Dial::Direct { host: "127.0.0.1".into(), port: closed }, deadline),
        SshReach::NoAnswer
    );
    assert_eq!(reach::dial_probe(&Dial::Proxied, deadline), SshReach::Unprobed);
}

fn row(name: &str, found: Found, ssh: Option<SshReach>) -> Available {
    Available {
        name: name.into(),
        address: format!("{name}.tail1234.ts.net"),
        os: "linux".into(),
        mine: true,
        found,
        ssh,
    }
}

/// The dogfood case: 57 tailnet hosts whose ssh port the ACL drops become one line and one hint,
/// and the one host that answers keeps its add command.
#[test]
fn silent_hosts_fold_into_one_line_with_the_acl_hint_once() {
    let mut rows: Vec<Available> = (0..57)
        .map(|i| row(&format!("vm-{i:02}"), Found::Network, Some(SshReach::NoAnswer)))
        .collect();
    rows.push(row("build-box", Found::Network, Some(SshReach::Open)));
    rows.push(row("bastioned", Found::SshConfig, Some(SshReach::Unprobed)));
    let lines = available_lines(&rows);
    let adds: Vec<&String> = lines.iter().filter(|l| l.contains("cmux device add")).collect();
    assert_eq!(adds.len(), 2, "{lines:#?}");
    assert!(adds[0].contains("build-box.tail1234.ts.net --yes"));
    assert!(adds[1].contains("bastioned"));
    assert_eq!(lines.len(), 4, "{lines:#?}");
    assert!(lines[2].starts_with("  ssh not reachable from here (57): vm-00, vm-01"));
    assert!(lines[2].ends_with("vm-11, and 45 more"), "{}", lines[2]);
    assert!(lines[3].contains("tcp:22") && lines[3].contains("Tailscale SSH"));
}

#[test]
fn an_unprobed_list_prints_every_add_command_as_before() {
    let rows = vec![row("a", Found::Network, None), row("b", Found::SshConfig, None)];
    let lines = available_lines(&rows);
    assert_eq!(lines.len(), 2);
    assert!(lines.iter().all(|l| l.contains("cmux device add")));
}

#[test]
fn ssh_config_hosts_that_do_not_answer_get_no_tailnet_hint() {
    let rows = vec![row("old-box", Found::SshConfig, Some(SshReach::NoAnswer))];
    let lines = available_lines(&rows);
    assert_eq!(lines, ["  ssh not reachable from here (1): old-box"]);
}

/// The probe fills each row, and `--json` keeps every row: a field is added, none removed.
#[test]
fn the_probe_marks_every_row_and_json_keeps_them_all() {
    let mut rows = vec![row("up", Found::Network, None), row("down", Found::Network, None)];
    let probe: Probe =
        Arc::new(
            |host: &str, _| {
                if host.starts_with("up.") { SshReach::Open } else { SshReach::NoAnswer }
            },
        );
    probe_available(&mut rows, &probe);
    assert_eq!(rows[0].ssh, Some(SshReach::Open));
    assert_eq!(rows[1].ssh, Some(SshReach::NoAnswer));
    let v = serde_json::to_value(&rows).unwrap();
    assert_eq!(v[0]["ssh"], "open");
    assert_eq!(v[1]["ssh"], "no-answer");
    assert_eq!(v[1]["address"], "down.tail1234.ts.net");
    let unprobed = serde_json::to_value(row("x", Found::Network, None)).unwrap();
    assert!(unprobed.get("ssh").is_none(), "an unprobed row serializes as it did before");
}
