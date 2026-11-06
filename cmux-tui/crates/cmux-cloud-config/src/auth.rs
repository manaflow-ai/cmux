//! The auth rules around the stored session that are not Keychain I/O (the app's
//! `CmuxNextCloud/Auth`): which launch keys auth keeps, the debug auto sign-in's account pick
//! (`DogfoodCredentials`), and the active team's checks (`ActiveTeam`). The app keeps the
//! Keychain and file reads, the Stack client and the team save; it asks here what they mean.

use std::collections::BTreeMap;

use serde::{Deserialize, Serialize};

/// The variables that choose a debug build's sign-in account. The app strips inherited
/// `CMUX_*` variables at launch, so these are captured first and reach auth only, never a child.
pub const LAUNCH_KEY_NAMES: [&str; 8] = [
    "CMUX_AUTH_CREDENTIALS_FILE",
    "CMUX_DEV_AUTH_PROFILE",
    "CMUX_DEV_AUTH_ACCOUNT",
    "CMUX_DEV_AUTH_REPLACE_SESSION",
    "CMUX_DOGFOOD_STACK_EMAIL",
    "CMUX_DOGFOOD_STACK_PASSWORD",
    "CMUX_UITEST_STACK_EMAIL",
    "CMUX_UITEST_STACK_PASSWORD",
];

/// The auth launch keys of `environment`.
pub fn launch_keys(environment: &BTreeMap<String, String>) -> BTreeMap<String, String> {
    environment
        .iter()
        .filter(|(key, _)| LAUNCH_KEY_NAMES.contains(&key.as_str()))
        .map(|(key, value)| (key.clone(), value.clone()))
        .collect()
}

/// The environment auth reads: the process's, plus the captured launch keys it no longer has
/// (a value it still has wins).
pub fn auth_environment(
    process: &BTreeMap<String, String>,
    launch: &BTreeMap<String, String>,
) -> BTreeMap<String, String> {
    let mut merged = launch.clone();
    merged.extend(process.iter().map(|(key, value)| (key.clone(), value.clone())));
    merged
}

/// An email with everything but its first letter and its domain masked, for logs.
pub fn mask(email: &str) -> String {
    match email.split_once('@') {
        Some((_, domain)) => {
            format!("{}***@{domain}", email.chars().next().map(String::from).unwrap_or_default())
        }
        None => "***".to_owned(),
    }
}

/// A debug build's sign-in account (never logged; the password stays in process).
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct Credentials {
    pub email: String,
    pub password: String,
}

/// Why a tagged build starts signed out (logged masked, never the secret).
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "camelCase")]
pub enum Refusal {
    /// No `~/.config/cmux/dev-account` and no `CMUX_DEV_AUTH_ACCOUNT`.
    NoDeclaredAccount,
    /// The account found is not the machine owner's declared one.
    AccountMismatch { found: String, declared: String },
}

/// The account to sign in, or why none.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
pub struct Decision {
    pub credentials: Option<Credentials>,
    pub refusal: Option<Refusal>,
}

/// The files [`decide`] reads under `home` for `environment`: the explicit credentials file
/// alone when one is named, else the declared account and the two ambient secrets files. The
/// app reads them (and checks the explicit one is this user's regular 0600 file) and passes the
/// contents back.
pub fn credential_paths(environment: &BTreeMap<String, String>, home: &str) -> Vec<String> {
    match environment.get("CMUX_AUTH_CREDENTIALS_FILE").filter(|path| !path.is_empty()) {
        Some(explicit) => vec![explicit.clone()],
        None => vec![
            format!("{home}/.config/cmux/dev-account"),
            format!("{home}/.secrets/cmuxterm-dev.env"),
            format!("{home}/.secrets/cmux.env"),
        ],
    }
}

/// What the app read for [`decide`].
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Reads {
    #[serde(default)]
    pub environment: BTreeMap<String, String>,
    pub home: String,
    /// The contents of each path of [`credential_paths`] that could be read.
    #[serde(default)]
    pub files: BTreeMap<String, String>,
    /// Whether the explicit credentials file is a regular file owned by this user, 0600 or stricter.
    #[serde(default)]
    pub explicit_file_secure: bool,
}

