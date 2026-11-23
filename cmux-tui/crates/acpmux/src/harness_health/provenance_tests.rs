use super::*;
use crate::harness_health::{Auth, HarnessHealth, channel::Channel};
use serde_json::json;

fn row(auth: Auth, detail: Option<&str>, installed: bool) -> HarnessHealth {
    HarnessHealth {
        id: "codex".into(),
        program: "codex".into(),
        path: installed.then(|| "/usr/local/bin/codex".into()),
        channel: Channel::Npm,
        package: None,
        version: None,
        latest: None,
        latest_checked_at: None,
        outdated: false,
        auth,
        auth_detail: detail.map(str::to_owned),
        login: None,
        update: None,
        problem: None,
        checked_at: 0,
        auto_update: false,
        last_auto_update: None,
    }
}

fn env(pairs: &[(&str, &str)]) -> BTreeMap<String, String> {
    pairs.iter().map(|(k, v)| ((*k).to_owned(), (*v).to_owned())).collect()
}

struct Case {
    family: &'static str,
    argv: Vec<String>,
    profile: BTreeMap<String, String>,
    login: BTreeMap<String, String>,
    config: ConfigSource,
    config_path: Option<&'static str>,
    routed: bool,
    row: Option<HarnessHealth>,
    probe_error: Option<&'static str>,
    machine: &'static str,
}

impl Default for Case {
    fn default() -> Self {
        Self {
            family: "codex",
            argv: vec!["codex-acp".into()],
            profile: BTreeMap::new(),
            login: BTreeMap::new(),
            config: ConfigSource::Discovered,
            config_path: None,
            routed: false,
            row: Some(row(Auth::SignedIn, Some("`codex login status` passed"), true)),
            probe_error: None,
            machine: "big-red",
        }
    }
}

fn run(c: &Case) -> Provenance {
    of(&Inputs {
        family: c.family,
        argv: &c.argv,
        profile_env: &c.profile,
        login_env: &c.login,
        config: c.config,
        config_path: c.config_path,
        routed: c.routed,
        row: c.row.as_ref(),
        probe_error: c.probe_error,
        machine: c.machine,
    })
}

/// Two instances with different accounts are labelled apart before Start: the machine, and the
/// account home the profile names versus the login shell's.
#[test]
fn local_and_remote_accounts_are_labelled_distinctly() {
    let local =
        run(&Case { profile: env(&[("CODEX_HOME", "/Users/leo/.codex-work")]), ..Case::default() });
    let remote = run(&Case {
        login: env(&[("CODEX_HOME", "/home/cmux/.codex-personal")]),
        machine: "air-blue",
        ..Case::default()
    });
    assert_eq!(local.machine, "big-red");
    assert_eq!(local.account, AccountHome::Profile);
    assert_eq!(local.account_name.as_deref(), Some(".codex-work"));
    assert_eq!(remote.machine, "air-blue");
    assert_eq!(remote.account, AccountHome::Environment);
    assert_eq!(remote.account_name.as_deref(), Some(".codex-personal"));
    assert_ne!(local, remote);
    let default = run(&Case::default());
    assert_eq!((default.account, default.account_name), (AccountHome::Default, None));
    let unresolved =
        run(&Case { profile: env(&[("CODEX_HOME", "${HOME}/.x")]), ..Case::default() });
    assert_eq!(unresolved.account, AccountHome::Unresolved);
    let other = run(&Case { family: "pi", ..Case::default() });
    assert_eq!(other.account, AccountHome::Unknown);
}

