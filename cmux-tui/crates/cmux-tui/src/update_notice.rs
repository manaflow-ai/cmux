//! The update notice for npm and PyPI installs (plans/cmux-next/tui-tester-rollout.md #8).
//!
//! The app's bundled binary updates with Sparkle; a standalone install heard
//! nothing, so a tester could run a month-old release. The owner asks the
//! install's registry for the latest release at most once a day
//! (`owner_start/background_checks.rs`) and caches the answer in
//! `update-check.json` at the state root. The interactive client prints one
//! localized line with the update command when it exits, never inside the
//! TUI. Off with `updates.checkAutomatically: false`, the managed
//! `DisableAutoUpdate` policy, `CMUX_TUI_UPDATE_CHECK=off`, under `CI`, and
//! for local builds.

use std::path::{Path, PathBuf};
use std::time::Duration;

use serde_json::Value;

use crate::version_report::{DISTRIBUTION_VERSION, InstallChannel};

const CACHE_NAME: &str = "update-check.json";
/// How long one registry answer holds.
pub(crate) const CHECK_INTERVAL: Duration = Duration::from_secs(24 * 60 * 60);
#[cfg(debug_assertions)]
pub(crate) const TEST_URL_ENV: &str = "CMUX_TUI_TEST_REGISTRY_URL";
#[cfg(debug_assertions)]
const TEST_CHANNEL_ENV: &str = "CMUX_TUI_TEST_INSTALL_CHANNEL";

/// Whether this process may check, or why not.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum Check {
    Allowed,
    Off(&'static str),
}

/// What `allowed` decides from; every input injected, so tests need no environment.
pub(crate) struct CheckInputs<'a> {
    pub(crate) channel: InstallChannel,
    pub(crate) managed_forced: &'a std::collections::BTreeMap<String, Value>,
    pub(crate) settings: Option<&'a Value>,
    pub(crate) release_build: bool,
    pub(crate) env: &'a dyn Fn(&str) -> Option<String>,
}

pub(crate) fn allowed(inputs: &CheckInputs<'_>) -> Check {
    let env_set = |name: &str| (inputs.env)(name).filter(|value| !value.is_empty());
    let falsy =
        |value: &str| matches!(value.to_ascii_lowercase().as_str(), "0" | "off" | "false" | "no");
    if inputs.channel.update_command().is_none() {
        return Check::Off("this install has no update command");
    }
    if inputs.managed_forced.get("DisableAutoUpdate") == Some(&Value::Bool(true))
        || inputs.managed_forced.get("updates.checkAutomatically") == Some(&Value::Bool(false))
    {
        return Check::Off("managed policy DisableAutoUpdate");
    }
    let setting = inputs.settings.and_then(|root| {
        cmux_config::value::value_at(root, &["updates", "checkAutomatically"][..])
    });
    if setting == Some(&Value::Bool(false)) {
        return Check::Off("updates.checkAutomatically is false");
    }
    if env_set("CMUX_TUI_UPDATE_CHECK").is_some_and(|value| falsy(&value)) {
        return Check::Off("CMUX_TUI_UPDATE_CHECK");
    }
    if env_set("CI").is_some() {
        return Check::Off("CI");
    }
    if !inputs.release_build {
        return Check::Off("not a release build");
    }
    Check::Allowed
}

/// The registry document that names `channel`'s latest release.
pub(crate) fn registry_url(channel: InstallChannel) -> Option<String> {
    #[cfg(debug_assertions)]
    if let Some(url) = std::env::var(TEST_URL_ENV).ok().filter(|url| !url.is_empty()) {
        return Some(url);
    }
    match channel {
        InstallChannel::Npm => Some("https://registry.npmjs.org/cmux/latest".into()),
        InstallChannel::Pypi => Some("https://pypi.org/pypi/cmux/json".into()),
        InstallChannel::App | InstallChannel::Other => None,
    }
}

