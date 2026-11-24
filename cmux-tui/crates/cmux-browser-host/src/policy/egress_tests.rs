use super::*;
use crate::policy::{Layer, Writer, parse_patterns};

fn url(text: &str) -> Url {
    Url::parse(text).unwrap()
}

#[test]
fn link_local_and_metadata_are_refused_everywhere() {
    let policy = Policy::default();
    for text in [
        "http://169.254.169.254/latest/meta-data/",
        "http://[fe80::1]/",
        "http://metadata.google.internal/computeMetadata/v1/",
        "http://[::ffff:169.254.169.254]/",
        "http://[fd00:ec2::254]/latest/meta-data/",
        "http://100.100.100.200/latest/meta-data/",
        "http://168.63.129.16/machine",
        "http://METADATA.google.internal./",
        "http://metadata.goog/",
        "http://instance-data.ec2.internal/",
        // IPv6 forms that carry 169.254.169.254.
        "http://[::a9fe:a9fe]/",
        "http://[64:ff9b::a9fe:a9fe]/",
        "http://[2002:a9fe:a9fe::1]/",
    ] {
        assert!(policy.egress_refusal(&url(text), false).is_some(), "{text}");
    }
}

#[test]
fn every_address_class_has_its_range() {
    let range = |text: &str| ip_range(text.parse().unwrap());
    for text in
        ["169.254.169.254", "169.254.0.1", "fe80::1", "fd00:ec2::254", "::ffff:169.254.169.254"]
    {
        assert_eq!(range(text), Some(Range::LinkLocal), "{text}");
    }
    for text in [
        "127.0.0.1",
        "127.255.255.254",
        "10.0.0.1",
        "172.16.0.1",
        "172.31.255.255",
        "192.168.0.1",
        "100.64.0.1",
        "100.127.255.255",
        "0.0.0.0",
        "192.0.0.8",
        "198.18.0.1",
        "224.0.0.1",
        "255.255.255.255",
        "::",
        "::1",
        "fc00::1",
        "fd12:3456::1",
        "fec0::1",
        "ff02::1",
        "::ffff:10.0.0.1",
        "::ffff:127.0.0.1",
        "::ffff:100.64.0.1",
        "::10.0.0.1",
        "64:ff9b::7f00:1",
        "64:ff9b:1::1",
        "2002:c0a8:0101::1",
        "100::1",
    ] {
        assert_eq!(range(text), Some(Range::Private), "{text}");
    }
    for text in [
        "8.8.8.8",
        "172.32.0.1",
        "100.128.0.1",
        "198.20.0.1",
        "2606:4700::1111",
        "::ffff:8.8.8.8",
        "64:ff9b::808:808",
        "2002:0808:0808::1",
    ] {
        assert_eq!(range(text), None, "{text}");
    }
}

#[test]
fn private_ranges_are_refused_only_for_remote_sessions() {
    let policy = Policy::default();
    for text in [
        "http://127.0.0.1:8080/",
        "http://10.1.2.3/",
        "http://172.20.0.1/",
        "http://192.168.1.1/",
        "http://100.89.225.106/",
        "http://[::1]/",
        "http://[fd00::1]/",
        "http://localhost:3000/",
        "http://app.localhost/",
    ] {
        assert!(policy.egress_refusal(&url(text), false).is_none(), "local: {text}");
        assert!(policy.egress_refusal(&url(text), true).is_some(), "remote: {text}");
    }
    for text in ["https://example.com/", "http://172.32.0.1/", "http://8.8.8.8/"] {
        assert!(policy.egress_refusal(&url(text), true).is_none(), "{text}");
    }
}

#[test]
fn only_the_owner_policy_allows_a_refused_host() {
    let mut policy = Policy::default();
    let layer = Layer {
        allowed: Some(parse_patterns(&["http://169.254.169.254".to_owned()]).unwrap()),
        ..Layer::default()
    };
    policy.set(Writer::Owner, layer.clone(), false).unwrap();
    assert!(policy.egress_refusal(&url("http://169.254.169.254/x"), true).is_none());
    let mut agent = Policy::default();
    agent.set(Writer::Agent, layer, false).unwrap();
    assert!(agent.egress_refusal(&url("http://169.254.169.254/x"), false).is_some());
}
