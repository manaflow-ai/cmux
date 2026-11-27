use serde_json::json;

use super::*;

fn args(words: &[&str]) -> Vec<String> {
    words.iter().map(|word| (*word).to_owned()).collect()
}

fn parsed(words: &[&str]) -> Result<Option<AppCommand>, UsageError> {
    super::super::parse(&args(words))
}

#[test]
fn a_phone_tab_address_routes_the_verb_to_the_phone() {
    let Ok(Some(AppCommand::Phone { device, then })) =
        parsed(&["browser", "tab_ab@phone", "eval", "document.title"])
    else {
        panic!("a phone call");
    };
    assert_eq!(device, None);
    let payload = request(device.as_deref(), &then).expect("a request");
    assert_eq!(payload["op"], "phone-page");
    assert_eq!(payload["device"], json!(null));
    assert_eq!(payload["method"], "browser.page.eval");
    assert_eq!(payload["params"]["tab"], "tab_ab");
    assert_eq!(payload["params"]["script"], "document.title");

    let Ok(Some(AppCommand::Phone { device, then })) =
        parsed(&["browser", "tab_ab@dev-7", "screenshot"])
    else {
        panic!("a phone screenshot");
    };
    assert_eq!(device.as_deref(), Some("dev-7"));
    assert_eq!(
        request(device.as_deref(), &then).expect("a request")["method"],
        "browser.page.screenshot"
    );
}

#[test]
fn a_plain_tab_stays_the_macs() {
    assert!(!matches!(
        parsed(&["browser", "tab_ab", "eval", "1"]),
        Ok(Some(AppCommand::Phone { .. }))
    ));
}

#[test]
fn a_verb_the_phone_does_not_answer_is_a_usage_error_naming_the_ones_it_does() {
    let Err(error) = parsed(&["browser", "tab_ab@phone", "cookies", "get"]) else {
        panic!("refused");
    };
    let text = format!("{error:?}");
    assert!(text.contains("tab_…@phone"), "{text}");
}

#[test]
fn the_link_hosts_refusal_keeps_its_code() {
    let answer = json!({"error": cmux_phone_page::NOT_LINKED, "message": "no iPhone is linked"});
    assert_eq!(
        answered(answer),
        Err(("phone.phone_not_linked".to_owned(), "no iPhone is linked".to_owned()))
    );
    let old = json!({"error": "bad_request", "message": "op is machines, open, pair-requests or traffic"});
    assert_eq!(answered(old).unwrap_err().0, "phone.unsupported_host");
    let ok = json!({"ok": true, "device_id": "dev-1", "value": {"value": 2}});
    assert_eq!(answered(ok), Ok(json!({"value": 2})));
}

#[test]
fn phone_screenshot_rejects_options_the_phone_cannot_honor() {
    for option in ["--selector", "--full-page"] {
        let mut words = vec!["browser", "tab_ab@phone", "screenshot", option];
        if option == "--selector" {
            words.push("h1");
        }
        assert!(parsed(&words).is_err(), "{option}");
    }
}
