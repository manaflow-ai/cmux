use serde_json::json;

use super::super::call;

#[test]
fn ops_answer_on_the_wire() {
    let root = json!({ "browser": { "hostsToOpenInEmbeddedBrowser": "x" } });
    let reply = call("link_rules.routing", &json!({ "root": root })).unwrap();
    assert_eq!(reply["problems"][0]["path"], "browser.hostsToOpenInEmbeddedBrowser");

    let routing = json!({ "embeddedHosts": ["*.example.com"] });
    let target = |url: &str, host: &str| {
        call(
            "link_rules.target",
            &json!({ "routing": routing, "url": url, "scheme": "https", "host": host }),
        )
        .unwrap()["target"]
            .clone()
    };
    assert_eq!(target("https://app.example.com/", "app.example.com"), "cmuxBrowser");
    assert_eq!(target("https://github.com/", "github.com"), "system");

    let reply = call(
        "link_rules.decide",
        &json!({
            "opener": { "default": "cmux", "rules": ["caller:aws -> chrome@Profile 1"] },
            "url": "https://signin.aws.amazon.com/", "callers": ["aws", "zsh"],
        }),
    )
    .unwrap();
    assert_eq!(
        reply,
        json!({ "target": { "kind": "app", "app": "Google Chrome",
                                          "profile": "Profile 1" }, "rule": 0 })
    );

    let reply = call(
        "link_rules.launch",
        &json!({ "target": reply["target"], "url": "https://x.example/" }),
    )
    .unwrap();
    assert_eq!(
        reply["launch"]["arguments"],
        json!(["--profile-directory=Profile 1", "https://x.example/"])
    );

    assert_eq!(
        call("link_rules.regex_accepts", &json!({ "expression": "(a+)+" })).unwrap(),
        json!({ "accepts": false })
    );
    assert_eq!(
        call(
            "link_rules.external_matches",
            &json!({ "patterns": ["billing"], "url": "https://x/billing" })
        )
        .unwrap(),
        json!({ "matches": true })
    );
    assert_eq!(
        call("link_rules.placement", &json!({ "root": {} })).unwrap(),
        json!({ "placement": "split-right", "problems": [] })
    );
    assert_eq!(
        call("link_rules.opener_target", &json!({ "text": "netscape" })).unwrap(),
        json!({ "target": null })
    );
    assert!(call("link_rules.target", &json!({})).is_err());
}
