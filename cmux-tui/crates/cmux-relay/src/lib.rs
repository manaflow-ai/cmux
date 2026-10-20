//! Opaque WebSocket circuit relay for cmux remote sessions.

mod admission;
mod config;
mod relay;
mod ticket;

pub use admission::AdmissionListener;
pub use config::{ConfigError, RelayCommand, RelayConfig};
pub use relay::{HealthSnapshot, Relay};
pub use ticket::{TicketAuthority, TicketError};

pub fn version_string() -> String {
    let commit = option_env!("CMUX_TUI_BUILD_COMMIT")
        .filter(|commit| !commit.is_empty())
        .unwrap_or("unstamped");
    format!("{} ({commit})", env!("CARGO_PKG_VERSION"))
}

#[cfg(test)]
mod build_info_tests {
    #[test]
    fn relay_version_identifies_the_package_and_build() {
        let version = super::version_string();
        assert!(version.starts_with(env!("CARGO_PKG_VERSION")));
        assert!(version.ends_with(')'));
    }
}
