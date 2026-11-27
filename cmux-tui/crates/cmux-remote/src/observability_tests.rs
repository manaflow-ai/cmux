use super::*;

/// The transport snapshot crosses processes as JSON (`remote_cli` topology, the terminal
/// client), so a daemon and a client one build apart read each other: `outer` is optional both
/// ways.
#[test]
fn outer_path_is_optional_for_old_writers_and_old_readers() {
    // An old writer: no `outer`.
    let old = r#"{"provider":"relay","route":"relay+do://r","selected_path":{"kind":"relay","remote":"r:443","rtt_micros":12}}"#;
    let read: TransportSnapshot = serde_json::from_str(old).unwrap();
    assert_eq!(read.selected_path.as_ref().unwrap().outer, None);
    // A path with no outer path writes no `outer` key, so it is byte for byte what old builds wrote.
    assert!(!serde_json::to_string(&read).unwrap().contains("outer"));

    // A new writer with an outer path, read by a build that has never heard of `outer`.
    #[derive(Deserialize)]
    struct OldPath {
        kind: TransportPathKind,
        remote: Option<String>,
        rtt_micros: Option<u64>,
    }
    #[derive(Deserialize)]
    struct OldSnapshot {
        provider: String,
        selected_path: Option<OldPath>,
    }
    let mut new = read;
    new.selected_path.as_mut().unwrap().outer =
        Some(OuterPathSnapshot { proxy: Some("HTTP proxy p:3128".into()), tls_inspected: true });
    let json = serde_json::to_string(&new).unwrap();
    let old_reader: OldSnapshot = serde_json::from_str(&json).unwrap();
    assert_eq!(old_reader.provider, "relay");
    let path = old_reader.selected_path.unwrap();
    assert_eq!(
        (path.kind, path.remote.as_deref(), path.rtt_micros),
        (TransportPathKind::Relay, Some("r:443"), Some(12))
    );
    assert_eq!(serde_json::from_str::<TransportSnapshot>(&json).unwrap(), new);

    // A later writer may add fields to `outer` or leave `proxy` out.
    let later = r#"{"provider":"relay","route":"","selected_path":{"kind":"relay","outer":{"tls_inspected":true,"via":"pac"}}}"#;
    let outer = serde_json::from_str::<TransportSnapshot>(later)
        .unwrap()
        .selected_path
        .unwrap()
        .outer
        .unwrap();
    assert_eq!(outer, OuterPathSnapshot { proxy: None, tls_inspected: true });
    // And an `outer` with neither field still reads.
    let empty = r#"{"provider":"relay","route":"","selected_path":{"kind":"relay","outer":{}}}"#;
    assert_eq!(
        serde_json::from_str::<TransportSnapshot>(empty).unwrap().selected_path.unwrap().outer,
        Some(OuterPathSnapshot::default())
    );
}