/// Valid credentials without workspace access read differently from expired or signed out.
#[test]
fn not_entitled_is_its_own_explanation() {
    let missing_access = run(&Case {
        probe_error: Some("Your workspace has been deactivated. Contact your admin."),
        ..Case::default()
    });
    assert_eq!(missing_access.eligibility, Eligibility::NotEntitled);
    let plan = run(&Case {
        row: Some(row(Auth::Unknown, None, true)),
        probe_error: Some(
            "Cloud tasks require a ChatGPT plan; your plan does not include Codex Cloud",
        ),
        ..Case::default()
    });
    assert_eq!(plan.eligibility, Eligibility::NotEntitled);
    let expired = run(&Case {
        row: Some(row(Auth::Expired, Some("credential expired"), true)),
        probe_error: Some("upgrade your plan"),
        ..Case::default()
    });
    assert_eq!(expired.eligibility, Eligibility::Expired);
    let out = run(&Case { row: Some(row(Auth::SignedOut, None, true)), ..Case::default() });
    assert_eq!(out.eligibility, Eligibility::SignInNeeded);
    assert_eq!(run(&Case::default()).eligibility, Eligibility::Eligible);
    let unknown = run(&Case { row: Some(row(Auth::Unknown, None, true)), ..Case::default() });
    assert_eq!(unknown.eligibility, Eligibility::Unknown);
    let gone = run(&Case { row: Some(row(Auth::Unknown, None, false)), ..Case::default() });
    assert_eq!(gone.eligibility, Eligibility::NotInstalled);
    assert_eq!(run(&Case { row: None, ..Case::default() }).eligibility, Eligibility::Unknown);
    assert!(!says_not_entitled("Not logged in"));
    assert!(!says_not_entitled("HTTP 503"));
}

#[test]
fn the_credential_owner_follows_launch_precedence() {
    let launcher = run(&Case {
        family: "claude-sr2",
        argv: vec!["sr2".into(), "claude".into()],
        routed: true,
        ..Case::default()
    });
    assert_eq!(launcher.credential, CredentialOwner::Launcher);
    let routed =
        run(&Case { routed: true, profile: env(&[("OPENAI_API_KEY", "sk-x")]), ..Case::default() });
    assert_eq!(routed.credential, CredentialOwner::Route);
    let profile = run(&Case { profile: env(&[("OPENAI_API_KEY", "sk-x")]), ..Case::default() });
    assert_eq!(profile.credential, CredentialOwner::Profile);
    let shell = run(&Case { login: env(&[("OPENAI_API_KEY", "sk-x")]), ..Case::default() });
    assert_eq!(shell.credential, CredentialOwner::Environment);
    assert_eq!(run(&Case::default()).credential, CredentialOwner::AgentLogin);
    let unknown = run(&Case { row: Some(row(Auth::Unknown, None, true)), ..Case::default() });
    assert_eq!(unknown.credential, CredentialOwner::Unknown);
}

/// Nothing a credential holds, no full path and no raw error text reaches the answer.
#[test]
fn provenance_carries_fixed_words_and_sanitized_names_only() {
    let p = run(&Case {
        profile: env(&[
            ("CODEX_HOME", "/Users/leo/secret dir/.codex-$(work)"),
            ("OPENAI_API_KEY", "sk-live-SECRETVALUE"),
        ]),
        config: ConfigSource::ProfileFile,
        config_path: Some("/Users/leo/.config/acpmux/profiles/codex-work.toml"),
        probe_error: Some("token sk-live-SECRETVALUE not entitled for workspace acme"),
        machine: "big red; rm",
        ..Case::default()
    });
    let text = serde_json::to_string(&p).unwrap();
    for leak in ["SECRETVALUE", "/Users", "acme", "secret dir", "$(", ";"] {
        assert!(!text.contains(leak), "{leak} in {text}");
    }
    assert_eq!(
        serde_json::to_value(&p).unwrap(),
        json!({
            "machine": "bigredrm",
            "account": "profile",
            "accountName": ".codex-work",
            "credential": "profile",
            "config": "profileFile",
            "configName": "codex-work.toml",
            "eligibility": "notEntitled",
        })
    );
    assert_eq!(sanitized_name("/"), None);
    assert_eq!(sanitized_name(".."), None);
}