/// npm's `next` tag beside its `latest` URL (`…/cmux/latest` → `…/cmux/next`):
/// the tester channel a176 publishes. PyPI has no tags, so None there.
pub(crate) fn next_url(channel: InstallChannel, latest_url: &str) -> Option<String> {
    if channel != InstallChannel::Npm {
        return None;
    }
    latest_url.strip_suffix("/latest").map(|base| format!("{base}/next"))
}

/// The command that moves an npm install to the `next` tag.
const NPM_NEXT_UPDATE: &str = "npm install --global cmux@next";

/// The latest version in an npm (`version`) or PyPI (`info.version`) answer.
pub(crate) fn parse_latest(body: &[u8]) -> Option<String> {
    let document: Value = serde_json::from_slice(body).ok()?;
    let version = document
        .get("version")
        .or_else(|| document.get("info").and_then(|info| info.get("version")))?
        .as_str()?
        .trim();
    numbers(version).map(|_| version.to_string())
}

/// `major.minor.patch` and whether a pre-release suffix follows.
fn numbers(version: &str) -> Option<([u64; 3], bool)> {
    parts(version).map(|(core, pre)| (core, pre.is_some()))
}

/// `major.minor.patch` and the pre-release suffix after `-`, if any (build metadata after `+` is ignored).
fn parts(version: &str) -> Option<([u64; 3], Option<&str>)> {
    let version = version.split('+').next()?;
    let (core, pre) = match version.split_once('-') {
        Some((core, pre)) if !pre.is_empty() => (core, Some(pre)),
        Some(_) => return None,
        None => (version, None),
    };
    let mut fields = core.split('.').map(|part| part.parse::<u64>().ok());
    let triple = [fields.next()??, fields.next()??, fields.next()??];
    fields.next().is_none().then_some((triple, pre))
}

/// Semver pre-release order: numeric identifiers by value, others by text,
/// numeric before text, and a shorter list first when one is a prefix.
fn pre_release_order(left: &str, right: &str) -> std::cmp::Ordering {
    use std::cmp::Ordering;
    let mut left = left.split('.');
    let mut right = right.split('.');
    loop {
        match (left.next(), right.next()) {
            (None, None) => return Ordering::Equal,
            (None, Some(_)) => return Ordering::Less,
            (Some(_), None) => return Ordering::Greater,
            (Some(a), Some(b)) => {
                let order = match (a.parse::<u64>(), b.parse::<u64>()) {
                    (Ok(a), Ok(b)) => a.cmp(&b),
                    (Ok(_), Err(_)) => Ordering::Less,
                    (Err(_), Ok(_)) => Ordering::Greater,
                    (Err(_), Err(_)) => a.cmp(b),
                };
                if order != Ordering::Equal {
                    return order;
                }
            }
        }
    }
}

/// Whether `latest` is a newer release than `current` (semver order).
pub(crate) fn newer(latest: &str, current: &str) -> bool {
    use std::cmp::Ordering;
    let (Some((latest_core, latest_pre)), Some((current_core, current_pre))) =
        (parts(latest), parts(current))
    else {
        return false;
    };
    let order = latest_core.cmp(&current_core).then_with(|| match (latest_pre, current_pre) {
        (None, None) => Ordering::Equal,
        (None, Some(_)) => Ordering::Greater,
        (Some(_), None) => Ordering::Less,
        (Some(a), Some(b)) => pre_release_order(a, b),
    });
    order == Ordering::Greater
}

/// One cached registry answer.
#[derive(Debug, PartialEq, Eq)]
pub(crate) struct Cached {
    pub(crate) checked_at_ms: u64,
    pub(crate) latest: String,
    /// npm's `next` tag, when the registry has one.
    pub(crate) next: Option<String>,
    pub(crate) channel: String,
}

pub(crate) fn cache_path(root: &Path) -> PathBuf {
    root.join(CACHE_NAME)
}

