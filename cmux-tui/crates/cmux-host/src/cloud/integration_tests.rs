use super::integration::{from_json, note_for, reply_for};
use super::sender::Answer;
use serde_json::json;

#[test]
fn validates_provider_scopes_and_label() {
    let ask = from_json(
        &json!({"provider":"slack","scopes":["chat:write","channels:read"],"label":"agent"}),
    )
    .unwrap();
    assert_eq!(ask.provider, "slack");
    assert_eq!(ask.api_body(), json!({"scopes":["chat:write","channels:read"],"label":"agent"}));
    for value in [
        json!({"provider":"","scopes":["read"]}),
        json!({"provider":"linear/token","scopes":["read"]}),
        json!({"provider":"linear","scopes":[]}),
        json!({"provider":"linear","scopes":["read space"]}),
        json!({"provider":"linear","scopes":["read"],"label":"agent label"}),
    ] {
        assert!(from_json(&value).is_err(), "accepted {value}");
    }
}

#[test]
fn accepts_only_a_scoped_short_lived_broker_answer() {
    let ask = from_json(&json!({"provider":"linear","scopes":["issue:create"]})).unwrap();
    let answer = Answer::Http {
        status: 200,
        body: json!({"token":"oauth-secret","expires_at":"2026-12-01T00:00:00Z","provider":"linear","token_id":"0123456789abcdef"}),
    };
    let reply = reply_for(&ask, &answer);
    assert_eq!(reply["ok"], true);
    assert_eq!(reply["scopes"], json!(["issue:create"]));
    assert_eq!(note_for(&ask, &reply), "integration token linear issue:create: minted");
    for field in ["token", "expires_at", "provider", "token_id"] {
        let mut body = json!({"token":"oauth-secret","expires_at":"x","provider":"linear","token_id":"0123456789abcdef"});
        body.as_object_mut().unwrap().remove(field);
        assert_eq!(
            reply_for(&ask, &Answer::Http { status: 200, body })["error"]["code"],
            "integration.bad_answer",
            "{field}"
        );
    }
}
