//! The release a binary belongs to and how it was installed, shared by
//! `cmux --version`, the daemon's `identify` and every handshake refusal
//! (plans/cmux-next/tui-tester-rollout.md, msg 2785): a refusal names the
//! exact update command for the side that is too old.

use std::path::{Component, Path};

/// The npm/PyPI release that contains this binary. Anything else (a local or
/// test build, or a raw R2 tree artifact stamped `0.0.0-r2.sha-…` that the
/// app bundles) reports the one cmux-next version, the workspace crate
/// version, which `scripts/cmux-next/check-version-surfaces.sh` requires.
pub const DISTRIBUTION_VERSION: &str = match option_env!("CMUX_TUI_DISTRIBUTION_VERSION") {
    Some(version) if is_release(version) => version,
    _ => env!("CARGO_PKG_VERSION"),
};

/// A release version: not empty and not a `0.0.0-…` placeholder stamp.
pub const fn is_release(version: &str) -> bool {
    !matches!(version.as_bytes(), [] | [b'0', b'.', b'0', b'.', b'0', b'-', ..])
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
