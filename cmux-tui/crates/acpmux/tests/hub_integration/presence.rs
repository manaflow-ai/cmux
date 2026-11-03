//! Chat multiplayer presence (hq#4389 §5): who has a chat open and who types in it, kept in the
//! hub's memory only (`hub/presence.rs`). `_acpmux/typing {sessionId, on}` and `_acpmux/view
//! {sessionId, visible}` name their person in `_meta.acpmux.author` (none is the owner); a
//! visible attach is the owner viewing; every attached connection hears
//! `_acpmux/presence {sessionId, participants}` on each change, and `_acpmux/attach` answers it
//! as `presence`. Nothing of it reaches the log.

use super::*;
use acpmux::server::Origin;

const PRESENCE: &str = "_acpmux/presence";

fn person(login: &str) -> Value {
    json!({"id": format!("tailnet:{login}"), "name": login, "login": login, "node": "mac"})
}

fn typing(session: &str, on: bool, author: Option<Value>) -> Value {
    let mut params = json!({"sessionId": session, "on": on});
    if let Some(author) = author {
        params["_meta"] = json!({"acpmux": {"author": author}});
    }
    params
}

/// The participant `id` in a `_acpmux/presence` params or an attach reply's `presence`.
fn entry<'a>(presence: &'a Value, id: &str) -> Option<&'a Value> {
    presence["participants"].as_array()?.iter().find(|p| p["id"] == id)
}

const ANA: &str = "tailnet:ana";

/// A second connection, attached to `session` without showing it.
async fn attached(hub: &Arc<Hub>, session: &str) -> TestClient {
    let mut c = connect(hub).await;
    c.request(method::MUX_ATTACH, json!({"sessionId": session, "limit": 0, "visible": false}))
        .await
        .unwrap();
    c
}

impl TestClient {
    /// The next `_acpmux/presence` for `session` that `pred` accepts.
    async fn presence(&mut self, session: &str, pred: impl Fn(&Value) -> bool) -> Value {
        self.wait_for(PRESENCE, |p| p["sessionId"] == session && pred(p)).await
    }

    async fn typing(
        &mut self,
        session: &str,
        on: bool,
        author: Option<Value>,
    ) -> Result<Value, String> {
        self.request("_acpmux/typing", typing(session, on, author)).await
    }
}

#[tokio::test]
async fn the_attach_reply_carries_presence_and_typing_reaches_attached_clients() {
    let (hub, mut host) = setup(PermissionPolicy::ApproveAll).await;
    let session = new_session(&mut host, "presence").await;
    let mut tab = connect(&hub).await;
    let reply =
        tab.request(method::MUX_ATTACH, json!({"sessionId": session, "limit": 0})).await.unwrap();
    // A visible attach with no author is the owner viewing, from one device.
    let owner = entry(&reply["presence"], "owner").unwrap_or_else(|| panic!("{reply}"));
    assert_eq!((owner["viewing"].clone(), owner["devices"].clone()), (json!(true), json!(1)));

    host.typing(&session, true, Some(person("ana"))).await.unwrap();
    let on = tab.presence(&session, |p| entry(p, ANA).is_some()).await;
    let ana = entry(&on, ANA).unwrap();
    assert_eq!(
        *ana,
        json!({"id": ANA, "name": "ana", "devices": 1, "viewing": false, "typing": true})
    );
    let again =
        tab.request(method::MUX_ATTACH, json!({"sessionId": session, "limit": 0})).await.unwrap();
    assert_eq!(again["presence"], on, "the attach reply is the same object");

    // The owner (no author) is named for the host's user.
    let mut mine = attached(&hub, &session).await;
    mine.typing(&session, true, None).await.unwrap();
    let owner = tab.presence(&session, |p| entry(p, "owner").is_some()).await;
    assert!(entry(&owner, "owner").unwrap()["name"].as_str().is_some_and(|n| !n.is_empty()));
    host.typing(&session, false, Some(person("ana"))).await.unwrap();
    let off = tab.presence(&session, |p| entry(p, ANA).is_none()).await;
    assert!(entry(&off, "owner").is_some(), "{off}");
}

