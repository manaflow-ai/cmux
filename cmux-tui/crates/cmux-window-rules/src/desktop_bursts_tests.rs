use super::*;

fn finished(notification: u64, tab: &str) -> Arrival {
    Arrival { notification, finished_turn: true, reply: false, tab: tab.into() }
}

/// Joins `arrivals` into one workspace's burst in turn; the digests they made.
fn run(burst: &mut Option<Burst>, arrivals: &[Arrival]) -> Vec<Option<Digest>> {
    arrivals
        .iter()
        .map(|arrival| {
            let joined = join(burst.clone(), arrival);
            if joined.burst.is_some() {
                *burst = joined.burst;
            }
            joined.digest
        })
        .collect()
}

fn ids(burst: &Option<Burst>) -> Vec<String> {
    burst.iter().flat_map(|burst| burst.showing.iter().map(|shown| shown.id.clone())).collect()
}

/// Agents finishing in one workspace share one banner: each other agent's
/// finish replaces every banner still showing, and the count grows.
#[test]
fn agents_finishing_in_one_workspace_share_one_banner() {
    let mut burst = None;
    let digests =
        run(&mut burst, &[finished(5, "claude"), finished(7, "codex"), finished(8, "claude-2")]);
    assert_eq!(digests[0], None, "the first finish posts on its own");
    assert_eq!(
        digests[1],
        Some(Digest { count: 2, replacing: vec!["cmux-notification-5".into()] }),
        "a second agent's finish replaces the first banner"
    );
    assert_eq!(
        digests[2],
        Some(Digest { count: 3, replacing: vec!["cmux-notification-7".into()] })
    );
    assert_eq!(
        ids(&burst),
        ["cmux-notification-8"],
        "the digest is filed under the newest agent's tab"
    );
    assert_eq!(burst.map(|burst| burst.showing[0].tab.clone()).as_deref(), Some("claude-2"));
}

/// An approval (a warning), an error or a reply banner never joins, and
/// leaves the burst as it was.
#[test]
fn asks_and_reply_banners_never_join() {
    let mut burst = None;
    run(&mut burst, &[finished(5, "claude")]);
    let kept = burst.clone();
    let ask = Arrival { finished_turn: false, ..finished(6, "codex") };
    assert_eq!(join(burst.clone(), &ask), Joined { burst: None, digest: None });
    let reply = Arrival { reply: true, ..finished(6, "codex") };
    assert_eq!(join(burst.clone(), &reply), Joined { burst: None, digest: None });
    assert_eq!(join(None, &ask), Joined { burst: None, digest: None }, "nor opens a burst");
    assert_eq!(burst, kept);
}

/// One agent finishing twice is not a burst: both banners show.
#[test]
fn one_agent_finishing_twice_is_not_a_burst() {
    let mut burst = None;
    assert_eq!(run(&mut burst, &[finished(5, "claude"), finished(6, "claude")]), [None, None]);
    assert_eq!(ids(&burst), ["cmux-notification-5", "cmux-notification-6"]);
    assert_eq!(burst.map(|burst| burst.tabs), Some(vec!["claude".to_owned()]));
}

/// An agent finishing twice and then another: both of the first agent's
/// banners give way to the digest.
#[test]
fn an_agent_finishing_twice_then_another_leaves_only_the_digest() {
    let mut burst = None;
    let digests =
        run(&mut burst, &[finished(5, "claude"), finished(6, "claude"), finished(7, "codex")]);
    assert_eq!(
        digests[2],
        Some(Digest {
            count: 2,
            replacing: vec!["cmux-notification-5".into(), "cmux-notification-6".into()]
        })
    );
    assert_eq!(ids(&burst), ["cmux-notification-7"]);
}

/// An agent the person already read leaves the burst: the next finish is
/// not counted with it and replaces nothing.
#[test]
fn an_agent_the_user_already_read_leaves_the_burst() {
    let mut burst = None;
    run(&mut burst, &[finished(5, "claude"), finished(6, "other")]);
    let left = read(burst.clone().unwrap_or_default(), "claude");
    assert!(!left.closes, "another agent is still unread in it");
    assert_eq!(left.burst.tabs, ["other"]);
    let alone = read(Burst { tabs: vec!["claude".into()], showing: vec![] }, "claude");
    assert!(alone.closes, "a burst left empty closes");
    // The burst that closed: the next finish opens a new one and posts on its own.
    let mut reopened = None;
    run(&mut reopened, &[finished(5, "claude")]);
    let read_first = read(reopened.clone().unwrap_or_default(), "claude");
    assert!(read_first.closes);
    let mut after = None;
    assert_eq!(run(&mut after, &[finished(6, "codex")]), [None], "a banner that replaces nothing");
}

/// Reading a tab takes its banners out of the burst's showing ones, so a
/// later digest does not withdraw them again.
#[test]
fn a_read_tab_takes_its_banners_with_it() {
    let burst = Burst {
        tabs: vec!["a".into(), "b".into()],
        showing: vec![
            Showing { id: "cmux-notification-1".into(), tab: "a".into() },
            Showing { id: "cmux-notification-2".into(), tab: "b".into() },
        ],
    };
    let left = read(burst, "a");
    assert_eq!(left.burst.showing, [Showing { id: "cmux-notification-2".into(), tab: "b".into() }]);
    let joined = join(Some(left.burst), &finished(3, "c"));
    assert_eq!(
        joined.digest,
        Some(Digest { count: 2, replacing: vec!["cmux-notification-2".into()] })
    );
}

/// Reading a tab the burst does not hold changes nothing.
#[test]
fn reading_another_tab_changes_nothing() {
    let burst = Burst {
        tabs: vec!["a".into()],
        showing: vec![Showing { id: "cmux-notification-1".into(), tab: "a".into() }],
    };
    assert_eq!(read(burst.clone(), "z"), Read { burst, closes: false });
}
