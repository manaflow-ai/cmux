//! Version identity shared by every cmux-tui binary entrypoint.

/// Resolve the version stamped into a distributed binary.
///
/// Release workflows provide `CMUX_TUI_DISTRIBUTION_VERSION`. Local builds do
/// not set it, so they retain the Cargo package version as their fallback.
const fn resolve_distribution_version<'a>(
    stamped_version: Option<&'a str>,
    cargo_version: &'a str,
) -> &'a str {
    match stamped_version {
        Some(version) => version,
        None => cargo_version,
    }
}

/// Canonical version shown by `cmux-tui --version` and `remote-probe`.
///
/// Stable releases use the shared `X.Y.Z` package version. Nightly builds use
/// the npm-form prerelease stamp; the PyPI `.dev...` suffix remains packaging
/// metadata because one binary is shared by both registries.
pub const DISTRIBUTION_VERSION: &str = resolve_distribution_version(
    option_env!("CMUX_TUI_DISTRIBUTION_VERSION"),
    env!("CARGO_PKG_VERSION"),
);

#[cfg(test)]
mod tests {
    use super::resolve_distribution_version;

    #[test]
    fn stable_release_stamp_overrides_the_cargo_crate_version() {
        assert_eq!(resolve_distribution_version(Some("0.11.0"), "0.1.0"), "0.11.0");
    }

    #[test]
    fn nightly_binary_stamp_preserves_the_npm_prerelease_form() {
        let nightly = "0.11.1-nightly.20260817.42";
        assert_eq!(resolve_distribution_version(Some(nightly), "0.1.0"), nightly);
    }

    #[test]
    fn local_builds_fall_back_to_the_cargo_crate_version() {
        assert_eq!(resolve_distribution_version(None, "0.1.0"), "0.1.0");
    }
}
