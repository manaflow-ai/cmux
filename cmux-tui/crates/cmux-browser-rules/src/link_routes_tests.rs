use crate::link_routes::*;
use crate::ops;
use serde_json::{Value, json};

fn web(scheme: &str, host: &str) -> Option<Address> {
    Some(Address { scheme: Some(scheme.into()), host: Some(host.into()) })
}

#[test]
fn only_chromium_schemes_need_chromium() {
    assert!(needs_chromium(Some("chrome")));
    assert!(needs_chromium(Some("Chrome-Extension")));
    assert!(!needs_chromium(Some("https")));
    assert!(!needs_chromium(Some("about")));
    assert!(!needs_chromium(None));
}

#[test]
fn the_new_tab_page_and_the_blank_page_are_new_tab_pages() {
    for text in
        ["about:blank", "ABOUT:BLANK", "chrome://newtab/", "chrome://NewTab", "chrome://newtab"]
    {
        assert!(is_new_tab_page(text), "{text}");
    }
    for text in ["", "https://example.com/", "chrome://newtab/x", "about:srcdoc"] {
        assert!(!is_new_tab_page(text), "{text}");
    }
}

#[test]
fn a_tab_is_on_the_host_by_its_first_web_address() {
    let hosts = ["claude.ai".to_string()];
    assert!(on_host(&[web("https", "GitHub.com")], Some("github.com"), &[]));
    assert!(on_host(&[None, web("http", "github.com")], Some("github.com"), &[]));
    assert!(on_host(&[web("https", "claude.ai")], Some("claude.com"), &hosts));
    // The first web address decides, not a later one.
    assert!(!on_host(
        &[web("https", "news.example.com"), web("https", "github.com")],
        Some("github.com"),
        &[]
    ));
    assert!(!on_host(&[web("https", "gist.github.com")], Some("github.com"), &[]));
    // A non-web address is skipped; none at all, or no host to match, is no.
    assert!(!on_host(&[web("about", "github.com")], Some("github.com"), &[]));
    assert!(!on_host(&[None], Some("github.com"), &[]));
    assert!(!on_host(&[web("https", "github.com")], None, &[]));
    assert!(!on_host(
        &[Some(Address { scheme: Some("https".into()), host: None })],
        Some("github.com"),
        &[]
    ));
}

#[test]
fn only_a_single_tab_on_the_host_closes() {
    let on = vec![web("https", "github.com")];
    let off = vec![web("https", "example.com")];
    assert_eq!(to_close(&[on.clone()], Some("github.com"), &[]), Some(0));
    assert_eq!(to_close(&[off.clone(), on.clone()], Some("github.com"), &[]), Some(1));
    assert_eq!(to_close(&[on.clone(), on.clone()], Some("github.com"), &[]), None);
    assert_eq!(to_close(&[off], Some("github.com"), &[]), None);
    assert_eq!(to_close(&[], Some("github.com"), &[]), None);
}

#[test]
fn a_popup_takes_the_size_and_a_nonzero_origin() {
    let given = popup_request(Some(Features { x: 10.0, y: 20.0, width: 400.0, height: 300.0 }));
    assert_eq!(given, PopupRequest { width: 400.0, height: 300.0, x: Some(10.0), y: Some(20.0) });
    let unplaced = popup_request(Some(Features { x: 0.0, y: 0.0, width: -5.0, height: 300.0 }));
    assert_eq!(unplaced, PopupRequest { width: 0.0, height: 300.0, x: None, y: None });
    let one_axis = popup_request(Some(Features { x: 0.0, y: 7.0, width: 1.0, height: 1.0 }));
    assert_eq!((one_axis.x, one_axis.y), (Some(0.0), Some(7.0)));
    assert_eq!(popup_request(None), PopupRequest { width: 0.0, height: 0.0, x: None, y: None });
}

fn op(name: &str, request: Value) -> Value {
    ops::call(name, request).unwrap()
}

#[test]
fn the_ops_answer_over_json() {
    assert_eq!(
        op("browser_rules_linkroute_needs_chromium", json!({"scheme": "chrome"})),
        json!(true)
    );
    assert_eq!(op("browser_rules_linkroute_needs_chromium", json!({"scheme": null})), json!(false));
    assert_eq!(
        op("browser_rules_linkroute_is_new_tab_page", json!({"text": "about:blank"})),
        json!(true)
    );
    let tabs = json!([{"shown": [{"scheme": "https", "host": "github.com"}]}, {"shown": [null]}]);
    assert_eq!(
        op(
            "browser_rules_linkroute_sign_in_to_close",
            json!({"tabs": tabs, "host": "github.com", "hosts": []})
        ),
        json!(0)
    );
    assert_eq!(
        op(
            "browser_rules_linkroute_sign_in_on_host",
            json!({"shown": [null], "host": "github.com"})
        ),
        json!(false)
    );
    assert_eq!(
        op(
            "browser_rules_linkroute_popup_request",
            json!({"features": {"x": 0, "y": 0, "width": 5, "height": 6}})
        ),
        json!({"width": 5.0, "height": 6.0})
    );
    assert!(ops::call("browser_rules_linkroute_nope", json!({})).is_err());
    assert!(ops::call("browser_rules_linkroute_is_new_tab_page", json!({})).is_err());
}
