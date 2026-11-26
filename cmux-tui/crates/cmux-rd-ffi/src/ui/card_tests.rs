//! Parity with `MacScreenCardView`'s cards (`MacScreenQuietCardTests`, `MacScreenFailureReasonTests`).

use serde_json::{Value, json};

use super::*;

fn card(v: Value) -> Card {
    serde_json::from_value(v).unwrap()
}

fn ids(c: &Content) -> Vec<Option<&str>> {
    c.buttons.iter().map(|b| b.id).collect()
}

fn args_for(c: Card) -> ContentArgs {
    ContentArgs { card: c, ..ContentArgs::default() }
}

#[test]
fn connecting_spins_with_cancel() {
    let c = content(&args_for(card(json!({"kind": "connecting"}))));
    assert!(c.spinner);
    assert_eq!(c.title, keyed("macScreen.card.connecting", &["$name"]));
    assert_eq!(c.buttons, vec![cancel("disconnect", None)]);
    let c = content(&args_for(card(json!({"kind": "connecting", "reconnecting": true}))));
    assert_eq!(c.title, key("macScreen.card.reconnecting"));
}

#[test]
fn failed_prints_a_named_reason_unless_quiet() {
    let mut a = args_for(card(json!({"kind": "failed"})));
    assert_eq!(content(&a).line, None);
    a.has_failed_detail = true;
    assert_eq!(content(&a).line, Some(Line { text: token("$failedDetail"), printed: true }));
    assert_eq!(ids(&content(&a)), [None, Some("macScreen.card.retry")]);
    assert!(content(&a).buttons[1].return_key);
    a.quiet = true;
    assert_eq!(content(&a).line, None);
}

#[test]
fn hub_end_falls_back_to_end_text() {
    let a = args_for(card(json!({"kind": "hubEnded", "end": {"canReconnect": true}})));
    let c = content(&a);
    assert_eq!(c.title, key("macScreen.card.endedTitle"));
    assert_eq!(c.line, Some(Line { text: token("$endText"), printed: false }));
    assert_eq!(ids(&c), [None, Some("macScreen.card.reconnect")]);
    let a = args_for(card(
        json!({"kind": "hubRevoked", "end": {"removesAccess": true, "canReconnect": false}}),
    ));
    let c = content(&a);
    assert_eq!(c.title, key("macScreen.hub.revokedTitle"));
    assert_eq!(c.buttons.len(), 1);
    let a = args_for(card(json!({"kind": "hubRevoked", "end": {"canReconnect": true}})));
    assert_eq!(ids(&content(&a)), [None, Some("macScreen.hub.connectAgain")]);
}

#[test]
fn hub_connect_offers_both_scopes() {
    let c = content(&args_for(card(json!({"kind": "hubConnect"}))));
    assert_eq!(ids(&c), [Some("macScreen.hub.connectView"), Some("macScreen.hub.connectFull")]);
    assert!(!c.buttons[0].primary && c.buttons[1].primary && c.buttons[1].return_key);
    assert_eq!(c.buttons[1].scope.as_deref(), Some("full"));
}

#[test]
fn refusals() {
    let refused = |r: &str| card(json!({"kind": "hubRefused", "refusal": r, "requested": "full"}));
    let c = content(&args_for(refused("notSignedIn")));
    assert!(c.sign_in);
    assert_eq!(c.title, key("macScreen.hub.signedOutTitle"));
    assert!(!c.buttons[1].primary && c.buttons[1].scope.as_deref() == Some("full"));
    let c = content(&args_for(refused("notFound")));
    assert_eq!(c.buttons.len(), 1);
    let mut a = args_for(refused("hostOffline"));
    assert!(content(&a).buttons[1].primary);
    assert!(!content(&a).start);
    a.shows_start = true;
    assert!(content(&a).start && !content(&a).buttons[1].primary);
    let c = content(&args_for(refused("permissionNone")));
    assert_eq!(c.line.unwrap().text, keyed("macScreen.hub.noneBodyBlocked", &["$name", "$name"]));
    let c = content(&args_for(refused("scopeExceeds")));
    assert_eq!(c.buttons[1].id, Some("macScreen.hub.viewInstead"));
    let other = card(json!({"kind": "hubRefused", "refusal": "other", "otherReason": "busy"}));
    let c = content(&args_for(other));
    assert_eq!(
        c.line,
        Some(Line {
            text: keyed("macScreen.hub.otherBodyReason", &["$otherReason"]),
            printed: true
        })
    );
    let c = content(&args_for(refused("other")));
    assert_eq!(c.line, Some(Line { text: key("macScreen.hub.otherBody"), printed: false }));
}

#[test]
fn refused_titles_and_bodies() {
    assert_eq!(refused_title("hostOffline"), keyed("macScreen.hub.offlineTitle", &["$name"]));
    assert_eq!(refused_title("permissionNone"), key("macScreen.card.failedTitle"));
    let shared = Card { refusal: Some("notShared".into()), ..Card::default() };
    assert_eq!(refused_body(&shared, Some("linux")).key, Some("macScreen.hub.notSharedBodyLinux"));
    assert_eq!(refused_body(&shared, Some("macos")).key, Some("macScreen.hub.notSharedBodyNamed"));
}

#[test]
fn failed_detail_sources_and_quiet() {
    assert_eq!(failed_detail_source(&card(json!({"kind": "failed"}))), Some("failed"));
    assert_eq!(
        failed_detail_source(&card(json!({"kind": "hubEnded", "end": {"failed": true}}))),
        Some("hub")
    );
    assert_eq!(failed_detail_source(&card(json!({"kind": "hubRevoked"}))), None);
    assert_eq!(
        handle("quiet", &json!({"look": "a", "card": {"kind": "hubWaiting"}})),
        Some(Ok(json!(true)))
    );
    assert_eq!(
        handle("quiet", &json!({"look": "c", "card": {"kind": "hubWaiting"}})),
        Some(Ok(json!(false)))
    );
    assert_eq!(
        handle("quiet", &json!({"look": "a", "card": {"kind": "failed"}})),
        Some(Ok(json!(false)))
    );
    assert_eq!(
        handle("setupApplies", &json!({"card": {"kind": "hubRefused", "refusal": "hostOffline"}})),
        Some(Ok(json!(true)))
    );
}

#[test]
fn quiet_card_has_no_info_circle() {
    let mut a = args_for(card(json!({"kind": "hubRequesting", "scope": "full"})));
    assert_eq!(content(&a).line, Some(Line { text: token("$scopeTitle"), printed: false }));
    a.quiet = true;
    assert_eq!(content(&a).line, None);
}
