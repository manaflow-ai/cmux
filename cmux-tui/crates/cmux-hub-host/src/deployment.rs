//! Which device hub serves a machine join: the one of the deployment its credential came from.
//! A machine credential (acpmux's `machine-credential.json`) names the platform that issued it
//! (`hub_origin`), and only that deployment's device hub signs it in (`POST /v1/auth/machine`).
//! The acpmux daemon and `cmux-rd linux-host` both pick the hub here, from the credential they
//! read, so a credential is never sent to another deployment's hub (review F2 of #45480).
//!
//! The table mirrors `cmux-cloud-environment`'s deployments (that crate needs an HTTP client,
//! which cmux-rd does not link); acpmux's `share_host` tests check the two agree.

/// The platform origin of each deployment, with its device hub.
pub const DEVICE_HUBS: [(&str, &str); 4] = [
    (
        "https://cmux-platform-production.debussy.workers.dev",
        "https://cmux-device-hub.debussy.workers.dev",
    ),
    (
        "https://cmux-platform-staging.debussy.workers.dev",
        "https://cmux-device-hub-dev.debussy.workers.dev",
    ),
    (
        "https://cmux-platform-development.debussy.workers.dev",
        "https://cmux-device-hub-dev.debussy.workers.dev",
    ),
    ("http://localhost:8788", "http://localhost:8791"),
];

/// The device hub of the deployment whose platform is `platform_origin`, or None when no
/// deployment has that platform.
pub fn device_hub_of(platform_origin: &str) -> Option<&'static str> {
    let origin = platform_origin.trim().trim_end_matches('/');
    DEVICE_HUBS.iter().find(|(platform, _)| *platform == origin).map(|(_, hub)| *hub)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn each_platform_has_its_own_deployments_hub() {
        assert_eq!(
            device_hub_of("https://cmux-platform-production.debussy.workers.dev/"),
            Some("https://cmux-device-hub.debussy.workers.dev")
        );
        assert_eq!(
            device_hub_of(" https://cmux-platform-development.debussy.workers.dev"),
            Some("https://cmux-device-hub-dev.debussy.workers.dev")
        );
        for unknown in ["", "https://evil.example", "http://127.0.0.1:1"] {
            assert_eq!(device_hub_of(unknown), None, "{unknown}");
        }
    }
}
