//! A setup comes from someone else's repo: what it would put in your
//! customization is checked for credentials the way a shared profile is
//! (`Customize::shareable_profile`), and one that holds any is refused whole.
//! The error names where, never the value.

use cmux_config::Schema;
use cmux_config::schema::Kind;

use super::Setup;
use crate::Error;
use crate::redact::{find_secret, sensitive_value};

/// Refuses `setup` when a setting, file, action or its own text holds
/// something that looks like a credential.
pub(super) fn check_secrets(setup: &Setup) -> Result<(), Error> {
    let refuse = |what: String, kind: &str| {
        Err(Error::Setup(format!(
            "{what} looks like it holds a credential ({kind}); a setup may not carry one"
        )))
    };
    let schema = Schema::embedded();
    for (key, value) in &setup.profile.settings {
        let url = schema.row(key).is_some_and(|row| matches!(row.kind, Kind::Url));
        if sensitive_value(value, url) {
            return refuse(format!("the setting {key}"), "a password in a URL");
        }
        if let Some((_, kind)) = find_secret(&value.to_string()) {
            return refuse(format!("the setting {key}"), kind);
        }
    }
    for (path, text) in &setup.profile.files {
        if let Some((line, kind)) = find_secret(text) {
            return refuse(format!("{path} (line {line})"), kind);
        }
    }
    for (name, value) in &setup.manifest.actions {
        if let Some((_, kind)) = find_secret(&value.to_string()) {
            return refuse(format!("the action {name}"), kind);
        }
    }
    let manifest = &setup.manifest;
    for text in [&manifest.name, &manifest.description].into_iter().chain(&manifest.tagline) {
        if let Some((_, kind)) = find_secret(text) {
            return refuse("the setup's name or description".to_owned(), kind);
        }
    }
    Ok(())
}
