//! A setup comes from someone else's repo: what it would put in your
//! customization is checked for credentials the way a shared profile is
//! (`Customize::shareable_profile`), and one that holds any is refused whole.
//! The finding names where, never the value.

use cmux_config::Schema;
use cmux_config::schema::Kind;

use super::{Finding, SETUP_FILE, Setup, codes};
use crate::redact::{find_secret, sensitive_value};

/// Each setting, file, action (name or value) and text of `setup` that holds
/// something that looks like a credential. Names first: they go into your
/// settings and onto the card, and the messages after them quote them.
pub(super) fn secret_findings(setup: &Setup) -> Vec<Finding> {
    let found = |path: &str, what: String, kind: &str| {
        Finding::error(
            codes::SECRET,
            path,
            format!("{what} looks like it holds a credential ({kind}); a setup may not carry one"),
        )
        .fix("take the credential out; let the person enter it on their machine")
    };
    let mut findings = Vec::new();
    let names = [
        ("a setting's name", setup.profile.settings.keys().collect::<Vec<_>>()),
        ("a file's name", setup.profile.files.keys().collect()),
        ("an action's name", setup.manifest.actions.keys().collect()),
    ];
    let mut bad_names = Vec::new();
    for (what, keys) in names {
        for key in keys {
            if let Some((_, kind)) = find_secret(key) {
                // The name itself is the secret: the finding never quotes it.
                findings.push(found(SETUP_FILE, what.to_owned(), kind));
                bad_names.push(key.clone());
            }
        }
    }
    let quotable = |name: &String| !bad_names.contains(name);
    let schema = Schema::embedded();
    for (key, value) in setup.profile.settings.iter().filter(|(key, _)| quotable(key)) {
        let url = schema.row(key).is_some_and(|row| matches!(row.kind, Kind::Url));
        if sensitive_value(value, url) {
            findings.push(
                found(SETUP_FILE, format!("the setting {key}"), "a password in a URL").key(key),
            );
        } else if let Some((_, kind)) = find_secret(&value.to_string()) {
            findings.push(found(SETUP_FILE, format!("the setting {key}"), kind).key(key));
        }
    }
    for (path, text) in setup.profile.files.iter().filter(|(path, _)| quotable(path)) {
        if let Some((line, kind)) = find_secret(text) {
            let mut finding = found(path, format!("{path} (line {line})"), kind);
            finding.line = Some(line);
            findings.push(finding);
        }
    }
    for (name, value) in setup.manifest.actions.iter().filter(|(name, _)| quotable(name)) {
        if let Some((_, kind)) = find_secret(&value.to_string()) {
            findings.push(
                found(SETUP_FILE, format!("the action {name}"), kind)
                    .key(format!("actions.{name}")),
            );
        }
    }
    let manifest = &setup.manifest;
    for text in [&manifest.name, &manifest.description].into_iter().chain(&manifest.tagline) {
        if let Some((_, kind)) = find_secret(text) {
            findings.push(found(SETUP_FILE, "the setup's name or description".to_owned(), kind));
        }
    }
    findings
}
