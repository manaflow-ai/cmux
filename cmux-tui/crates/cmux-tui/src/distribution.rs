//! The version of the npm/PyPI distribution that contains this binary, and
//! the npm version a remote may install (`None`: not published there).
//! Release workflows stamp them independently from the Rust crate's internal
//! version. Only this crate reads them at compile time; cmux-remote takes them
//! as arguments (`SshBootstrapConfig::defaults`), so a new stamp does not
//! recompile it.

pub(crate) const DISTRIBUTION_VERSION: &str = match option_env!("CMUX_TUI_DISTRIBUTION_VERSION") {
    Some(version) => version,
    None => env!("CARGO_PKG_VERSION"),
};
pub(crate) const NPM_BOOTSTRAP_VERSION: Option<&str> =
    option_env!("CMUX_TUI_NPM_BOOTSTRAP_VERSION");
