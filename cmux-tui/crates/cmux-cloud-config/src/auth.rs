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

/// The name cmux's backend gives a person's own Cloud team (`team-vm-api-personal-stack.ts`
/// creates it as "Personal"). The sign-in service lists it beside shared teams with no other mark a
/// signed-in client can read (its provenance is server-only metadata), so this name is what tells
/// the person's own team apart on screen. It only labels a row; nothing is allowed or refused by it.
pub const PERSONAL_TEAM_NAME: &str = "Personal";

/// What the app read about one of the account's teams.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct TeamFacts {
    pub id: String,
    pub name: String,
    /// The team's plan id (`client_read_only_metadata.cmuxPlan`, web billing's mirror), when set.
    #[serde(default)]
    pub plan: Option<String>,
}

/// Whose a team is.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum TeamKind {
    /// The person's own team.
    Personal,
    /// A team shared with other people.
    Team,
}

/// One team as every team list shows it (the account menu, Switch Active Team, the menu bar).
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct TeamRow {
    pub id: String,
    /// The team's name; its id when the name is blank.
    pub title: String,
    pub kind: TeamKind,
    /// The team cmux works in now: the one row a list checks.
    pub active: bool,
    /// The plan id, lowercased, when the team has one; the app names it.
    pub plan: Option<String>,
}

/// Whether `name` is the default team the sign-in service makes for a new account by itself,
/// named for the person's email ("leo@cmux.com's Team"). It is the person's own team as much as
/// "Personal" is (Leo 2026-11-10: "apparently sometimes stakcauth just adds a team of jsut u when
/// it's ur personal account?"), so the lists show it as Personal.
fn is_email_default_team(name: &str) -> bool {
    let lower = name.to_lowercase();
    let Some(owner) =
        lower.strip_suffix("'s team").or_else(|| lower.strip_suffix("\u{2019}s team"))
    else {
        return false;
    };
    let mut parts = owner.split('@');
    let (Some(local), Some(domain), None) = (parts.next(), parts.next(), parts.next()) else {
        return false;
    };
    !local.is_empty() && domain.contains('.') && !owner.chars().any(char::is_whitespace)
}

/// The account's teams as rows, in the order given, with `active` checked: at most one row is,
/// and none when `active` names no listed team. The sign-in service's email-named default team
/// shows as Personal, unless the account already has a team named Personal: then each keeps its name.
pub fn team_rows(teams: &[TeamFacts], active: Option<&str>) -> Vec<TeamRow> {
    let has_personal = teams.iter().any(|team| team.name.trim() == PERSONAL_TEAM_NAME);
    teams
        .iter()
        .map(|team| {
            let name = team.name.trim();
            let name = if !has_personal && is_email_default_team(name) {
                PERSONAL_TEAM_NAME
            } else {
                name
            };
            let plan = team
                .plan
                .as_deref()
                .map(|plan| plan.trim().to_lowercase())
                .filter(|plan| !plan.is_empty() && plan.len() <= 64);
            TeamRow {
                id: team.id.clone(),
                title: if name.is_empty() { team.id.clone() } else { name.to_owned() },
                kind: if name == PERSONAL_TEAM_NAME { TeamKind::Personal } else { TeamKind::Team },
                active: active == Some(team.id.as_str()),
                plan,
            }
        })
        .collect()
}

/// The build facts [`launch_sign_in`] reads.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Build {
    pub bundle_id: Option<String>,
    pub is_debug_build: bool,
    pub is_production_auth: bool,
}

/// How a launch signs in from the credentials it was given.
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct LaunchSignIn {
    /// The debug sign-in surface: the ambient dogfood files and the `42` shortcut.
    pub dev_auth: bool,
    /// Whether the launch resolves credentials and signs in from them.
    pub auto_login: bool,
    /// Whether resolved credentials replace a session already stored.
    pub replaces_session: bool,
    /// Whether the session lives in memory only: never read from or written to the Keychain, the
    /// credentials file or the defaults, so it ends with the process.
    pub memory_only: bool,
}

