//! The control socket's sessions: the qualifier name that prefixes a remote
//! session's object ids (`build-box`, `build-box-ci`), the session's
//! transport and connection state words. Runs in every control snapshot
//! publish (per tab switch), so the app asks once for all its daemons.

use serde::{Deserialize, Serialize};

/// A host name's first DNS label (`cmux-dev-backend-1` for
/// `cmux-dev-backend-1.us-central1-b.c.example.internal`); an IP address or
/// an SSH label (`host/session`) stays whole.
pub fn short_host(name: &str) -> &str {
    if name.contains('/') || name.bytes().all(|b| b.is_ascii_digit() || b == b'.' || b == b':') {
        return name;
    }
    name.split('.').find(|label| !label.is_empty()).unwrap_or(name)
}

/// `build-box`, or `build-box-ci` for session `ci` on it: the machine name
/// plus the session name when that is not one of `defaults`.
pub fn qualifier_name(
    machine: Option<&str>,
    session: Option<&str>,
    defaults: &[String],
) -> Option<String> {
    let machine = machine.map(short_host);
    let Some(session) = session
        .filter(|session| !session.is_empty() && !defaults.iter().any(|name| name == session))
    else {
        return machine.or(session).map(str::to_owned);
    };
    let Some(machine) = machine else { return Some(session.to_owned()) };
    // An SSH label already names its session (`host/session`).
    if machine.ends_with(&format!("/{session}")) {
        return Some(machine.to_owned());
    }
    Some(format!("{machine}-{session}"))
}

/// One daemon, as the app read it.
#[derive(Debug, Clone, Default, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Candidate {
    #[serde(default)]
    pub machine: Option<String>,
    /// The session label (the home session's build label already applied).
    #[serde(default)]
    pub session: Option<String>,
    #[serde(default)]
    pub is_local: bool,
    #[serde(default)]
    pub ssh: bool,
    #[serde(default)]
    pub server: bool,
}

/// What the control snapshot shows for one daemon.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Named {
    pub qualifier_name: Option<String>,
    pub transport: &'static str,
}

/// How the app reaches a daemon: this Mac, SSH, a server, else Cloud.
pub fn transport(candidate: &Candidate) -> &'static str {
    if candidate.is_local {
        "local"
    } else if candidate.ssh {
        "ssh"
    } else if candidate.server {
        "server"
    } else {
        "cloud"
    }
}

/// Every daemon's qualifier name and transport, in order.
pub fn name_all(candidates: &[Candidate], defaults: &[String]) -> Vec<Named> {
    candidates
        .iter()
        .map(|candidate| Named {
            qualifier_name: qualifier_name(
                candidate.machine.as_deref(),
                candidate.session.as_deref(),
                defaults,
            ),
            transport: transport(candidate),
        })
        .collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    fn defaults() -> Vec<String> {
        vec!["default".into(), "cmux-app".into(), "cmux-nightly".into()]
    }

    #[test]
    fn short_hosts() {
        assert_eq!(
            short_host("cmux-dev-backend-1.us-central1-b.c.example.internal"),
            "cmux-dev-backend-1"
        );
        assert_eq!(short_host("build-box"), "build-box");
        assert_eq!(short_host("10.0.0.2"), "10.0.0.2");
        assert_eq!(short_host("fe80::1"), "fe80::1");
        assert_eq!(short_host("host/session"), "host/session");
        assert_eq!(short_host("a.b/c"), "a.b/c");
        assert_eq!(short_host(""), "");
        // Swift's split drops empty labels.
        assert_eq!(short_host(".hidden.example"), "hidden");
        assert_eq!(short_host("..."), "...");
    }

    #[test]
    fn a_default_session_adds_nothing() {
        let defaults = defaults();
        assert_eq!(
            qualifier_name(Some("build-box.lan"), Some("default"), &defaults),
            Some("build-box".into())
        );
        assert_eq!(
            qualifier_name(Some("build-box"), Some("cmux-app"), &defaults),
            Some("build-box".into())
        );
        assert_eq!(
            qualifier_name(Some("build-box"), Some(""), &defaults),
            Some("build-box".into())
        );
        assert_eq!(qualifier_name(Some("build-box"), None, &defaults), Some("build-box".into()));
        assert_eq!(qualifier_name(None, Some("default"), &defaults), Some("default".into()));
        assert_eq!(qualifier_name(None, Some(""), &defaults), Some(String::new()));
        assert_eq!(qualifier_name(None, None, &defaults), None);
    }

    #[test]
    fn another_session_joins_the_machine() {
        let defaults = defaults();
        assert_eq!(
            qualifier_name(Some("build-box.lan"), Some("ci"), &defaults),
            Some("build-box-ci".into())
        );
        assert_eq!(qualifier_name(None, Some("ci"), &defaults), Some("ci".into()));
        assert_eq!(qualifier_name(Some("host/ci"), Some("ci"), &defaults), Some("host/ci".into()));
        assert_eq!(qualifier_name(Some("hostci"), Some("ci"), &defaults), Some("hostci-ci".into()));
        assert_eq!(qualifier_name(Some("/ci"), Some("ci"), &defaults), Some("/ci".into()));
    }

    #[test]
    fn transports() {
        let local = Candidate { is_local: true, ssh: true, ..Candidate::default() };
        assert_eq!(transport(&local), "local");
        assert_eq!(
            transport(&Candidate { ssh: true, server: true, ..Candidate::default() }),
            "ssh"
        );
        assert_eq!(transport(&Candidate { server: true, ..Candidate::default() }), "server");
        assert_eq!(transport(&Candidate::default()), "cloud");
    }

    #[test]
    fn name_all_keeps_order() {
        let candidates = vec![
            Candidate {
                machine: Some("mac.local".into()),
                session: Some("cmux-app".into()),
                is_local: true,
                ..Candidate::default()
            },
            Candidate {
                machine: Some("box".into()),
                session: Some("ci".into()),
                ssh: true,
                ..Candidate::default()
            },
        ];
        assert_eq!(
            name_all(&candidates, &defaults()),
            vec![
                Named { qualifier_name: Some("mac".into()), transport: "local" },
                Named { qualifier_name: Some("box-ci".into()), transport: "ssh" },
            ]
        );
    }
}
