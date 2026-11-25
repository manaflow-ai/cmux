//! Prompt coach (`hub/prompt_coach.rs`): a person's chat that took three corrections before the
//! person moved on logs one `coach_offer`, and the view's `_acpmux/prompt_coach` makes one `coach`
//! rewrite from the first prompt and the corrections only. A chat that went fine logs neither.

use super::*;
use acpmux::server::{Origin, serve_connection_with};

/// The `mux` records of `kind` in chat `id`, waiting up to 5 s for `want` of them.
async fn records(hub: &Arc<Hub>, id: &str, kind: &str, want: usize) -> Vec<Value> {
    let read = || -> Vec<Value> {
        hub.events(id, 0, 10_000)
            .unwrap()
            .into_iter()
            .filter(|e| e.dir == "mux" && e.kind == kind)
            .map(|e| e.msg)
            .collect()
    };
    for _ in 0..250 {
        if read().len() >= want {
            break;
        }
        tokio::time::sleep(Duration::from_millis(20)).await;
    }
    read()
}

async fn say(c: &mut TestClient, id: &str, text: &str) {
    c.request(
        method::SESSION_PROMPT,
        json!({"sessionId": id, "prompt": [{"type": "text", "text": text}]}),
    )
    .await
    .unwrap();
}

#[tokio::test]
async fn a_chat_kept_after_three_corrections_is_offered_one_rewrite() {
    let (hub, mut c) = setup(PermissionPolicy::ApproveAll).await;
    let asked: Arc<std::sync::Mutex<Vec<String>>> = Arc::default();
    let seen = asked.clone();
    hub.set_coach_rewriter(Some(Arc::new(move |prompt: String| {
        seen.lock().unwrap().push(prompt);
        Some("Add a dark mode toggle under Appearance in src/settings/Appearance.tsx.".into())
    })));
    let id = new_session(&mut c, "coach").await;
    for text in [
        "add a dark mode toggle",
        "no, it goes under Appearance in src/settings/Appearance.tsx",
        "actually it should follow the system theme by default",
        "that's not what I meant, keep ThemeContext",
    ] {
        say(&mut c, &id, text).await;
    }
    assert!(records(&hub, &id, "coach_offer", 1).await.is_empty(), "still correcting: no offer");
    say(&mut c, &id, "great, now add a test").await;
    let offers = records(&hub, &id, "coach_offer", 1).await;
    assert_eq!(offers.len(), 1, "{offers:?}");
    assert_eq!(offers[0]["corrections"], 3);
    let coach_id = offers[0]["coachId"].as_str().unwrap().to_owned();
    assert!(asked.lock().unwrap().is_empty(), "no model call before a view asks");

    let made = c
        .request(method::MUX_PROMPT_COACH, json!({"sessionId": id, "coachId": coach_id}))
        .await
        .unwrap();
    assert_eq!(made["made"], true);
    let again = c
        .request(method::MUX_PROMPT_COACH, json!({"sessionId": id, "coachId": coach_id}))
        .await
        .unwrap();
    assert_eq!(again["made"], false, "made once");
    let coach = records(&hub, &id, "coach", 1).await;
    assert_eq!(coach.len(), 1, "{coach:?}");
    assert_eq!(coach[0]["firstPrompt"], "add a dark mode toggle");
    assert_eq!(coach[0]["corrections"], 3);
    assert!(coach[0]["rewrite"].as_str().unwrap().starts_with("Add a dark mode toggle"));
    let asked = asked.lock().unwrap().clone();
    assert_eq!(asked.len(), 1);
    assert!(asked[0].contains("keep ThemeContext"), "the corrections are read");
    assert!(!asked[0].contains("great, now add a test"), "the kept turn's prompt is not");

    // A chat client's transcript page carries both records (`paging.rs` `TRANSCRIPT_MUX_KINDS`).
    let page = c
        .request(
            method::MUX_EVENTS,
            json!({"sessionId": id, "afterSeq": 0, "limit": 5000, "kinds": ["transcript"]}),
        )
        .await
        .unwrap();
    let kinds: Vec<&str> =
        page["events"].as_array().unwrap().iter().filter_map(|e| e["kind"].as_str()).collect();
    assert!(kinds.contains(&"coach_offer") && kinds.contains(&"coach"), "{kinds:?}");

    // More corrections later never make a second offer.
    for text in ["no, the other file", "still wrong", "actually revert it", "fine, thanks"] {
        say(&mut c, &id, text).await;
    }
    assert_eq!(records(&hub, &id, "coach_offer", 2).await.len(), 1);
}

#[tokio::test]
async fn a_chat_that_went_fine_is_offered_nothing() {
    let (hub, mut c) = setup(PermissionPolicy::ApproveAll).await;
    let id = new_session(&mut c, "fine").await;
    for text in ["add a lint script", "now run it", "great, add it to CI", "thanks! commit it"] {
        say(&mut c, &id, text).await;
    }
    assert!(records(&hub, &id, "coach_offer", 1).await.is_empty());
    let none = c
        .request(method::MUX_PROMPT_COACH, json!({"sessionId": id, "coachId": "made-up"}))
        .await
        .unwrap();
    assert_eq!(none["made"], false);
    assert!(records(&hub, &id, "coach", 0).await.is_empty());
}

