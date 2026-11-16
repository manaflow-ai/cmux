//! What a crash report from a standalone cmux-tui may not carry (docs/privacy.md, Telemetry).
//!
//! The app's reports go through `SentryScrubber` (Packages/Shared/CmuxSentryTelemetry); this is
//! the same free-text rule set, in the same order, for the panic and memory lines `crash_forward`
//! sends: URL credentials, then tokens and keys (`ScrubberDenylists.valuePatterns`), then emails,
//! then the home directory and any other `/Users/<name>` or `/home/<name>`. A rule's group 1, when
//! it has one, is a prefix kept in the output (`token=`).

use regex::{Captures, Regex};
use std::sync::LazyLock;

const SECRET: &str = "<redacted-secret>";
const EMAIL: &str = "<redacted-email>";
const USER: &str = "<redacted>";
const URL_SECRET: &str = "<redacted-secret>@";

/// The secret rules, `ScrubberDenylists.valuePatterns` in its order, card, IBAN and SSN included
/// (a panic can carry pasted text). `(?i)` where the Swift pattern is case-insensitive.
const SECRET_RULES: &[&str] = &[
    r"(?i)(Bearer\s+)[A-Za-z0-9\-._~+/]+=*",
    r"(?i)(Authorization:\s*\w+\s+)\S+",
    // A quoted value runs to its own closing quote, past backslash escapes: one rule per quote.
    r#"(?i)([A-Za-z0-9.\-]*(?:access[_\-]?token|api[_\-]?key|access[_\-]?key|private[_\-]?key|session[_\-]?id|session|secret|token|password|passwd|pwd|credentials?|cookie|bearer|auth)[A-Za-z0-9.\-]*["']?\s*[:=]\s*")(?:[^"\\]|\\[\s\S])*"#,
    r#"(?i)([A-Za-z0-9.\-]*(?:access[_\-]?token|api[_\-]?key|access[_\-]?key|private[_\-]?key|session[_\-]?id|session|secret|token|password|passwd|pwd|credentials?|cookie|bearer|auth)[A-Za-z0-9.\-]*["']?\s*[:=]\s*')(?:[^'\\]|\\[\s\S])*"#,
    r#"(?i)(\bsid["']?\s*[:=]\s*")(?:[^"\\]|\\[\s\S])*"#,
    r#"(?i)(\bsid["']?\s*[:=]\s*')(?:[^'\\]|\\[\s\S])*"#,
    r#"(?i)([A-Za-z0-9.\-]*(?:access[_\-]?token|api[_\-]?key|access[_\-]?key|private[_\-]?key|session[_\-]?id|session|secret|token|password|passwd|pwd|credentials?|cookie|bearer|auth)[A-Za-z0-9.\-]*["']?\s*[:=]\s*)[^\s"'&,}]+"#,
    r#"(?i)(\bsid["']?\s*[:=]\s*)[^\s"'&,}]+"#,
    r"(?i)\b(?:sk|pk|rk|ghp|gho|ghu|ghs|ghr|xox[baprs])[_\-][A-Za-z0-9_\-]{16,}",
    r"\b(?:github_pat_[A-Za-z0-9_]{22,}|glpat-[A-Za-z0-9_\-]{20,}|npm_[A-Za-z0-9]{36,}|hf_[A-Za-z0-9]{30,}|AIza[0-9A-Za-z_\-]{35,})",
    r"\beyJ[A-Za-z0-9_\-]+\.[A-Za-z0-9_\-]+\.[A-Za-z0-9_\-]+",
    r"\b(?:AKIA|ASIA)[A-Z0-9]{16}\b",
    r"(?i)-----BEGIN[A-Z ]+(?:PRIVATE|PUBLIC) KEY-----[\s\S]+?-----END[A-Z ]+(?:PRIVATE|PUBLIC) KEY-----",
    r"\b(?:3[47]\d|4\d{3}|5[1-5]\d\d|65\d\d|6011)(?:[-\s]?\d){12}\b",
    concat!(
        r"(?i)\b(?:AT|AD|AE|AL|AZ|BA|BE|BG|BH|BR|BY|CH|CR|CY|CZ|DE|DK|DO|EE|EG|ES|FI|FO|FR|GB|GE|GI|GL|",
        r"GR|GT|HR|HU|IE|IL|IQ|IS|IT|JO|KW|KZ|LB|LC|LI|LT|LU|LV|LY|MC|MD|ME|MK|MR|MT|MU|NL|NO|",
        r"PK|PL|PS|PT|QA|RO|RU|RS|SA|SC|SE|SI|SK|SM|ST|SV|TL|TN|TR|UA|VA|VG|XK|DZ|AO|BJ|BF|BI|",
        r"CV|CM|CF|TD|KM|CG|CI|DJ|GQ|GA|GW|HN|IR|MG|ML|MA|MZ|NI|NE|SN|TG)",
        r"\d{2}[A-Za-z0-9]{11,29}\b"
    ),
    r"\b[0-9]{3}-[0-9]{2}-[0-9]{4}\b",
];