/// How a launch of `build` with `environment` signs in. The signed NEXT DEV build (a Release
/// compile) signs in only from an explicit `CMUX_AUTH_CREDENTIALS_FILE` (the proof passes it),
/// never the ambient files, keeps a session already signed in unless told to replace it, and gets
/// no debug sign-in surface. Signed cmux NIGHTLY signs in from an explicit file the same way, for
/// end-to-end checks on a CI Mac, with that launch's session in memory only: it never reads, writes
/// or replaces the session in its Keychain. Every other Release build never signs in from the
/// launch. A debug build signs in from its dogfood credentials against the development project;
/// pointed at production, only from an explicit file.
pub fn launch_sign_in(build: &Build, environment: &BTreeMap<String, String>) -> LaunchSignIn {
    let explicit = environment.get("CMUX_AUTH_CREDENTIALS_FILE").is_some_and(|v| !v.is_empty());
    let bundle_id = build.bundle_id.as_deref();
    if !build.is_debug_build
        && bundle_id == Some(crate::config::NIGHTLY_BUNDLE_ID)
        && build.is_production_auth
        && explicit
    {
        return LaunchSignIn { auto_login: true, memory_only: true, ..LaunchSignIn::default() };
    }
    let replace_asked = environment.get("CMUX_DEV_AUTH_REPLACE_SESSION").is_some_and(|v| v == "1");
    if !build.is_debug_build && bundle_id == Some(crate::config::NEXT_DEV_BUNDLE_ID) && explicit {
        return LaunchSignIn {
            auto_login: true,
            replaces_session: replace_asked,
            ..LaunchSignIn::default()
        };
    }
    let dev_auth = build.is_debug_build && (!build.is_production_auth || explicit);
    let replaces = replace_asked
        || environment.contains_key("CMUX_DEV_AUTH_PROFILE")
        || environment.contains_key("CMUX_AUTH_CREDENTIALS_FILE");
    LaunchSignIn {
        dev_auth,
        auto_login: dev_auth,
        replaces_session: dev_auth && replaces,
        memory_only: false,
    }
}

/// What the launch's sign-in does with the account [`decide`] picked.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct LaunchLogin {
    /// The account to sign in, handed to the coordinator's auto-login as the
    /// `CMUX_UITEST_STACK_*` launch keys.
    pub credentials: Option<Credentials>,
    pub replace_session: bool,
    /// Whether the coordinator may sign in from the launch's keys at all: the debug surface, or
    /// the explicit file's resolved account (never raw launch keys on a signed build).
    pub allows_environment_auto_login: bool,
    /// Why the build starts signed out, masked for the log; never the secret.
    pub refusal_log: Option<String>,
}

/// The launch's sign-in: `sign_in` from [`launch_sign_in`], `decision` from [`decide`] (absent
/// when the launch does not sign in from credentials).
pub fn launch_login(sign_in: &LaunchSignIn, decision: Option<&Decision>) -> LaunchLogin {
    let credentials = decision.and_then(|d| d.credentials.clone());
    let refusal_log = decision.and_then(|d| d.refusal.as_ref()).map(|refusal| match refusal {
        Refusal::NoDeclaredAccount => "dev auto sign-in off: no declared account (~/.config/cmux/dev-account or CMUX_DEV_AUTH_ACCOUNT)".to_owned(),
        Refusal::AccountMismatch { found, declared } => {
            format!("dev auto sign-in off: {} is not the declared {}", mask(found), mask(declared))
        }
    });
    LaunchLogin {
        replace_session: credentials.is_some() && sign_in.replaces_session,
        allows_environment_auto_login: sign_in.dev_auth
            || (sign_in.auto_login && credentials.is_some()),
        credentials,
        refusal_log,
    }
}

