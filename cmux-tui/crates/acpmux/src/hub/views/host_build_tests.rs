use super::*;

#[test]
fn only_a_host_on_another_build_differs() {
    assert!(host_build_differs(Some("0.9.1 (abc 2026-11-05)"), "0.9.2 (def 2026-11-06)"));
    assert!(!host_build_differs(Some("0.9.2 (def 2026-11-06)"), "0.9.2 (def 2026-11-06)"));
    assert!(!host_build_differs(None, "0.9.2 (def 2026-11-06)"), "no live host");
}

#[test]
fn session_info_names_a_host_on_another_build_and_nothing_else() {
    let old = json!({"hostBuild": "abc", "hostBuildDiffers": true});
    assert_eq!(
        other_build_host_line(&old).as_deref(),
        Some(
            "host:      build abc, not the daemon's; it moves onto the daemon's build when the session hibernates"
        )
    );
    assert_eq!(
        other_build_host_line(&json!({"hostBuild": "def", "hostBuildDiffers": false})),
        None
    );
    assert_eq!(other_build_host_line(&json!({"hostBuild": null, "hostBuildDiffers": false})), None);
    assert_eq!(other_build_host_line(&json!({})), None, "an older daemon says neither");
}

#[test]
fn daemon_status_counts_hosts_on_other_builds_only_when_there_are_some() {
    assert_eq!(other_build_hosts_line(&json!({"hostsOnOtherBuilds": 0})), None);
    assert_eq!(other_build_hosts_line(&json!({})), None, "an older daemon says none");
    assert_eq!(
        other_build_hosts_line(&json!({"hostsOnOtherBuilds": 1})).as_deref(),
        Some("hosts:    1 live host on another build than the daemon's")
    );
    assert_eq!(
        other_build_hosts_line(&json!({"hostsOnOtherBuilds": 3})).as_deref(),
        Some("hosts:    3 live hosts on another build than the daemon's")
    );
}