#[tokio::test]
async fn a_typing_on_expires_after_eight_seconds() {
    let (hub, mut host) = setup(PermissionPolicy::ApproveAll).await;
    let session = new_session(&mut host, "expiry").await;
    let mut tab = attached(&hub, &session).await;
    // The paused clock moves only to the next timer: the expiry, when nothing else is due.
    tokio::time::pause();
    let started = tokio::time::Instant::now();
    host.typing(&session, true, Some(person("ana"))).await.unwrap();
    tab.presence(&session, |p| entry(p, ANA).is_some()).await;
    tab.presence(&session, |p| entry(p, ANA).is_none()).await;
    let waited = started.elapsed();
    assert!(waited >= Duration::from_secs(8) && waited < Duration::from_secs(9), "{waited:?}");
}

#[tokio::test]
async fn typing_is_limited_to_two_a_second_per_connection() {
    let (hub, mut host) = setup(PermissionPolicy::ApproveAll).await;
    let session = new_session(&mut host, "rate").await;
    host.typing(&session, true, Some(person("ana"))).await.unwrap();
    host.typing(&session, true, Some(person("bob"))).await.unwrap();
    let refused = host.typing(&session, false, Some(person("ana"))).await.unwrap_err();
    assert!(refused.contains("2 calls a second"), "{refused}");
    // Another connection has its own allowance.
    let mut other = attached(&hub, &session).await;
    other.typing(&session, true, None).await.unwrap();
}

#[tokio::test]
async fn two_authors_share_one_connection_and_one_author_counts_its_devices() {
    let (hub, mut host) = setup(PermissionPolicy::ApproveAll).await;
    let session = new_session(&mut host, "two").await;
    let mut link = attached(&hub, &session).await;
    link.typing(&session, true, Some(person("ana"))).await.unwrap();
    link.typing(&session, true, Some(person("bob"))).await.unwrap();
    let both = host
        .presence(&session, |p| entry(p, ANA).is_some() && entry(p, "tailnet:bob").is_some())
        .await;
    assert_eq!(entry(&both, ANA).unwrap()["devices"], 1, "{both}");
    assert_eq!(entry(&both, "tailnet:bob").unwrap()["devices"], 1, "{both}");
    assert!(entry(&both, "owner").is_none(), "{both}");
    // Ana on a second machine: one person, two devices.
    let mut phone = attached(&hub, &session).await;
    phone.typing(&session, true, Some(person("ana"))).await.unwrap();
    host.presence(&session, |p| entry(p, ANA).is_some_and(|a| a["devices"] == 2)).await;
}

#[tokio::test]
async fn a_closed_connection_takes_its_people_with_it() {
    let (hub, mut host) = setup(PermissionPolicy::ApproveAll).await;
    let session = new_session(&mut host, "close").await;
    let mut link = attached(&hub, &session).await;
    link.typing(&session, true, Some(person("ana"))).await.unwrap();
    link.typing(&session, true, Some(person("bob"))).await.unwrap();
    host.presence(&session, |p| entry(p, "tailnet:bob").is_some()).await;
    drop(link);
    host.presence(&session, |p| p["participants"] == json!([])).await;
    // A detach lets go the same way.
    let mut tab = attached(&hub, &session).await;
    tab.typing(&session, true, Some(person("ana"))).await.unwrap();
    host.presence(&session, |p| entry(p, ANA).is_some()).await;
    tab.request(method::MUX_DETACH, json!({"sessionId": session})).await.unwrap();
    host.presence(&session, |p| entry(p, ANA).is_none()).await;
}

#[tokio::test]
async fn presence_is_never_in_the_log() {
    let (hub, mut host) = setup(PermissionPolicy::ApproveAll).await;
    let session = new_session(&mut host, "log").await;
    host.typing(&session, true, Some(person("ana"))).await.unwrap();
    host.typing(&session, false, Some(person("ana"))).await.unwrap();
    let stored = hub.events(&session, 0, 100_000).unwrap();
    for record in &stored {
        let text = record.msg.to_string();
        assert!(!text.contains("tailnet:ana"), "presence reached the log: {text}");
        assert!(
            !record.kind.contains("presence") && !record.kind.contains("typing"),
            "{}",
            record.kind
        );
    }
}

