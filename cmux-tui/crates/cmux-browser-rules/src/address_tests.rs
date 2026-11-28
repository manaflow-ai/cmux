//! The address rules, pinned to the Swift they replace (HostTypoFixup's documented cases,
//! OmnibarChromeGapsTests' fallback cases).

use crate::address::*;
use crate::ops;
use serde_json::json;

fn fixed(text: &str) -> Option<String> {
    fix_host_typo(text).map(|fix| fix.text)
}

#[test]
fn the_iana_list_holds_real_top_level_domains_in_any_case() {
    for label in ["com", "COM", "net", "org", "dev", "io", "xn--p1ai", "museum"] {
        assert!(is_top_level_domain(label), "{label}");
    }
    for label in ["con", "ocm", "localhost", "", "# version", "example"] {
        assert!(!is_top_level_domain(label), "{label}");
    }
    assert!(TYPOS.iter().all(|(_, tld)| is_top_level_domain(tld)));
}

#[test]
fn a_mistyped_last_label_is_fixed_and_the_rest_stays_as_typed() {
    assert_eq!(fixed("example.con"), Some("example.com".into()));
    assert_eq!(fixed("Example.CON"), Some("Example.com".into()));
    assert_eq!(fixed("  example.ocm  "), Some("example.com".into()));
    assert_eq!(
        fixed("https://news.example.ogr/a/b?q=1#x"),
        Some("https://news.example.org/a/b?q=1#x".into())
    );
    assert_eq!(fixed("HTTP://example.ner:8080/path"), Some("HTTP://example.net:8080/path".into()));
    assert_eq!(fixed("example.com'"), Some("example.com".into()));
    assert_eq!(fixed("a.b.c.rog?x"), Some("a.b.c.org?x".into()));
    let fix = fix_host_typo("https://Shop.Example.Con:443/").unwrap();
    assert_eq!(fix.typed_host, "shop.example.con");
    assert_eq!(fix.text, "https://Shop.Example.com:443/");
}

#[test]
fn nothing_changes_where_the_swift_rule_left_it() {
    for text in [
        "",
        "   ",
        "example.com",
        "example.con.",
        "con",
        "localhost",
        "ftp://example.con",
        "file:///tmp/example.con",
        "user@example.con",
        "https://user:pw@example.con/",
        "[::1].con",
        "example .con",
        "example.con/a b",
        "example.con:",
        "example.con:80a",
        "example..con",
        ".con",
        "example.xyz",
        "/Users/me/example.con",
    ] {
        assert_eq!(fixed(text), None, "{text:?}");
    }
}

#[test]
fn a_typo_that_is_a_real_top_level_domain_is_kept() {
    // `ent` is not delegated today, but a delegation would keep it.
    assert_eq!(fix_host_typo_with("example.ent", |label| label == "ent"), None);
    assert_eq!(
        fix_host_typo_with("example.ent", |_| false),
        Some(TypoFix { text: "example.net".into(), typed_host: "example.ent".into() })
    );
}

#[test]
fn chromium_errors_that_fall_back() {
    assert!(https_upgrade_falls_back("net", -102), "refused");
    assert!(https_upgrade_falls_back("net", -107), "TLS protocol");
    assert!(https_upgrade_falls_back("net", -202), "certificate authority");
    assert!(https_upgrade_falls_back("net", -7), "timed out");
    assert!(https_upgrade_falls_back("net", -100));
    assert!(https_upgrade_falls_back("net", -299));
    assert!(!https_upgrade_falls_back("net", -105), "name not resolved");
    assert!(!https_upgrade_falls_back("net", -106), "offline");
    assert!(!https_upgrade_falls_back("net", -137), "name resolution");
    assert!(!https_upgrade_falls_back("net", -300));
    assert!(!https_upgrade_falls_back("net", -3), "aborted");
}

#[test]
fn nsurl_errors_that_fall_back() {
    for code in [-1004, -1005, -1001, -1200, -1205, -1206, -1011, -1201, -1202, -1203, -1204] {
        assert!(https_upgrade_falls_back(NSURL_ERROR_DOMAIN, code), "{code}");
    }
    for code in [-1003, -1009, -999, -1002] {
        assert!(!https_upgrade_falls_back(NSURL_ERROR_DOMAIN, code), "{code}");
    }
    assert!(!https_upgrade_falls_back("WebKitErrorDomain", -1004));
    assert!(is_certificate_error("net", -201));
    assert!(!is_certificate_error("net", -102));
    assert!(is_certificate_error(NSURL_ERROR_DOMAIN, -1202));
}

#[test]
fn address_ops_answer_in_the_wire_shape_the_app_reads() {
    assert_eq!(
        ops::call("browser_rules_is_top_level_domain", json!({"label": "COM"})).unwrap(),
        json!(true)
    );
    assert_eq!(
        ops::call("browser_rules_is_top_level_domain", json!({"labels": ["dev", "con"]})).unwrap(),
        json!([true, false])
    );
    assert!(ops::call("browser_rules_is_top_level_domain", json!({})).is_err());
    assert_eq!(
        ops::call("browser_rules_host_typo_fix", json!({"text": "example.con/x"})).unwrap(),
        json!({"text": "example.com/x", "typedHost": "example.con"})
    );
    assert_eq!(
        ops::call("browser_rules_host_typo_fix", json!({"text": "example.com"})).unwrap(),
        json!(null)
    );
    assert_eq!(
        ops::call("browser_rules_https_upgrade_falls_back", json!({"domain": "net", "code": -102}))
            .unwrap(),
        json!(true)
    );
}
