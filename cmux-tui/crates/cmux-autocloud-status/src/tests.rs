use super::*;
use serde::Deserialize;

/// The states the design draws, with what each must say (the gallery draws from the same file).
const FIXTURES: &str =
    include_str!("../../../../webviews/src/sidebar/autocloudStatus.fixtures.json");

#[derive(Deserialize)]
struct Fixture {
    id: String,
    status: AutoCloudStatus,
    expect: Expect,
}

#[derive(Deserialize)]
struct Expect {
    headline: Headline,
    tone: Tone,
    pending: u32,
    people: usize,
    agents: usize,
}

fn here(name: &str, kind: HereKind) -> Here {
    Here { name: name.into(), kind, at: HereAt::Mac }
}

#[test]
fn fixtures_say_what_the_rust_says() {
    let fixtures: Vec<Fixture> = serde_json::from_str(FIXTURES).expect("fixtures parse");
    assert!(fixtures.len() >= 8, "the design's states are all there");
    for f in fixtures {
        let s = &f.status;
        assert_eq!(s.headline(), f.expect.headline, "{} headline", f.id);
        assert_eq!(s.tone(), f.expect.tone, "{} tone", f.id);
        assert_eq!(s.pending(), f.expect.pending, "{} pending", f.id);
        assert_eq!(s.people_here(), f.expect.people, "{} people", f.id);
        assert_eq!(s.agents_here(), f.expect.agents, "{} agents", f.id);
    }
}

#[test]
fn off_hides_sync() {
    let s = AutoCloudStatus { cloud: Cloud::Off, sync: Sync::Offline { pending: 4 }, here: vec![] };
    assert_eq!(s.headline(), Headline::Off);
    assert_eq!(s.tone(), Tone::Quiet);
    assert_eq!(s.pending(), 0);
}

#[test]
fn offline_beats_syncing_beats_warming() {
    let mut s = AutoCloudStatus { cloud: Cloud::Warming, sync: Sync::Synced, here: vec![] };
    assert_eq!(s.headline(), Headline::Warming);
    s.sync = Sync::Syncing { changes: 2 };
    assert_eq!(s.headline(), Headline::Syncing);
    s.sync = Sync::Offline { pending: 2 };
    assert_eq!(s.headline(), Headline::Offline);
    assert_eq!(s.tone(), Tone::Attention);
}

#[test]
fn syncing_nothing_is_synced() {
    let s =
        AutoCloudStatus { cloud: Cloud::Ready, sync: Sync::Syncing { changes: 0 }, here: vec![] };
    assert_eq!(s.headline(), Headline::Ready);
}

#[test]
fn avatars_put_people_first_and_count_the_rest() {
    let s = AutoCloudStatus {
        cloud: Cloud::Active,
        sync: Sync::Synced,
        here: vec![
            here("claude", HereKind::Agent),
            here("Lawrence", HereKind::Person),
            here("codex", HereKind::Agent),
            here("Austin", HereKind::Person),
        ],
    };
    let (shown, rest) = s.avatars(3);
    let names: Vec<&str> = shown.iter().map(|h| h.name.as_str()).collect();
    assert_eq!(names, ["Lawrence", "Austin", "claude"]);
    assert_eq!(rest, 1);
    assert!(s.someone_here());
}