#[tokio::test]
async fn an_author_from_the_web_is_refused() {
    let (hub, mut host) = setup(PermissionPolicy::ApproveAll).await;
    let session = new_session(&mut host, "web").await;
    for (origin, via) in
        [(Origin::Web, None), (Origin::LocalApp, None), (Origin::Peer, Some("web"))]
    {
        let (in_tx, in_rx) = mpsc::channel(64);
        let (out_tx, out_rx) = mpsc::channel(4096);
        tokio::spawn(acpmux::server::serve_connection_with(hub.clone(), in_rx, out_tx, origin));
        let mut remote = TestClient { tx: in_tx, rx: out_rx, next: 0 };
        let mut params = typing(&session, true, Some(person("ana")));
        if let Some(via) = via {
            params["_meta"]["acpmux"]["via"] = json!(via);
        }
        let refused = remote.request("_acpmux/typing", params).await.unwrap_err();
        assert!(refused.contains("an author is accepted only"), "{origin:?}: {refused}");
    }
}

#[tokio::test]
async fn the_people_in_one_chat_are_bounded() {
    let (hub, mut host) = setup(PermissionPolicy::ApproveAll).await;
    let session = new_session(&mut host, "bound").await;
    // One connection per person, each under its own typing allowance.
    let mut links = Vec::new();
    for n in 0..32 {
        let mut link = attached(&hub, &session).await;
        link.typing(&session, true, Some(person(&format!("p{n}")))).await.unwrap();
        links.push(link);
    }
    let mut late = attached(&hub, &session).await;
    let refused = late.typing(&session, true, Some(person("late"))).await.unwrap_err();
    assert!(refused.contains("already shows 32 people"), "{refused}");
    // Someone already in still changes, and the owner always gets in.
    late.typing(&session, true, Some(person("p0"))).await.unwrap();
    host.typing(&session, true, None).await.unwrap();
}

fn view(session: &str, visible: bool, author: Option<Value>) -> Value {
    let mut params = typing(session, visible, author);
    params.as_object_mut().unwrap().remove("on");
    params["visible"] = json!(visible);
    params
}

#[tokio::test]
async fn viewing_comes_from_view_per_author_and_leaves_unread_to_the_owner() {
    let (hub, mut host) = setup(PermissionPolicy::ApproveAll).await;
    let session = new_session(&mut host, "view").await;
    let mut link = attached(&hub, &session).await;
    for who in ["ana", "bob"] {
        link.request(method::MUX_VIEW, view(&session, true, Some(person(who)))).await.unwrap();
    }
    let both = host
        .presence(&session, |p| entry(p, ANA).is_some() && entry(p, "tailnet:bob").is_some())
        .await;
    assert_eq!(entry(&both, ANA).unwrap()["viewing"], true, "{both}");
    assert!(entry(&both, "owner").is_none(), "a hidden attach is nobody viewing: {both}");
    // An authored view is presence only: the link still does not show the chat.
    let shown = hub.session_summary(&hub.resolve(&session).unwrap())["shown"].clone();
    let mut alone = connect(&hub).await;
    alone
        .request(method::MUX_ATTACH, json!({"sessionId": session, "limit": 0, "visible": false}))
        .await
        .unwrap();
    assert_eq!(hub.session_summary(&hub.resolve(&session).unwrap())["shown"], shown);
    // Bob hiding leaves Ana viewing on the same connection; Ana on a second machine counts twice.
    link.request(method::MUX_VIEW, view(&session, false, Some(person("bob")))).await.unwrap();
    let ana_only = host.presence(&session, |p| entry(p, "tailnet:bob").is_none()).await;
    assert_eq!(entry(&ana_only, ANA).unwrap()["viewing"], true);
    alone.request(method::MUX_VIEW, view(&session, true, Some(person("ana")))).await.unwrap();
    host.presence(&session, |p| entry(p, ANA).is_some_and(|a| a["devices"] == 2)).await;
    drop(link);
    drop(alone);
    host.presence(&session, |p| entry(p, ANA).is_none()).await;
    // A view still needs the attachment.
    let mut stranger = connect(&hub).await;
    assert!(
        stranger
            .request(method::MUX_VIEW, view(&session, true, Some(person("ana"))))
            .await
            .is_err()
    );
}
