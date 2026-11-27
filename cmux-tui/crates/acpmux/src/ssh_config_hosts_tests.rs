use super::*;

#[test]
fn ssh_config_discovery_follows_includes_and_skips_patterns() {
    let temp = tempfile::tempdir().unwrap();
    let home = temp.path();
    let ssh_root = home.join(".ssh");
    let include_root = ssh_root.join("hosts");
    fs::create_dir_all(&include_root).unwrap();
    fs::write(
        ssh_root.join("config"),
        "Include hosts/*.conf\nHost buildbox *.internal !blocked duplicate\n",
    )
    .unwrap();
    fs::write(include_root.join("a.conf"), "Host mini duplicate\n  HostName 192.0.2.10\n").unwrap();
    fs::write(include_root.join("b.conf"), "Host=quoted-host # note\n").unwrap();

    assert_eq!(
        ssh_config_hosts_from_path(&ssh_root.join("config"), &ssh_root, home),
        vec!["buildbox", "duplicate", "mini", "quoted-host"]
    );
}

#[test]
fn ssh_config_discovery_reads_each_hosts_first_host_name() {
    let temp = tempfile::tempdir().unwrap();
    let home = temp.path();
    let ssh_root = home.join(".ssh");
    fs::create_dir_all(&ssh_root).unwrap();
    fs::write(
        ssh_root.join("config"),
        "Host gh\n  HostName github.com\nHost gh\n  HostName example.com\n\
             Host mini mini-b\n  HostName %h.tail1234.ts.net\nHost *.corp\n  HostName x\n\
             Match host plain\n  HostName y\nHost plain\n",
    )
    .unwrap();
    let host = |alias: &str, host_name: Option<&str>| SshConfigHost {
        alias: alias.to_owned(),
        host_name: host_name.map(str::to_owned),
    };
    assert_eq!(
        ssh_config_targets_from_path(&ssh_root.join("config"), &ssh_root, home),
        vec![
            host("gh", Some("github.com")),
            host("mini", Some("mini.tail1234.ts.net")),
            host("mini-b", Some("mini-b.tail1234.ts.net")),
            host("plain", None),
        ]
    );
}

/// Writes each `(file, lines)` under a scratch `~/.ssh` and reads the
/// config's hosts with their HostNames.
fn host_names_of(files: &[(&str, &[&str])]) -> Vec<(String, Option<String>)> {
    let temp = tempfile::tempdir().unwrap();
    let home = temp.path();
    let ssh_root = home.join(".ssh");
    fs::create_dir_all(&ssh_root).unwrap();
    for (file, lines) in files {
        fs::write(ssh_root.join(file), lines.join("\n") + "\n").unwrap();
    }
    ssh_config_targets_from_path(&ssh_root.join("config"), &ssh_root, home)
        .into_iter()
        .map(|h| (h.alias, h.host_name))
        .collect()
}

fn named(alias: &str, host_name: &str) -> (String, Option<String>) {
    (alias.to_owned(), Some(host_name.to_owned()))
}

#[test]
fn a_host_name_from_an_include_counts_where_the_include_stands() {
    // `early` comes before `gh`'s block, so its HostName wins. `inside`
    // is read inside `lab`'s block, so it names `lab` and never
    // `target` or `other` (ssh reads it only for lab). `loop` includes
    // the config again, which stops.
    let config: &[&str] = &[
        "Include early",
        "Host gh",
        "  HostName example.com",
        "Host lab",
        "  Include inside",
        "Host lab2",
        "  Include loop",
        "Host target",
        "  HostName target.internal",
    ];
    let names = host_names_of(&[
        ("config", config),
        ("early", &["Host gh", "  HostName github.com"]),
        ("inside", &["HostName 10.0.4.2", "Host target other", "  HostName github.com"]),
        ("loop", &["Include config", "HostName lab2.internal"]),
    ]);
    assert_eq!(
        names,
        vec![
            named("gh", "github.com"),
            named("lab", "10.0.4.2"),
            named("lab2", "lab2.internal"),
            named("target", "target.internal"),
            ("other".to_owned(), None),
        ]
    );
}

#[test]
fn a_negated_host_keeps_its_block_and_includes_from_that_host() {
    let config: &[&str] = &[
        "Host lab !lab",
        "  HostName github.com",
        "Host box gpu.corp !*.corp",
        "  HostName gitlab.com",
        "  Include under",
        "Host lab",
        "  HostName lab.internal",
        "Host gpu.corp",
        "  HostName 10.0.0.9",
    ];
    let names = host_names_of(&[("config", config), ("under", &["HostName ignored.example"])]);
    assert_eq!(
        names,
        vec![
            // Discovery order is unchanged: every concrete alias, in order.
            named("lab", "lab.internal"),
            named("box", "gitlab.com"),
            named("gpu.corp", "10.0.0.9"),
        ]
    );
    assert!(ssh_pattern_matches("*.corp", "gpu.corp"));
    assert!(ssh_pattern_matches("g?u*", "gpu.corp"));
    assert!(!ssh_pattern_matches("*.corp", "corp"));
    assert!(!ssh_pattern_matches("lab", "lab2"));
}

#[test]
fn a_host_name_before_any_host_line_is_every_hosts() {
    let names = host_names_of(&[
        (
            "config",
            &["Include first", "HostName second.example", "Host jump", "  HostName jump.internal"],
        ),
        ("first", &["HostName %h.tail1234.ts.net"]),
    ]);
    assert_eq!(names, vec![named("jump", "jump.tail1234.ts.net")]);
}

#[test]
fn a_host_s_own_name_read_before_the_global_one_wins() {
    let names = host_names_of(&[
        (
            "config",
            &["Include early", "HostName old-air.tail1234.ts.net", "Host jump", "  HostName x"],
        ),
        ("early", &["Host jump", "  HostName jump.internal"]),
    ]);
    assert_eq!(names, vec![named("jump", "jump.internal")]);
}

#[test]
fn a_host_name_may_be_set_with_an_equals_sign() {
    let config: &[&str] = &[
        "Host a",
        "  HostName = a.example",
        "Host b",
        "  HostName =b.example",
        "Host c",
        "  HostName= c.example",
        "Host d",
        "  HostName=d.example",
        "Host = e",
        "  HostName e.example",
    ];
    let names = host_names_of(&[("config", config)]);
    let want = |a: &str| named(a, &format!("{a}.example"));
    assert_eq!(names, vec![want("a"), want("b"), want("c"), want("d"), want("e")]);
}

#[test]
fn ssh_config_discovery_breaks_include_cycles() {
    let temp = tempfile::tempdir().unwrap();
    let home = temp.path();
    let ssh_root = home.join(".ssh");
    fs::create_dir_all(&ssh_root).unwrap();
    fs::write(ssh_root.join("config"), "Include loop\nHost root\n").unwrap();
    fs::write(ssh_root.join("loop"), "Include config\nHost nested\n").unwrap();

    assert_eq!(
        ssh_config_hosts_from_path(&ssh_root.join("config"), &ssh_root, home),
        vec!["root", "nested"]
    );
}
