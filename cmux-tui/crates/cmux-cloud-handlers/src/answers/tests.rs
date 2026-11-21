//! The answers' text and fields (CloudBrowserActionTests, CloudLivePreviewTests and the file,
//! domain and network actions' answers).

use super::*;

fn found(value: Value) -> Answer {
    of(&serde_json::from_value(value).unwrap())
}

#[test]
fn a_file_list_marks_folders_and_sizes() {
    let listed = found(json!({"kind": "filesList", "path": "/w", "entries": [
        {"kind": "directory", "name": "src"}, {"kind": "file", "name": "a.txt", "size": 12}]}));
    assert_eq!(listed.text.as_deref(), Some("d src\n- a.txt 12 bytes"));
    assert_eq!(Value::Object(listed.fields), json!({"path": "/w", "count": 2}));
    assert_eq!(
        found(json!({"kind": "filesList", "path": "/w", "entries": []})).text.as_deref(),
        Some("(empty)")
    );
}

#[test]
fn a_file_read_is_text_or_base64() {
    let text = found(
        json!({"kind": "fileRead", "path": "/a", "text": "hi", "dataBase64": "aGk=", "size": 2}),
    );
    assert_eq!(text.text.as_deref(), Some("hi"));
    assert_eq!(Value::Object(text.fields), json!({"path": "/a", "encoding": "utf8", "size": 2}));
    let binary = found(json!({"kind": "fileRead", "path": "/b", "dataBase64": "AAE="}));
    assert_eq!(binary.text.as_deref(), Some("AAE="));
    assert_eq!(
        Value::Object(binary.fields),
        json!({"path": "/b", "encoding": "base64", "data_base64": "AAE="})
    );
}

#[test]
fn a_stat_says_its_mode_in_octal() {
    let stat = found(
        json!({"kind": "fileStat", "path": "/a", "fileKind": "file", "size": 3, "mode": 420}),
    );
    assert_eq!(stat.text.as_deref(), Some("kind: file\nsize: 3 bytes\nmode: 644"));
    assert_eq!(
        Value::Object(stat.fields),
        json!({"path": "/a", "kind": "file", "size": 3, "mode": "644"})
    );
}

#[test]
fn an_scp_endpoint_says_when_it_expires() {
    let scp = found(
        json!({"kind": "scp", "host": "h", "port": 22, "username": "cmux", "hostPublicKey": "ssh-ed25519 K", "expiresAtUnix": 1_700_000_000}),
    );
    assert_eq!(
        scp.text.as_deref(),
        Some(
            "host: h\nport: 22\nuser: cmux\nhost key: ssh-ed25519 K\nexpires: 2023-11-14 22:13:20 +0000"
        )
    );
    assert_eq!(scp.fields["expires_at"], json!(1_700_000_000));
    assert_eq!(scp.fields["host_key"], json!("ssh-ed25519 K"));
}

#[test]
fn domains_publications_and_keys_have_their_lines() {
    let domains = found(
        json!({"kind": "domains", "items": [{"hostname": "a.dev", "verificationState": "verified"}, {"id": "d-2"}, {}]}),
    );
    assert_eq!(
        domains.text.as_deref(),
        Some(
            "a.dev (verification: verified, certificate: unknown)\nd-2 (verification: unknown, certificate: unknown)\n(unnamed) (verification: unknown, certificate: unknown)"
        )
    );
    assert_eq!(domains.fields["count"], json!(3));
    let publications = found(
        json!({"kind": "publications", "items": [{"hostname": "p.dev", "state": "live", "accessMode": "key"}, {"id": "p-2"}]}),
    );
    assert_eq!(publications.text.as_deref(), Some("p.dev (live, access: key)\np-2 (unknown)"));
    assert_eq!(found(json!({"kind": "publications", "items": []})).text.as_deref(), Some("(none)"));
    let keys = found(
        json!({"kind": "apiKeys", "items": [{"id": "k1", "name": "ci", "hint": "abcd"}, {"id": "k2"}]}),
    );
    assert_eq!(keys.text.as_deref(), Some("k1 ci (…abcd)\nk2  (…)"));
}

#[test]
fn networks_have_their_lines() {
    let networks = found(
        json!({"kind": "networks", "items": [{"id": "n1", "scope": "team", "cidr": "10.0.0.0/24"}, {"id": "n2", "scope": "user"}]}),
    );
    assert_eq!(networks.text.as_deref(), Some("n1 (team) 10.0.0.0/24\nn2 (user) "));
}

#[test]
fn daemon_ports_are_listed_or_left_to_the_app() {
    let ports = found(json!({"kind": "ports", "machineId": "vm-1", "ports": [3000, 8080]}));
    assert_eq!(ports.text.as_deref(), Some("3000\n8080"));
    assert_eq!(ports.fields["ports"], json!("3000,8080"));
    let none = found(json!({"kind": "ports", "machineId": "vm-1", "ports": []}));
    assert_eq!((none.text, none.copyable), (None, false));
}

