//! Part of `Hub` (`hub/views.rs`). A live agent host on another build than this daemon's.
//!
//! An update swaps the daemon at once, while every agent host it adopts keeps running the binary
//! it started from. A host moves onto the installed build when its session hibernates: the idle
//! harness and its host stop (`idle.rs`), and the next wake starts a host from the installed
//! binary (`hosts.rs` `start_hosted`). One that never hibernates (a background subagent at work,
//! a dev server under it) stays on the build it started from, and these say so: the summary's
//! `hostBuild` and `hostBuildDiffers` (`acpmux session info`, `acpmux ls`, its WARN cell) and
//! `daemon status`'s `hostsOnOtherBuilds`. Each reads the host record the daemon holds in memory,
//! never a process.
//!
//! A different build, not an older one: a build id names a commit and its date, and a host may run
//! a newer or a local build (a daemon moved back, a dev build), so nothing here says which is
//! newer.

use crate::hub::*;

/// Whether a host on `host_build` runs another build than the daemon's (`daemon`, `build()`).
/// No host (none live, an agent the daemon runs as its own child): false.
pub(crate) fn host_build_differs(host_build: Option<&str>, daemon: &str) -> bool {
    host_build.is_some_and(|host| host != daemon)
}

/// The build `session`'s live agent host runs, from the host record. None without one, and while
/// a start or stop holds the child's slot: a summary never waits on it.
pub(super) fn live_host_build(session: &Session) -> Option<String> {
    session.child.try_lock().ok()?.as_ref()?.host_build()
}

/// `acpmux session info`'s line for a summary whose host is on another build.
pub(crate) fn other_build_host_line(summary: &Value) -> Option<String> {
    if summary.get("hostBuildDiffers").and_then(Value::as_bool) != Some(true) {
        return None;
    }
    let host = summary.get("hostBuild").and_then(Value::as_str).unwrap_or("?");
    Some(format!(
        "host:      build {host}, not the daemon's; it moves onto the daemon's build when the session hibernates"
    ))
}

/// `acpmux daemon status`'s line for its `hostsOnOtherBuilds`, when any is.
pub(crate) fn other_build_hosts_line(status: &Value) -> Option<String> {
    let n = status.get("hostsOnOtherBuilds").and_then(Value::as_u64).filter(|n| *n > 0)?;
    let hosts = if n == 1 { "live host" } else { "live hosts" };
    Some(format!("hosts:    {n} {hosts} on another build than the daemon's"))
}

#[cfg(test)]
mod tests {
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
        assert_eq!(
            other_build_host_line(&json!({"hostBuild": null, "hostBuildDiffers": false})),
            None
        );
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
}
