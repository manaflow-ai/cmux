//! `cmux --version` and `cmux --version --json` (plans/cmux-next/tui-tester-rollout.md).
//!
//! The text names the npm/PyPI release a tester installed
//! (`CMUX_TUI_DISTRIBUTION_VERSION`, stamped by the release workflows), not
//! the crate's internal version: the published 0.13.4 printed `cmux 0.1.0`.
//! The JSON is the one paste a bug report needs for version-skew triage:
//! release, build, both protocols, platform and how the binary was installed.

use std::path::Path;

pub(crate) use cmux_tui_core::release::InstallChannel;
use cmux_tui_core::release::is_release;

/// This binary's release stamp, `None` for a build that has none. Read only
/// here: cmux-tui-core gets it at start (`install_distribution_version`), so a
/// new stamp recompiles this crate and not the libraries.
pub(crate) const DISTRIBUTION_STAMP: Option<&str> = option_env!("CMUX_TUI_DISTRIBUTION_VERSION");

/// The npm/PyPI release that contains this binary, as
/// `cmux_tui_core::release::distribution_version` reports it once installed.
pub(crate) const DISTRIBUTION_VERSION: &str = match DISTRIBUTION_STAMP {
    Some(version) if is_release(version) => version,
    _ => env!("CARGO_PKG_VERSION"),
};

/// Whether this binary was stamped as an npm/PyPI release (not a `0.0.0-…`
/// placeholder): crash forwarding and the update check run only then.
pub(crate) const RELEASE_STAMPED: bool = match DISTRIBUTION_STAMP {
    Some(version) => is_release(version),
    None => false,
};

/// The release `cmux --version` names. An unpublished commit artifact (the R2
/// tree builds the cmux-next app bundles, stamped `0.0.0-r2.sha-<commit>`)
/// names the cmux-next version, the crate version from cmux-tui/Cargo.toml
/// [workspace.package], so the app's CLI says what the app says (1.0.0).
pub(crate) fn release_version<'a>(distribution: &'a str, crate_version: &'a str) -> &'a str {
    if distribution.starts_with("0.0.0-") { crate_version } else { distribution }
}

/// `cmux --version`'s line after `cmux `.
pub(crate) fn version_text(
    distribution: &str,
    commit: Option<&str>,
    ghostty: Option<&str>,
) -> String {
    match (commit, ghostty) {
        (Some(commit), Some(ghostty)) => format!("{distribution} ({commit}; ghostty {ghostty})"),
        (Some(commit), None) => format!("{distribution} ({commit})"),
        (None, _) => distribution.to_string(),
    }
}

/// The `CMUXCommit` of the app bundle around `exe`, when the CLI runs from
/// inside one (`X.app/Contents/Resources/bin/cmux`). A nightly can bundle a
/// client built from another commit of the same tree (RFD 0021), so the
/// compiled commit alone does not say which app this is; this does.
pub(crate) fn app_commit(exe: &Path) -> Option<String> {
    let bundle = crate::app_identity::containing_app_bundle(exe)?;
    let info = plist::Value::from_file(bundle.join("Contents/Info.plist")).ok()?;
    let commit = info.as_dictionary()?.get("CMUXCommit")?.as_string()?.trim();
    (!commit.is_empty()).then(|| commit.to_owned())
}

/// `cmux --version`'s whole output: the first line as before (scripts parse
/// it), then the enclosing app's commit on its own line when there is one.
pub(crate) fn version_lines(first: &str, app_commit: Option<&str>) -> String {
    match app_commit {
        Some(commit) => format!("cmux {first}\napp {commit}"),
        None => format!("cmux {first}"),
    }
}

/// Facts `--version --json` reports that this module cannot read itself.
pub(crate) struct BuildFacts<'a> {
    pub(crate) build_identity: Option<&'a str>,
    pub(crate) build_time: u64,
    pub(crate) build_commit: Option<&'a str>,
    pub(crate) ghostty_commit: Option<&'a str>,
    pub(crate) remote_protocol: Option<u64>,
}

pub(crate) fn version_json(facts: &BuildFacts<'_>, executable: Option<&Path>) -> serde_json::Value {
    let channel = executable.map_or(InstallChannel::Other, InstallChannel::detect);
    let app_commit = executable.and_then(app_commit);
    serde_json::json!({
        "app": "cmux-tui",
        "version": DISTRIBUTION_VERSION,
        "crate_version": env!("CARGO_PKG_VERSION"),
        "build_identity": facts.build_identity,
        "build_time": facts.build_time,
        "build_commit": facts.build_commit,
        "ghostty_commit": facts.ghostty_commit,
        "app_commit": app_commit,
        "protocol": cmux_tui_core::server::PROTOCOL_VERSION,
        "remote_protocol": facts.remote_protocol,
        "os": std::env::consts::OS,
        "arch": std::env::consts::ARCH,
        "install": channel.as_str(),
        "update_command": channel.update_command(),
    })
}

#[cfg(test)]
#[path = "version_report_tests.rs"]
mod tests;
