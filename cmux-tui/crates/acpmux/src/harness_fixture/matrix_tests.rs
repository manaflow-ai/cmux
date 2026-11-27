use super::*;

fn auths(cell: &str) -> Vec<(&'static str, Auth)> {
    fixture(cell).unwrap().health.iter().map(|row| (agent_name(&row.id), row.auth)).collect()
}

fn agent_name(id: &str) -> &'static str {
    AGENTS.iter().find(|a| a.id == id).unwrap().name
}

#[test]
fn leos_mac_today_is_two_expired_and_two_signed_in() {
    assert_eq!(
        auths("leo-2026-11-12"),
        [
            ("claude", Auth::Expired),
            ("codex", Auth::Expired),
            ("antigravity", Auth::SignedIn),
            ("opencode", Auth::SignedIn),
        ]
    );
    let fixture = fixture("leo-2026-11-12").unwrap();
    assert_eq!(
        fixture.harnesses.keys().collect::<Vec<_>>(),
        ["antigravity", "claude", "codex", "opencode"]
    );
}

#[test]
fn a_new_mac_has_no_agent() {
    assert_eq!(fixture("none").unwrap(), Fixture::default());
    assert_eq!(fixture("").unwrap(), Fixture::default());
    assert_eq!(fixture("cursor=absent").unwrap(), Fixture::default());
}

#[test]
fn every_named_cell_parses_and_round_trips_as_a_fixture_file() {
    for (name, _) in CELLS {
        let fixture = fixture(name).unwrap_or_else(|e| panic!("{name}: {e}"));
        assert_eq!(fixture.harnesses.len(), fixture.health.len(), "{name}");
        let text = serde_json::json!({"harnesses": fixture.harnesses, "health": fixture.health});
        let back: Fixture = serde_json::from_value(text).unwrap();
        assert_eq!(back, fixture, "{name}");
    }
}

/// Each agent reaches the family its sign-in and login logic keys on, so a
/// cell's harness is the one the real Mac would list.
#[test]
fn each_agent_is_listed_under_its_real_family() {
    let fixture = fixture("all-signed-in").unwrap();
    let families: Vec<String> = AGENTS
        .iter()
        .map(|a| crate::config::derive_family(a.id, &fixture.harnesses[a.id]))
        .collect();
    assert_eq!(
        families,
        ["claude", "codex", "cursor", "grok", "gemini", "antigravity", "opencode"]
    );
}

#[test]
fn every_agent_in_every_state() {
    for agent in AGENTS {
        for (word, auth) in [
            ("signedIn", Auth::SignedIn),
            ("signedOut", Auth::SignedOut),
            ("expired", Auth::Expired),
            ("unknown", Auth::Unknown),
        ] {
            assert_eq!(auths(&format!("{}={word}", agent.name)), [(agent.name, auth)]);
        }
    }
}

/// A start of a cell's harness can never find this host's real CLI on PATH.
#[test]
fn every_program_is_a_path_no_mac_has() {
    let fixture = fixture("all-signed-in").unwrap();
    for (id, profile) in &fixture.harnesses {
        assert!(profile.argv[0].starts_with(FIXTURE_BIN), "{id}: {:?}", profile.argv);
    }
    for row in &fixture.health {
        assert_eq!(row.path.as_deref(), Some(fixture.harnesses[&row.id].argv[0].as_str()));
    }
}

#[test]
fn a_wrong_cell_says_why() {
    assert!(parse("claud=signedIn").unwrap_err().contains("unknown agent `claud`"));
    assert!(parse("claude=loggedIn").unwrap_err().contains("unknown state `loggedIn`"));
    assert!(parse("claude=signedIn,claude=expired").unwrap_err().contains("named twice"));
    assert!(parse("leo").unwrap_err().contains("named cell"));
}
