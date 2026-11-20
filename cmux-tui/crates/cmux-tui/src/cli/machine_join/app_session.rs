//! Match an app-issued token to the platform in the same deployment. Custom platforms
//! take an explicitly supplied credential; never request a token from the app for them.

use std::time::{Duration, Instant};

use cmux_cloud_environment::{DEVELOPMENT_DEPLOYMENT, PRODUCTION_DEPLOYMENT, STAGING_DEPLOYMENT};
use serde_json::Value;

use crate::cli::{GlobalArgs, app, auth_token};

pub(in crate::cli) fn token(
    global: &GlobalArgs,
    platform: &str,
    limit: Duration,
) -> Result<String, String> {
    let end = Instant::now() + limit.min(Duration::from_secs(30));
    checked(platform, || {
        let mut stream = app::connect_command(global).map_err(|_| {
            "not signed in: no cmux app; open cmux or set CMUX_CLOUD_ACCESS_TOKEN".to_owned()
        })?;
        app::request_by(
            &mut stream,
            "auth.token",
            Value::Object(auth_token::request(None)),
            limit,
            Some(end),
        )?
        .map_err(|err| err["message"].as_str().unwrap_or("not signed in").to_owned())
    })
}

fn checked(
    platform: &str,
    request: impl FnOnce() -> Result<Value, String>,
) -> Result<String, String> {
    let deployment = [DEVELOPMENT_DEPLOYMENT, STAGING_DEPLOYMENT, PRODUCTION_DEPLOYMENT]
        .into_iter()
        .find(|d| d.platform_origin == platform)
        .ok_or_else(|| {
            "supply a credential for this custom platform with CMUX_CLOUD_ACCESS_TOKEN".to_owned()
        })?;
    let grant = request()?;
    if grant["api_origin"].as_str().map(|url| url.trim_end_matches('/'))
        != Some(deployment.api_origin)
    {
        return Err("the app sign-in does not match this platform; use the matching app or supply a credential for this platform".into());
    }
    auth_token::token_line(&grant)
        .map(|line| line.trim().to_owned())
        .ok_or_else(|| "the cmux app gave no token".to_owned())
}

#[cfg(test)]
mod tests {
    use super::*;
    use serde_json::json;

    #[test]
    fn a_grant_only_reaches_its_own_platform() {
        let rows = [DEVELOPMENT_DEPLOYMENT, STAGING_DEPLOYMENT, PRODUCTION_DEPLOYMENT];
        for platform in rows {
            for issuer in rows {
                let grant = || Ok(json!({"api_origin":issuer.api_origin, "access_token":"sample"}));
                assert_eq!(
                    checked(platform.platform_origin, grant).is_ok(),
                    platform.api_origin == issuer.api_origin
                );
            }
        }
        assert!(
            checked(PRODUCTION_DEPLOYMENT.platform_origin, || Ok(json!({"access_token":"sample"})))
                .is_err()
        );
        assert!(checked("https://custom.example", || panic!("must not mint")).is_err());
    }
}
