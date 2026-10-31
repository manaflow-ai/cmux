//! The release a binary belongs to and how it was installed, shared by
//! `cmux --version`, the daemon's `identify` and every handshake refusal
//! (plans/cmux-next/tui-tester-rollout.md, msg 2785): a refusal names the
//! exact update command for the side that is too old.

use std::path::{Component, Path};

/// The npm/PyPI release that contains this binary. Anything else (a local or
/// test build, or a raw R2 tree artifact stamped `0.0.0-r2.sha-…` that the
/// app bundles) reports the one cmux-next version, the workspace crate
/// version, which `scripts/cmux-next/check-version-surfaces.sh` requires.
/// The binary stamps it (`CMUX_TUI_DISTRIBUTION_VERSION`) and installs it at
/// start ([`install_distribution_version`]), so a new stamp (every build of
/// the Linux pool) recompiles the binary and not this crate.
pub fn distribution_version() -> &'static str {
    INSTALLED_DISTRIBUTION_VERSION.get().copied().unwrap_or(env!("CARGO_PKG_VERSION"))
}

static INSTALLED_DISTRIBUTION_VERSION: std::sync::OnceLock<&'static str> =
    std::sync::OnceLock::new();

/// Records the binary's stamped release, `None` when it has none. A placeholder
/// stamp is not a release ([`is_release`]). The first call wins.
pub fn install_distribution_version(stamped: Option<&'static str>) {
    let _ = INSTALLED_DISTRIBUTION_VERSION.set(release_or_workspace(stamped));
}

/// A release stamp as the version to report: the workspace crate version for
/// none or a placeholder.
fn release_or_workspace(stamped: Option<&str>) -> &str {
    stamped.filter(|version| is_release(version)).unwrap_or(env!("CARGO_PKG_VERSION"))
}

/// A release version: not empty and not a `0.0.0-…` placeholder stamp.
pub const fn is_release(version: &str) -> bool {
    let bytes = version.as_bytes();
    let placeholder = b"0.0.0-";
    if bytes.is_empty() {
        return false;
    }
    if bytes.len() < placeholder.len() {
        return true;
    }
    let mut index = 0;
    while index < placeholder.len() {
        if bytes[index] != placeholder[index] {
            return true;
        }
        index += 1;
    }
    false
}

/// How this binary reached the machine, read from its own path.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum InstallChannel {
    /// A `cmux-tui-<platform>` npm package (`npx cmux`, `npm install -g cmux`).
    Npm,
    /// A `cmux` PyPI wheel (`uvx cmux`, `pipx`, `uv tool install`).
    Pypi,
    /// Bundled inside the cmux macOS app, which updates it.
    App,
    /// Anything else: a source build, a copied binary, an SSH-bootstrapped host.
    Other,
}

impl InstallChannel {
    pub fn detect(executable: &Path) -> Self {
        let names: Vec<String> = executable
            .components()
            .filter_map(|component| match component {
                Component::Normal(name) => Some(name.to_string_lossy().to_ascii_lowercase()),
                _ => None,
            })
            .collect();
        if names.iter().any(|name| name.ends_with(".app")) {
            Self::App
        } else if names.iter().any(|name| name == "node_modules") {
            Self::Npm
        } else if names.iter().any(|name| name == "site-packages" || name == "dist-packages") {
            Self::Pypi
        } else {
            Self::Other
        }
    }

    pub fn as_str(self) -> &'static str {
        match self {
            Self::Npm => "npm",
            Self::Pypi => "pypi",
            Self::App => "app",
            Self::Other => "other",
        }
    }

    /// The command that moves this install to the latest release, when the
    /// channel has one (the app updates itself; other installs are manual).
    pub fn update_command(self) -> Option<&'static str> {
        match self {
            Self::Npm => Some(NPM_UPDATE),
            Self::Pypi => Some(PYPI_UPDATE),
            Self::App | Self::Other => None,
        }
    }
}

impl InstallChannel {
    /// The channel a peer declared on the wire (`npm`, `pypi`, `app`, `other`).
    pub fn parse(name: &str) -> Option<Self> {
        match name {
            "npm" => Some(Self::Npm),
            "pypi" => Some(Self::Pypi),
            "app" => Some(Self::App),
            "other" => Some(Self::Other),
            _ => None,
        }
    }

    /// The channel of the running binary.
    pub fn current() -> Self {
        std::env::current_exe().map_or(Self::Other, |path| Self::detect(&path))
    }

    /// What a person on this channel does to update, in one line.
    pub fn update_hint(self) -> String {
        match (self, self.update_command()) {
            (_, Some(command)) => format!("run `{command}`"),
            (Self::App, None) => "update the cmux app (cmux > Check for Updates)".to_string(),
            _ => format!("reinstall cmux: `{NPM_UPDATE}` or `{PYPI_UPDATE}`"),
        }
    }
}

const NPM_UPDATE: &str = "npm install --global cmux@latest";
const PYPI_UPDATE: &str = "uv tool upgrade cmux";

/// The hint for a peer whose channel is unknown (a build from before
/// `install` was sent): every package command.
pub fn update_hint_for(install: Option<&str>) -> String {
    match install.and_then(InstallChannel::parse) {
        Some(channel) => channel.update_hint(),
        None => format!(
            "update cmux: `{NPM_UPDATE}` (npm), `{PYPI_UPDATE}` (PyPI), or Check for Updates in the cmux app"
        ),
    }
}

#[cfg(test)]
mod distribution_tests {
    /// What the binary installs is what `DISTRIBUTION_VERSION` was when this
    /// crate read the stamp itself: a release as stamped, anything else the
    /// workspace crate version.
    #[test]
    fn only_a_release_stamp_is_reported_as_the_release() {
        use super::release_or_workspace;
        assert_eq!(release_or_workspace(Some("0.13.4")), "0.13.4");
        assert_eq!(release_or_workspace(Some("0.0.0-r2.sha-abc")), env!("CARGO_PKG_VERSION"));
        assert_eq!(release_or_workspace(Some("")), env!("CARGO_PKG_VERSION"));
        assert_eq!(release_or_workspace(None), env!("CARGO_PKG_VERSION"));
    }
}