pub(crate) fn read_cache(root: &Path) -> Option<Cached> {
    let document: Value =
        serde_json::from_slice(&cmux_blocking::fs::read(cache_path(root)).ok()?).ok()?;
    Some(Cached {
        checked_at_ms: document.get("checked_at_ms")?.as_u64()?,
        latest: document.get("latest")?.as_str()?.to_string(),
        next: document.get("next").and_then(Value::as_str).map(String::from),
        channel: document.get("channel")?.as_str()?.to_string(),
    })
}

pub(crate) fn write_cache(root: &Path, cached: &Cached) -> Result<(), String> {
    use std::io::Write;
    let body = serde_json::json!({
        "checked_at_ms": cached.checked_at_ms,
        "latest": cached.latest,
        "next": cached.next,
        "channel": cached.channel,
    });
    let path = cache_path(root);
    let temp = root.join(format!("{CACHE_NAME}.tmp"));
    let mut options = std::fs::OpenOptions::new();
    options.create(true).write(true).truncate(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.mode(0o600).custom_flags(libc::O_NOFOLLOW);
    }
    let mut file = crate::blocking::fs::open_with(&options, &temp)
        .map_err(|error| format!("write cache: {error}"))?;
    file.write_all(body.to_string().as_bytes()).map_err(|error| format!("write cache: {error}"))?;
    cmux_blocking::fs::rename(&temp, path).map_err(|error| format!("write cache: {error}"))
}

/// Whether the cache needs a fresh answer (none, another channel, or older than a day).
pub(crate) fn due(cached: Option<&Cached>, channel: InstallChannel, now_ms: u64) -> bool {
    match cached {
        Some(cached) if cached.channel == channel.as_str() => {
            now_ms.saturating_sub(cached.checked_at_ms) >= CHECK_INTERVAL.as_millis() as u64
                || cached.checked_at_ms > now_ms
        }
        _ => true,
    }
}

/// The notice line for a cached answer, when it names a newer release.
///
/// A stable install hears only about `latest`. A pre-release install (a
/// tester on npm's `next` tag) hears about whichever of `next` and `latest`
/// is newer, with the command for that tag.
pub(crate) fn notice(
    template: &str,
    cached: &Cached,
    channel: InstallChannel,
    current: &str,
) -> Option<String> {
    if cached.channel != channel.as_str() {
        return None;
    }
    let on_prerelease = numbers(current).is_some_and(|(_, pre)| pre);
    let (target, command) = match cached.next.as_deref() {
        Some(next) if on_prerelease && newer(next, &cached.latest) => (next, NPM_NEXT_UPDATE),
        _ => (cached.latest.as_str(), channel.update_command()?),
    };
    if !newer(target, current) {
        return None;
    }
    Some(
        template
            .replace("{latest}", target)
            .replace("{current}", current)
            .replace("{command}", command),
    )
}

/// How this binary was installed (a debug build may say so in the environment).
pub(crate) fn channel() -> InstallChannel {
    #[cfg(debug_assertions)]
    if let Some(channel) =
        std::env::var(TEST_CHANNEL_ENV).ok().and_then(|name| InstallChannel::parse(&name))
    {
        return channel;
    }
    std::env::current_exe()
        .ok()
        .and_then(|path| cmux_blocking::fs::canonicalize(path).ok())
        .map_or(InstallChannel::Other, |path| InstallChannel::detect(&path))
}

/// This process's decision, read from the real environment, policy and settings.
pub(crate) fn decision(channel: InstallChannel) -> Check {
    let env = |name: &str| std::env::var(name).ok();
    let managed = cmux_config::managed::default_reader(env).read();
    let settings = crate::feature_flags::settings();
    #[cfg(debug_assertions)]
    let test_registry = env(TEST_URL_ENV).is_some_and(|url| !url.is_empty());
    #[cfg(not(debug_assertions))]
    let test_registry = false;
    allowed(&CheckInputs {
        channel,
        managed_forced: &managed.forced,
        settings: settings.as_ref(),
        release_build: test_registry || crate::version_report::RELEASE_STAMPED,
        env: &env,
    })
}