struct Rules {
    url_userinfo: Regex,
    secrets: Vec<Regex>,
    email: Regex,
    users: Regex,
    homes: Regex,
}

fn compile(pattern: &str) -> Option<Regex> {
    Regex::new(pattern).ok()
}

/// Every rule, or `None` when one does not compile; `scrub` then keeps nothing of the text (it
/// fails closed). Every rule is a constant above, and `every_rule_compiles` checks them.
static RULES: LazyLock<Option<Rules>> = LazyLock::new(|| {
    Some(Rules {
        url_userinfo: compile(r"([A-Za-z][A-Za-z0-9+.\-]*://)[^/?#\s]+@")?,
        secrets: SECRET_RULES.iter().copied().map(compile).collect::<Option<_>>()?,
        email: compile(r"[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}")?,
        users: compile(r#"(?i)/Users/[^/\s"']+"#)?,
        homes: compile(r#"(?i)/home/[^/\s"']+"#)?,
    })
});

/// Keeps group 1 (a field prefix such as `token=`) and replaces the rest of the match with `with`.
fn keep_prefix<'t>(with: &'t str) -> impl FnMut(&Captures<'_>) -> String + 't {
    move |caps| format!("{}{with}", caps.get(1).map_or("", |prefix| prefix.as_str()))
}

/// `text` with secrets, emails and user names removed; `home` becomes `~`, unless it is `/`,
/// `/Users` or `/home`.
pub(super) fn scrub(text: &str, home: Option<&str>) -> String {
    let Some(rules) = RULES.as_ref() else {
        return USER.to_string();
    };
    let mut out = rules.url_userinfo.replace_all(text, keep_prefix(URL_SECRET)).into_owned();
    for rule in &rules.secrets {
        out = rule.replace_all(&out, keep_prefix(SECRET)).into_owned();
    }
    out = rules.email.replace_all(&out, EMAIL).into_owned();
    // `/`, `/Users` or `/home` as the home would swallow the users' directory before the generic
    // rule below sees the name after it, so those get no home rule (as in `SentryScrubber`).
    let users_dir = |home: &&str| {
        matches!(home.trim_matches('/').to_ascii_lowercase().as_str(), "" | "users" | "home")
    };
    // A trailing slash (`HOME=/srv/alice/`) would keep the home from matching `/srv/alice/x`.
    let home = home.map(|home| home.trim_end_matches('/'));
    if let Some(home) = home.filter(|home| !users_dir(home)) {
        // Only a whole name: with `/Users/al`, `/Users/alice` must not become `~ice`, so the home
        // ends at any character that cannot continue a name (`/`, `:`, `)`, a space, the end).
        let pattern = format!(r"(?i){}([^A-Za-z0-9._\-]|$)", regex::escape(home));
        let Some(bounded) = compile(&pattern) else {
            return USER.to_string();
        };
        out = bounded.replace_all(&out, "~$1").into_owned();
    }
    out = rules.users.replace_all(&out, format!("/Users/{USER}")).into_owned();
    rules.homes.replace_all(&out, format!("/home/{USER}")).into_owned()
}

#[cfg(test)]
mod tests {
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
}