#[test]
fn a_forward_record_becomes_its_local_url() {
    let record = json!({"machine": "vm-1", "port": 3000.0, "localPort": 52011.0, "state": "open"});
    assert_eq!(
        Value::Object(forward_fields(&record)),
        json!({"machine_id": "vm-1", "port": 3000, "local_port": 52011, "url": "http://127.0.0.1:52011/", "state": "open"})
    );
    let names = PortNames { name: "dev box".into(), id: "vm-1".into(), port: Some(3000) };
    assert_eq!(forward(&record, &names).unwrap().text.as_deref(), Some("http://127.0.0.1:52011/"));
    assert_eq!(
        forward(&json!({"port": 3000}), &names).unwrap_err(),
        Said::with("portFailed", ["dev box", "vm-1", "3000", "no local port"])
    );
    let listed =
        found(json!({"kind": "portList", "machineId": "vm-1", "forwards": [record, {"port": 9}]}));
    assert_eq!(listed.text.as_deref(), Some("3000 -> http://127.0.0.1:52011/"));
    assert_eq!(listed.fields["forwards"].as_array().unwrap().len(), 2);
    assert_eq!(found(json!({"kind": "portList", "machineId": "vm-1", "forwards": []})).text, None);
}

#[test]
fn a_machine_link_without_a_port_is_its_address() {
    let names = PortNames { name: "dev box".into(), id: "vm-1".into(), port: None };
    let bare = machine_link(&names, Some("10.0.0.7"), false, None).unwrap();
    assert_eq!(bare.text.as_deref(), Some("10.0.0.7"));
    assert_eq!(bare.fields["address"], json!("10.0.0.7"));
    assert_eq!(
        machine_link(&names, None, false, None).unwrap().text.as_deref(),
        Some("machine:vm-1")
    );
}

#[test]
fn a_machine_link_with_a_port_is_its_share_link_or_no_link() {
    let names = PortNames { name: "dev box".into(), id: "vm-1".into(), port: Some(3000) };
    let no_link = Said::with("portNoLink", ["dev box", "vm-1", "3000"]);
    let link =
        ShareLink { url: "https://share.cmux.dev/l/1".into(), link_id: "l1".into(), expires_at: 9 };
    // A provider that opens no port links, before and after a link was made.
    assert_eq!(machine_link_port(&names, false), Err(no_link.clone()));
    assert_eq!(machine_link(&names, Some("10.0.0.7"), false, Some(&link)), Err(no_link.clone()));
    assert_eq!(machine_link_port(&names, true), Ok(()));
    // No link to give is refused, never an empty answer.
    assert_eq!(machine_link(&names, Some("10.0.0.7"), true, None), Err(no_link));
    let linked = machine_link(&names, Some("10.0.0.7"), true, Some(&link)).unwrap();
    assert_eq!(linked.text.as_deref(), Some("https://share.cmux.dev/l/1"));
    assert_eq!(
        Value::Object(linked.fields),
        json!({"machine_id": "vm-1", "target": "machine:vm-1", "port": 3000, "private_url": "http://10.0.0.7:3000",
               "url": "https://share.cmux.dev/l/1", "linkId": "l1", "expiresAt": 9})
    );
}

#[test]
fn only_a_plain_https_share_link_is_handed_out() {
    assert!(share_link_ok("https://share.cmux.dev/l/abc?t=1"));
    assert!(share_link_ok("HTTPS://share.cmux.dev"));
    for bad in [
        "http://share.cmux.dev/l",
        "https://user:pw@share.cmux.dev/",
        "https://u@x/",
        "https:///x",
        "share.cmux.dev",
        "https://a b/",
        "https://[::1",
        "https://[::1]x/",
        "https://[zz]/",
        "https://host:80a/",
        "https://host:/x",
        "https://[::1]:/x",
        "https://ho^st/",
        "https://share.cmux.dev/%zz",
        "https://share.cmux.dev/<x>",
    ] {
        assert!(!share_link_ok(bad), "{bad}");
    }
    assert!(share_link_ok("https://share.cmux.dev/a@b"), "an @ in the path is not a user");
    assert!(share_link_ok("https://[::1]:8443/l"));
    assert!(share_link_ok("https://share.cmux.dev:443/l%20x"));
}

#[test]
fn the_tools_probe_is_the_old_cli_s() {
    assert!(
        TOOLS_PROBE
            .starts_with("printf 'shell: '; printf '%s\\n' \"$SHELL\"; for tool in zsh git gh")
    );
    assert!(TOOLS_PROBE.ends_with("; gh --version 2>/dev/null | head -n 1 || true"));
}