/// Prints the notice to stderr when the interactive client exits and a newer
/// release is cached. Reads two small files; never touches the network.
pub(crate) fn print_on_exit() {
    use std::io::IsTerminal;
    if !std::io::stderr().is_terminal() {
        return;
    }
    let channel = channel();
    if decision(channel) != Check::Allowed {
        return;
    }
    let Some(cached) = crate::feature_flags::state_root().and_then(|root| read_cache(&root)) else {
        return;
    };
    let template = crate::localization::catalog().update_notice.available;
    if let Some(line) = notice(template, &cached, channel, DISTRIBUTION_VERSION) {
        eprintln!("{line}");
    }
}

#[cfg(test)]
mod tester_rollout_tests {
    use super::*;
    use std::collections::BTreeMap;

    fn inputs<'a>(
        channel: InstallChannel,
        forced: &'a BTreeMap<String, Value>,
        settings: Option<&'a Value>,
        env: &'a dyn Fn(&str) -> Option<String>,
    ) -> CheckInputs<'a> {
        CheckInputs { channel, managed_forced: forced, settings, release_build: true, env }
    }

    #[test]
    fn only_package_installs_check_and_every_switch_turns_it_off() {
        let none: BTreeMap<String, Value> = BTreeMap::new();
        let no_env = |_: &str| -> Option<String> { None };
        assert_eq!(allowed(&inputs(InstallChannel::Npm, &none, None, &no_env)), Check::Allowed);
        assert_eq!(allowed(&inputs(InstallChannel::Pypi, &none, None, &no_env)), Check::Allowed);
        assert!(matches!(
            allowed(&inputs(InstallChannel::App, &none, None, &no_env)),
            Check::Off(_)
        ));
        let off = serde_json::json!({"updates": {"checkAutomatically": false}});
        assert_eq!(
            allowed(&inputs(InstallChannel::Npm, &none, Some(&off), &no_env)),
            Check::Off("updates.checkAutomatically is false")
        );
        let managed = BTreeMap::from([("DisableAutoUpdate".to_string(), Value::Bool(true))]);
        assert_eq!(
            allowed(&inputs(InstallChannel::Npm, &managed, None, &no_env)),
            Check::Off("managed policy DisableAutoUpdate")
        );
        let ci = |name: &str| (name == "CI").then(|| "true".to_string());
        assert_eq!(allowed(&inputs(InstallChannel::Npm, &none, None, &ci)), Check::Off("CI"));
        let env_off = |name: &str| (name == "CMUX_TUI_UPDATE_CHECK").then(|| "off".to_string());
        assert_eq!(
            allowed(&inputs(InstallChannel::Npm, &none, None, &env_off)),
            Check::Off("CMUX_TUI_UPDATE_CHECK")
        );
        let mut local = inputs(InstallChannel::Npm, &none, None, &no_env);
        local.release_build = false;
        assert_eq!(allowed(&local), Check::Off("not a release build"));
    }

    #[test]
    fn both_registries_name_the_latest_release() {
        assert_eq!(parse_latest(br#"{"version":"0.14.0"}"#).as_deref(), Some("0.14.0"));
        assert_eq!(parse_latest(br#"{"info":{"version":"1.2.3"}}"#).as_deref(), Some("1.2.3"));
        assert_eq!(parse_latest(br#"{"version":"latest"}"#), None);
        assert_eq!(parse_latest(b"<html>"), None);
    }

    #[test]
    fn releases_order_by_number_and_a_release_beats_its_prerelease() {
        assert!(newer("0.14.0", "0.13.4"));
        assert!(newer("1.0.0", "0.99.99"));
        assert!(newer("0.10.0", "0.9.0"));
        assert!(newer("1.0.0", "1.0.0-rc.1"));
        assert!(!newer("0.13.4", "0.13.4"));
        assert!(!newer("0.13.3", "0.13.4"));
        assert!(!newer("1.0.0-rc.2", "1.0.0"));
        assert!(!newer("garbage", "0.1.0"));
        assert!(newer("1.1.0-next.4", "1.1.0-next.3"));
        assert!(newer("1.1.0-next.10", "1.1.0-next.9"));
        assert!(!newer("1.1.0-next.3", "1.1.0-next.3"));
        assert!(newer("1.1.0-next.1", "1.1.0-alpha.9"));
    }

    #[test]
    fn one_answer_holds_for_a_day_and_one_channel() {
        let day = CHECK_INTERVAL.as_millis() as u64;
        let cached = Cached {
            checked_at_ms: 1_000,
            latest: "1.0.0".into(),
            next: None,
            channel: "npm".into(),
        };
        assert!(due(None, InstallChannel::Npm, 1_000));
        assert!(!due(Some(&cached), InstallChannel::Npm, 1_000 + day - 1));
        assert!(due(Some(&cached), InstallChannel::Npm, 1_000 + day));
        assert!(due(Some(&cached), InstallChannel::Pypi, 1_000));
        // A clock that went back does not freeze the check.
        assert!(due(Some(&cached), InstallChannel::Npm, 10));
    }

    #[test]
    fn the_notice_names_the_command_for_the_install() {
        let cached = Cached {
            checked_at_ms: 0,
            latest: "0.14.0".into(),
            next: None,
            channel: "pypi".into(),
        };
        let english = crate::localization::update_notice_english().available;
        let line = notice(english, &cached, InstallChannel::Pypi, "0.13.4").unwrap();
        assert_eq!(
            line,
            "cmux 0.14.0 is available (you have 0.13.4). Update: uv tool upgrade cmux"
        );
        assert_eq!(notice(english, &cached, InstallChannel::Npm, "0.13.4"), None);
        assert_eq!(notice(english, &cached, InstallChannel::Pypi, "0.14.0"), None);
        let japanese = crate::localization::update_notice_japanese().available;
        let line = notice(japanese, &cached, InstallChannel::Pypi, "0.13.4").unwrap();
        assert!(line.contains("0.14.0") && line.contains("uv tool upgrade cmux"), "{line}");
    }

    #[test]
    fn a_tester_on_next_hears_about_the_newer_tag() {
        let english = crate::localization::update_notice_english().available;
        let cached = Cached {
            checked_at_ms: 0,
            latest: "1.0.0".into(),
            next: Some("1.1.0-next.4".into()),
            channel: "npm".into(),
        };
        let line = notice(english, &cached, InstallChannel::Npm, "1.1.0-next.3").unwrap();
        assert!(line.contains("1.1.0-next.4") && line.ends_with("cmux@next"), "{line}");
        // A stable install never hears about next.
        assert_eq!(notice(english, &cached, InstallChannel::Npm, "1.0.0"), None);
        // A stable release past next moves the tester to latest.
        let past = Cached { latest: "1.2.0".into(), ..cached };
        let line = notice(english, &past, InstallChannel::Npm, "1.1.0-next.3").unwrap();
        assert!(line.contains("1.2.0") && line.ends_with("cmux@latest"), "{line}");
    }

    #[test]
    fn only_npm_has_a_next_tag() {
        assert_eq!(
            next_url(InstallChannel::Npm, "https://registry.npmjs.org/cmux/latest").as_deref(),
            Some("https://registry.npmjs.org/cmux/next")
        );
        assert_eq!(next_url(InstallChannel::Pypi, "https://pypi.org/pypi/cmux/json"), None);
    }

    #[test]
    fn the_cache_round_trips() {
        let root = tempfile::tempdir().unwrap();
        let cached = Cached {
            checked_at_ms: 42,
            latest: "1.0.1".into(),
            next: Some("1.1.0-next.2".into()),
            channel: "npm".into(),
        };
        write_cache(root.path(), &cached).unwrap();
        assert_eq!(read_cache(root.path()), Some(cached));
    }
}