/// The account to sign in (the app's `DogfoodCredentials.decide`). An explicit credentials file
/// (`CMUX_AUTH_CREDENTIALS_FILE`) is taken as given, unless `CMUX_DEV_AUTH_ACCOUNT` names another
/// account. The ambient files (`~/.secrets/cmuxterm-dev.env`, `~/.secrets/cmux.env`) and exports
/// sign in only the machine's declared owner account (`CMUX_DEV_AUTH_ACCOUNT`, else
/// `~/.config/cmux/dev-account`): a machine's secrets file can name another person.
/// `CMUX_DEV_AUTH_PROFILE` picks `personal` (dogfood keys) or `agent` (uitest keys).
pub fn decide(reads: &Reads) -> Decision {
    let environment = &reads.environment;
    let expected = environment.get("CMUX_DEV_AUTH_ACCOUNT").filter(|v| !v.is_empty());
    if let Some(explicit) = environment.get("CMUX_AUTH_CREDENTIALS_FILE").filter(|v| !v.is_empty())
    {
        let Some(text) = reads.files.get(explicit).filter(|_| reads.explicit_file_secure) else {
            return Decision::default();
        };
        let values = parse(text);
        let Some(found) =
            pair(&values, "CMUX_DOGFOOD_STACK").or_else(|| pair(&values, "CMUX_UITEST_STACK"))
        else {
            return Decision::default();
        };
        if let Some(expected) = expected
            && !found.email.eq_ignore_ascii_case(expected)
        {
            return Decision {
                credentials: None,
                refusal: Some(Refusal::AccountMismatch {
                    found: found.email,
                    declared: expected.clone(),
                }),
            };
        }
        return Decision { credentials: Some(found), refusal: None };
    }
    let home = &reads.home;
    let declared = expected.cloned().or_else(|| {
        reads
            .files
            .get(&format!("{home}/.config/cmux/dev-account"))
            .map(|text| text.trim().to_owned())
            .filter(|email| !email.is_empty())
    });
    let Some(declared) = declared else {
        return Decision { credentials: None, refusal: Some(Refusal::NoDeclaredAccount) };
    };
    let prefixes: &[&str] =
        match environment.get("CMUX_DEV_AUTH_PROFILE").map(|p| p.to_lowercase()).as_deref() {
            None | Some("") => &["CMUX_DOGFOOD_STACK", "CMUX_UITEST_STACK"],
            Some("personal") => &["CMUX_DOGFOOD_STACK"],
            Some("agent") => &["CMUX_UITEST_STACK"],
            Some(_) => &[],
        };
    let mut sources: Vec<BTreeMap<String, String>> =
        [".secrets/cmuxterm-dev.env", ".secrets/cmux.env"]
            .iter()
            .filter_map(|file| reads.files.get(&format!("{home}/{file}")))
            .map(|text| parse(text))
            .collect();
    sources.push(environment.clone());
    let mut first: Option<Credentials> = None;
    for prefix in prefixes {
        for found in sources.iter().filter_map(|values| pair(values, prefix)) {
            if found.email.eq_ignore_ascii_case(&declared) {
                return Decision { credentials: Some(found), refusal: None };
            }
            first.get_or_insert(found);
        }
    }
    Decision {
        credentials: None,
        refusal: first.map(|found| Refusal::AccountMismatch { found: found.email, declared }),
    }
}

/// A complete pair from one source; never mixes sources.
fn pair(values: &BTreeMap<String, String>, prefix: &str) -> Option<Credentials> {
    let email = values.get(&format!("{prefix}_EMAIL")).filter(|v| !v.is_empty())?;
    let password = values.get(&format!("{prefix}_PASSWORD")).filter(|v| !v.is_empty())?;
    Some(Credentials { email: email.clone(), password: password.clone() })
}

/// `KEY=value` lines; `export`, quotes and comments tolerated.
pub fn parse(text: &str) -> BTreeMap<String, String> {
    let mut values = BTreeMap::new();
    for raw in text.lines() {
        let mut line = raw.trim();
        if line.is_empty() || line.starts_with('#') {
            continue;
        }
        if let Some(rest) = line.strip_prefix("export ") {
            line = rest;
        }
        let Some((key, value)) = line.split_once('=') else { continue };
        let mut value = value.trim();
        for quote in ['"', '\''] {
            if value.len() >= 2
                && let Some(inner) = value.strip_prefix(quote).and_then(|v| v.strip_suffix(quote))
            {
                value = inner;
                break;
            }
        }
        values.insert(key.trim().to_owned(), value.to_owned());
    }
    values
}

/// Why a call naming a team may not act in it.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum TeamRefusal {
    /// The device is restricted to another team.
    Managed,
    /// A call named a team that is not the active one.
    NotActive,
}

/// Why a call naming `requested` (absent or blank: the active team) may not act in it: everything
/// acts in the active team, and a managed device only in its managed team.
pub fn team_refusal(
    requested: Option<&str>,
    active: Option<&str>,
    managed: Option<&str>,
) -> Option<TeamRefusal> {
    let named = requested.map(str::trim).filter(|named| !named.is_empty());
    if let Some(managed) = managed
        && (active != Some(managed) || named.is_some_and(|named| named != managed))
    {
        return Some(TeamRefusal::Managed);
    }
    match named {
        Some(named) if Some(named) != active => Some(TeamRefusal::NotActive),
        _ => None,
    }
}

/// The active team: the account's resolved one, or, on a device restricted to a managed team,
/// that team when the account belongs to it and none otherwise.
pub fn allowed_team_id(
    resolved: Option<&str>,
    available: &[String],
    managed: Option<&str>,
) -> Option<String> {
    match managed {
        None => resolved.map(str::to_owned),
        Some(managed) => available.iter().any(|id| id == managed).then(|| managed.to_owned()),
    }
}

#[cfg(test)]
#[path = "auth_tests.rs"]
mod tests;