#[tokio::test]
async fn an_offer_logged_before_a_restart_still_gets_its_rewrite() {
    let (hub, mut c) = setup(PermissionPolicy::ApproveAll).await;
    let asked: Arc<std::sync::Mutex<Vec<String>>> = Arc::default();
    let seen = asked.clone();
    hub.set_coach_rewriter(Some(Arc::new(move |prompt: String| {
        seen.lock().unwrap().push(prompt);
        Some("Rename the type to Account; keep the users table and API fields.".into())
    })));
    let id = new_session(&mut c, "restart").await;
    for text in [
        "rename User to Account",
        "no, keep the table name users",
        "actually leave the API fields alone",
        "still wrong, the migration renames the table",
        "perfect, open a PR",
    ] {
        say(&mut c, &id, text).await;
    }
    let offers = records(&hub, &id, "coach_offer", 1).await;
    assert_eq!(offers.len(), 1, "{offers:?}");
    let coach_id = offers[0]["coachId"].as_str().unwrap().to_owned();
    // The daemon restarts: what it counted is gone, the offer is in the log.
    hub.forget_coach(&id);
    let made = c
        .request(method::MUX_PROMPT_COACH, json!({"sessionId": id, "coachId": coach_id}))
        .await
        .unwrap();
    assert_eq!(made["made"], true);
    let asked = asked.lock().unwrap().clone();
    assert_eq!(asked.len(), 1);
    assert!(asked[0].contains("<first_message>\nrename User to Account"), "{}", asked[0]);
    assert!(
        asked[0].contains("the migration renames the table"),
        "corrections rebuilt from the log"
    );
    assert!(!asked[0].contains("open a PR"));
    let coach = records(&hub, &id, "coach", 1).await;
    assert_eq!(coach.len(), 1);
    assert_eq!(coach[0]["corrections"], 3);
    // Made once: asked again after another restart, nothing more is made.
    hub.forget_coach(&id);
    let again = c
        .request(method::MUX_PROMPT_COACH, json!({"sessionId": id, "coachId": coach_id}))
        .await
        .unwrap();
    assert_eq!(again["made"], false);
}

/// The owner's plain terminal: a unix connection that claims no sender and never proved the person
/// (`requests.rs` `owner_terminal`). Its prompt is drawn as theirs, but it proves nobody.
async fn terminal(hub: &Arc<Hub>) -> TestClient {
    let (in_tx, in_rx) = mpsc::channel(64);
    let (out_tx, out_rx) = mpsc::channel(4096);
    tokio::spawn(serve_connection_with(hub.clone(), in_rx, out_tx, Origin::Local));
    let mut client = TestClient { tx: in_tx, rx: out_rx, next: 0 };
    client
        .request(method::INITIALIZE, json!({"protocolVersion": 1, "clientInfo": {"name": "shell"}}))
        .await
        .unwrap();
    client
}

/// Corrections count only from a connection that proved the person (cmux#38893 review,
/// `requests.rs:2092`): a send no proof attributes, the owner's terminal included, could be any
/// process of the user, so three of them and the person's go-ahead make no offer.
#[tokio::test]
async fn corrections_no_connection_proved_make_no_offer() {
    let (hub, mut c) = setup(PermissionPolicy::ApproveAll).await;
    let id = new_session(&mut c, "unproven").await;
    say(&mut c, &id, "add a dark mode toggle").await;
    let mut shell = terminal(&hub).await;
    for text in [
        "no, it goes under Appearance",
        "actually it should follow the system theme",
        "that's not what I meant, keep ThemeContext",
    ] {
        say(&mut shell, &id, text).await;
    }
    say(&mut c, &id, "great, now add a test").await;
    assert!(records(&hub, &id, "coach_offer", 1).await.is_empty(), "no proven correction");
}

/// After a restart, a chat that qualifies again finds the offer an earlier run logged and logs no
/// second one: it then holds that logged offer, never an id no record has (cmux#38893 review,
/// `hub/prompt_coach.rs:575`), and the logged offer still gets its rewrite.
#[tokio::test]
async fn a_chat_that_qualifies_again_after_a_restart_holds_the_logged_offer() {
    let (hub, mut c) = setup(PermissionPolicy::ApproveAll).await;
    let asked: Arc<std::sync::Mutex<Vec<String>>> = Arc::default();
    let seen = asked.clone();
    hub.set_coach_rewriter(Some(Arc::new(move |prompt: String| {
        seen.lock().unwrap().push(prompt);
        Some("Rename the type to Account.".into())
    })));
    let id = new_session(&mut c, "again").await;
    let run = [
        "rename User to Account",
        "no, keep the table name users",
        "actually leave the API fields alone",
        "still wrong, the migration renames the table",
        "perfect, open a PR",
    ];
    for text in run {
        say(&mut c, &id, text).await;
    }
    let offers = records(&hub, &id, "coach_offer", 1).await;
    assert_eq!(offers.len(), 1, "{offers:?}");
    let logged = offers[0]["coachId"].as_str().unwrap().to_owned();
    hub.forget_coach(&id);
    for text in ["no, the other file", "still wrong", "actually revert it", "fine, thanks"] {
        say(&mut c, &id, text).await;
    }
    assert_eq!(records(&hub, &id, "coach_offer", 2).await.len(), 1, "one offer per chat");
    assert_eq!(hub.coach_offered(&id).as_deref(), Some(logged.as_str()));
    let made = c
        .request(method::MUX_PROMPT_COACH, json!({"sessionId": id, "coachId": logged}))
        .await
        .unwrap();
    assert_eq!(made["made"], true);
    // Its rewrite reads the corrections the logged offer counted, not the later ones.
    let asked = asked.lock().unwrap().clone();
    assert_eq!(asked.len(), 1);
    assert!(asked[0].contains("the migration renames the table"), "{}", asked[0]);
    assert!(!asked[0].contains("revert it"), "{}", asked[0]);
    assert_eq!(records(&hub, &id, "coach", 1).await[0]["corrections"], 3);
}
