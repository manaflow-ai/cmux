use super::integration::{from_json, note_for, reply_for};
use super::sender::Answer;
use serde_json::json;

#[test]
fn validates_provider_scopes_and_label() {
    let ask = from_json(
        &json!({"provider":"slack","session":"session-1","scopes":["chat:write","channels:read"],"label":"agent"}),
    )
    .unwrap();
    assert_eq!(ask.provider, "slack");
    assert_eq!(ask.api_body(), json!({"scopes":["chat:write","channels:read"]}));
    for value in [
        json!({"provider":"","scopes":["read"]}),
        json!({"provider":"linear/token","scopes":["read"]}),
        json!({"provider":"linear","session":"session-1","scopes":[]}),
        json!({"provider":"linear","session":"session-1","scopes":["read space"]}),
        json!({"provider":"linear","session":"session-1","scopes":["read"],"label":"agent label"}),
    ] {
        assert!(from_json(&value).is_err(), "accepted {value}");
    }
}

#[test]
fn accepts_only_a_scoped_short_lived_broker_answer() {
    let ask =
        from_json(&json!({"provider":"linear","session":"session-1","scopes":["issue:create"]}))
            .unwrap();
    let answer = Answer::Http {
        status: 200,
        body: json!({"token":"oauth-secret","expiresAt":2000,"vendor":"linear","grant":"igr_0123456789abcdef0123456789abcdef","scopes":["issue:create"]}),
    };
    let reply = reply_for(&ask, &answer, 1000);
    assert_eq!(reply["ok"], true);
    assert_eq!(reply["scopes"], json!(["issue:create"]));
    assert_eq!(note_for(&ask, &reply), "integration token linear issue:create: minted");
    for field in ["token", "expiresAt", "vendor", "grant", "scopes"] {
        let mut body = json!({"token":"oauth-secret","expiresAt":2000,"vendor":"linear","grant":"igr_0123456789abcdef0123456789abcdef","scopes":["issue:create"]});
        body.as_object_mut().unwrap().remove(field);
        assert_eq!(
            reply_for(&ask, &Answer::Http { status: 200, body }, 1000)["error"]["code"],
            "integration.bad_answer",
            "{field}"
        );
    }
}

#[test]
fn refuses_missing_session_and_mismatched_broker_answers() {
    let request = json!({"provider":"linear","session":"session-1","scopes":["issue:create"],"grant":"igr_0123456789abcdef0123456789abcdef"});
    let ask = from_json(&request).unwrap();
    assert_eq!(
        ask.api_body(),
        json!({"scopes":["issue:create"],"grant":"igr_0123456789abcdef0123456789abcdef"})
    );
    for session in [json!(null), json!(""), json!("s\r\nx-injected: yes"), json!("x".repeat(257))] {
        let mut invalid = request.clone();
        invalid["session"] = session;
        assert!(from_json(&invalid).is_err());
    }
    let good = json!({"token":"secret","expiresAt":2000,"vendor":"linear","grant":"igr_0123456789abcdef0123456789abcdef","scopes":["issue:create"]});
    for (field, value) in [
        ("expiresAt", json!(1000)),
        ("expiresAt", json!("2000")),
        ("vendor", json!("slack")),
        ("grant", json!("igr_ffffffffffffffffffffffffffffffff")),
        ("scopes", json!([])),
        ("scopes", json!(["issue:create", "admin"])),
    ] {
        let mut body = good.clone();
        body[field] = value;
        let reply = reply_for(&ask, &Answer::Http { status: 200, body }, 1000);
        assert_eq!(reply["error"]["code"], "integration.bad_answer", "{field}");
        assert!(!reply.to_string().contains("secret"));
    }
}
