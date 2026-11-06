//! Each environment's two origins, from `cmux-cloud-environment`'s deployment
//! rows (the ones the guest host and the conversations client already use):
//!
//! - the platform origin serves cmux-platform's HttpApi routes, the ones the
//!   generated [`crate::Client`] calls (`/v1/machines/...`, join tokens,
//!   client config);
//! - the owner API (`cloud-api.cmux.dev`) serves the `cmux.wire/1` ops
//!   ([`crate::ops`]) and the hand-routed `/v1/cloud/...` paths, which it
//!   forwards to the same platform Worker (`PLATFORM_SURFACES=cloud`).
//!
//! The plan folds both into one origin per environment (T1); until then a
//! caller picks by route, not by guess.

use cmux_cloud_environment as env;

/// A NEXT Cloud environment.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub enum Backend {
    Production,
    Staging,
    Development,
}

impl Backend {
    /// Reads `production`/`prod`, `staging`, `development`/`dev`.
    pub fn parse(name: &str) -> Option<Self> {
        match name.trim().to_ascii_lowercase().as_str() {
            "production" | "prod" => Some(Self::Production),
            "staging" => Some(Self::Staging),
            "development" | "dev" => Some(Self::Development),
            _ => None,
        }
    }

    /// The name [`Self::parse`] reads back.
    pub fn name(self) -> &'static str {
        match self {
            Self::Production => "production",
            Self::Staging => "staging",
            Self::Development => "development",
        }
    }

    /// cmux-platform's own origin (the HttpApi routes).
    pub const fn platform(self) -> &'static str {
        match self {
            Self::Production => env::PRODUCTION_PLATFORM,
            Self::Staging => env::STAGING_PLATFORM,
            Self::Development => env::DEVELOPMENT_PLATFORM,
        }
    }

    /// The owner API (the `cmux.wire/1` ops and `/v1/cloud/...`).
    pub const fn owner_api(self) -> &'static str {
        match self {
            Self::Production => env::PRODUCTION_API,
            Self::Staging => env::STAGING_API,
            Self::Development => env::DEVELOPMENT_API,
        }
    }

    /// Which backend `platform_origin` is, when it is one of the three.
    pub fn of_platform(platform_origin: &str) -> Option<Self> {
        let origin = platform_origin.trim_end_matches('/');
        [Self::Production, Self::Staging, Self::Development]
            .into_iter()
            .find(|b| b.platform() == origin)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn names_round_trip_and_origins_are_bare_https() {
        for b in [Backend::Production, Backend::Staging, Backend::Development] {
            assert_eq!(Backend::parse(b.name()), Some(b));
            assert_eq!(Backend::of_platform(b.platform()), Some(b));
            for origin in [b.platform(), b.owner_api()] {
                assert!(cmux_cloud_config::origin::is_bare_https_origin(origin), "{origin}");
            }
        }
        assert_eq!(Backend::parse("prod"), Some(Backend::Production));
        assert_eq!(Backend::parse("moon"), None);
    }
}