/// Where the hosted cmux sign-in opens (Debug Settings `auth.signInWindow`).
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum SignInWindow {
    /// The popup when the default browser is Safari, else the default browser.
    Automatic,
    /// Always the popup (a browser that ends it at once still falls back).
    Popup,
    /// Always the default browser.
    DefaultBrowser,
}

/// Bundle identifiers of browsers that host the sign-in popup (`ASWebAuthenticationSession`).
/// macOS hands the popup to the default browser, and one that does not host those sessions ends
/// it as cancelled (Helium; Edge, 2026-10-19: four Sign In clicks, four cancels).
pub const POPUP_BROWSERS: [&str; 2] = ["com.apple.Safari", "com.apple.SafariTechnologyPreview"];

/// Whether a sign-in skips the popup and opens in the default browser (`default_browser`: its
/// bundle identifier, absent when unknown).
pub fn opens_default_browser(window: SignInWindow, default_browser: Option<&str>) -> bool {
    match window {
        SignInWindow::Popup => false,
        SignInWindow::DefaultBrowser => true,
        SignInWindow::Automatic => default_browser.is_some_and(|b| !POPUP_BROWSERS.contains(&b)),
    }
}

/// Whether a person's creation waiting on a hosted sign-in survives an account scope change
/// (`[user, team]`, before and after). Hosted auth publishes its user before loading the initial
/// active team: that nil-to-team hydration belongs to the sign-in being awaited. A later user
/// replacement, sign-out, or populated-team change does not.
pub fn creation_survives_scope_change(
    previous: &[Option<String>],
    current: &[Option<String>],
) -> bool {
    let at = |scope: &[Option<String>], i: usize| scope.get(i).cloned().flatten();
    let (was_user, was_team) = (at(previous, 0), at(previous, 1));
    let (user, team) = (at(current, 0), at(current, 1));
    (previous.len() == 2 && was_user.is_none() && was_team.is_none() && user.is_some())
        || (was_user.is_some() && was_user == user && was_team.is_none() && team.is_some())
}

/// The team detail facts the Invite to Team dialog's cost line reads.
#[derive(Clone, Debug, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SeatInputs {
    pub invite_members: bool,
    pub role: Option<String>,
    pub plan_id: Option<String>,
    pub has_active_subscription: Option<bool>,
    pub member_count: Option<u64>,
    pub member_limit: Option<u64>,
    /// The detail's member rows.
    pub members: u64,
}

/// What a team's plan says about one more member.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct SeatFacts {
    pub can_invite: bool,
    pub plan_id: Option<String>,
    pub has_subscription: bool,
    pub member_count: u64,
    pub member_limit: Option<u64>,
}

/// A team's seat facts: an admin may always invite; the billed member count, else the rows.
pub fn seat_facts(inputs: &SeatInputs) -> SeatFacts {
    SeatFacts {
        can_invite: inputs.invite_members || inputs.role.as_deref() == Some("admin"),
        plan_id: inputs.plan_id.clone(),
        has_subscription: inputs.has_active_subscription.unwrap_or(false),
        member_count: inputs.member_count.unwrap_or(inputs.members),
        member_limit: inputs.member_limit,
    }
}

/// How one team invite went.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum InviteAnswer {
    Sent,
    AlreadyMember,
    SendFailed,
    NotAllowed,
    Unreachable,
}

/// One invite's answer: `error` is the team error the call threw (`forbidden`, ...), else
/// `first_failure_already_member` says whether the address was refused, and why.
pub fn invite_answer(
    error: Option<&str>,
    first_failure_already_member: Option<bool>,
) -> InviteAnswer {
    match (error, first_failure_already_member) {
        (Some("forbidden"), _) => InviteAnswer::NotAllowed,
        (Some(_), _) => InviteAnswer::Unreachable,
        (None, None) => InviteAnswer::Sent,
        (None, Some(true)) => InviteAnswer::AlreadyMember,
        (None, Some(false)) => InviteAnswer::SendFailed,
    }
}

#[cfg(test)]
#[path = "auth_tests.rs"]
mod tests;
