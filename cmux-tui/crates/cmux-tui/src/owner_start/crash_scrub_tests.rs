use super::{RULES, SECRET_RULES, scrub};

#[test]
fn every_rule_compiles() {
    let rules = RULES.as_ref().map(|rules| rules.secrets.len());
    assert_eq!(rules, Some(SECRET_RULES.len()));
}

#[test]
fn keeps_field_prefixes_and_ordinary_text() {
    let query = "GET /x?token=abcdef0123456789&page=2";
    assert_eq!(scrub(query, None), "GET /x?token=<redacted-secret>&page=2");
    let plain = "index out of bounds: len 3, index 7";
    assert_eq!(scrub(plain, None), plain);
    assert_eq!(scrub("src/session/mod.rs:42:9", None), "src/session/mod.rs:42:9");
    assert_eq!(scrub("npm_config_cache and hf_hub", None), "npm_config_cache and hf_hub");
}

/// A quoted value ends only at its own closing quote, past escaped quotes (cmux#38555 review F1).
#[test]
fn a_quoted_value_is_redacted_to_its_own_closing_quote() {
    let mixed = r#"password="before'AFTERsecret" next"#;
    assert_eq!(scrub(mixed, None), r#"password="<redacted-secret>" next"#);
    let single = r#"token='before"AFTERsecret' next"#;
    assert_eq!(scrub(single, None), r#"token='<redacted-secret>' next"#);
    let escaped = r#"{"password":"a\"AFTERsecret","n":1}"#;
    assert_eq!(scrub(escaped, None), r#"{"password":"<redacted-secret>","n":1}"#);
    let sid = r#"sid="x'AFTERsecret""#;
    assert_eq!(scrub(sid, None), r#"sid="<redacted-secret>""#);
    // A backslash before a real newline (a shell line continuation) is an escape too.
    let continued = "password=\"a\\\nAFTERsecret\" next";
    assert_eq!(scrub(continued, None), r#"password="<redacted-secret>" next"#);
    assert_eq!(scrub("sid='a\\\nAFTERsecret' next", None), "sid='<redacted-secret>' next");
}

/// Payment and identity numbers are redacted too: a panic can carry pasted text (cmux#38555
/// review F1).
#[test]
fn card_iban_and_ssn_are_redacted() {
    let card = ["4111", "1111", "1111", "1111"].join(" ");
    assert_eq!(scrub(&format!("parse {card} failed"), None), "parse <redacted-secret> failed");
    let iban = ["DE89", "3704", "0044", "0532", "0130", "00"].concat();
    assert_eq!(scrub(&format!("iban {iban} x"), None), "iban <redacted-secret> x");
    let ssn = ["123", "45", "6789"].join("-");
    assert_eq!(scrub(&format!("ssn {ssn}"), None), "ssn <redacted-secret>");
    assert_eq!(scrub("built 2026-11-08", None), "built 2026-11-08");
    let lower = iban.to_lowercase();
    assert_eq!(scrub(&format!("iban {lower} x"), None), "iban <redacted-secret> x");
}

#[test]
fn home_becomes_tilde_and_other_users_are_redacted() {
    assert_eq!(scrub("open /home/maya/x failed", Some("/home/maya")), "open ~/x failed");
    assert_eq!(scrub("at /Users/bob/src", Some("/home/maya")), "at /Users/<redacted>/src");
    assert_eq!(scrub("at /home/bob/src", None), "at /home/<redacted>/src");
    assert_eq!(scrub("/x", Some("/")), "/x");
}

/// The home directory is replaced only as a whole path component, and user paths match in any
/// case, as in `SentryScrubber` (cmux#38555 review F2).
#[test]
fn home_is_replaced_only_as_a_whole_component() {
    let home = Some("/Users/al");
    assert_eq!(scrub("at /Users/alice/project", home), "at /Users/<redacted>/project");
    assert_eq!(scrub("at /Users/al/project and /Users/al", home), "at ~/project and ~");
    assert_eq!(scrub(r#"open "/Users/al" failed"#, home), r#"open "~" failed"#);
    assert_eq!(scrub("at /users/bob/src", None), "at /Users/<redacted>/src");
    // A home with a trailing slash, outside /Users and /home (cmux#38555 review 8 F1).
    assert_eq!(scrub("at /srv/alice/project/x", Some("/srv/alice/")), "at ~/project/x");
    // Any character that cannot continue a name ends the home (cmux#38555 review 9 F1).
    let home = Some("/srv/alice");
    assert_eq!(scrub("cannot read /srv/alice: denied", home), "cannot read ~: denied");
    assert_eq!(scrub("open(/srv/alice) and [/srv/alice]", home), "open(~) and [~]");
    let longer = "at /srv/alice.old/x and /srv/alice-2";
    assert_eq!(scrub(longer, home), longer);
    // A home that is the users' directory must not hide the name (cmux#38555 review 7 F1).
    for home in ["/home", "/Users", "/home/"] {
        let out = scrub("at /home/alice/project and /Users/alice/x", Some(home));
        assert!(!out.contains("alice"), "{home}: {out}");
    }
}

#[test]
fn url_credentials_keep_scheme_and_host() {
    assert_eq!(
        scrub("clone https://me:pw@git.example.com/r.git", None),
        "clone https://<redacted-secret>@git.example.com/r.git"
    );
    assert_eq!(scrub("mail a.b@corp.dev now", None), "mail <redacted-email> now");
}
