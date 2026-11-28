//! Seeded secrets through the subscription sign-in client (tests/egress_seeded.json, site
//! `acpmux::subscriptions::oauth`): a refresh token rides only in the token and revoke form
//! bodies, an access token only in `authorization`, checked on the wire by cmux-egress's capture.

use super::{Endpoints, OAuth};
use crate::subscriptions::{KimiRegion, Provider, Record};

#[tokio::test(flavor = "multi_thread")]
async fn seeded_tokens_ride_only_in_the_form_body_and_authorization() {
    cmux_egress::capture::install().unwrap();
    let oauth = OAuth::new(Endpoints::default());
    let access = "SEEDoauthAccess-3b9f1c";
    let refresh = "SEEDoauthRefresh-7a02de";
    let record = Record {
        access_token: access.into(),
        refresh_token: refresh.into(),
        expires_at: 0,
        region: Some(KimiRegion::Global),
        device_id: Some("SEEDdevice".into()),
        sub: None,
        login: None,
        email: None,
    };
    // The capture server answers `200 {}`; only what was sent matters here.
    let _ = oauth.refresh(Provider::Grok, &record).await;
    let _ = oauth.refresh(Provider::Kimi, &record).await;
    oauth.revoke_grok(&record).await;
    let _ = oauth.copilot_endpoint(access).await;

    let mut refresh_at = cmux_egress::capture::leaks(refresh);
    refresh_at.sort();
    assert_eq!(
        refresh_at,
        [
            "auth.kimi.ai POST /api/oauth/token: body",
            "auth.x.ai POST /oauth2/revoke: body",
            "auth.x.ai POST /oauth2/token: body",
        ],
    );
    assert_eq!(
        cmux_egress::capture::leaks(access),
        ["api.github.com GET /copilot_internal/user: header authorization"],
    );
}
