//! Prompt coach (`hub/prompt_coach.rs`): a person's chat that took three corrections before the
//! person moved on logs one `coach_offer`, and the view's `_acpmux/prompt_coach` makes one `coach`
//! rewrite from the first prompt and the corrections only. A chat that went fine logs neither.

use super::*;

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
