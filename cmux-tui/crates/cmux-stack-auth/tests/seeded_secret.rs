//! Seeded secrets through every call the Stack and cmux account clients make, on the wire
//! (cmux_egress::capture): the refresh token rides only in the token exchange's form body and
//! the refresh header, the access token only in its header or `Authorization`, the email and
//! password only in their sign-in bodies. tests/egress_seeded.json names this test for the
//! `cmux_stack_auth::wire` gate site.

mod fake;

use cmux_egress::capture;
use cmux_stack_auth::{CmuxApi, CmuxApiConfig, Session, StackClient, StackConfig};

const STACK: &str = "api.stack-auth.com";
const CMUX: &str = "cmux.com";

fn only_in(secret: &str, expected: &[&str]) {
    let mut places = capture::leaks(secret);
    places.sort();
    let mut expected: Vec<String> = expected.iter().map(|s| (*s).to_owned()).collect();
    expected.sort();
    assert_eq!(places, expected, "{secret}");
}

#[tokio::test]
async fn each_token_and_address_rides_only_where_its_call_needs_it() {
    capture::install().unwrap();
    let refresh = "SEEDstackRefresh-91c4";
    let access = fake::token(600, 900, "SEEDstackAccessTag-3e7a");
    let password = "SEEDstackPassword-5b20";
    let email = "seed-stack-person-77d1@example.com";
    let code_email = "seed-stack-code-4f0a@example.com";
    let recovery_email = "seed-stack-recover-0c9e@example.com";

    let stack = StackClient::new(StackConfig::new(
        &format!("https://{STACK}"),
        "proj-seeded",
        "pck_seeded",
    ))
    .unwrap();
    let _ = stack.refresh_exchange(refresh).await;
    let _ = stack.sign_in_with_password(email, password).await;
    let _ = stack.send_sign_in_code(code_email, "https://cmux.com/auth/callback").await;
    let mut session = Session::new(Some(&access), Some(refresh));
    let _ = stack.current_user(&mut session).await;

    let api = CmuxApi::new(CmuxApiConfig::new(&format!("https://{CMUX}"))).unwrap();
    let _ = api.request_email_verification(recovery_email).await;
    let _ = api.team_memberships(&Session::new(Some(&access), Some(refresh))).await;

    let stack_sent = capture::requests_to(STACK);
    let cmux_sent = capture::requests_to(CMUX);
    assert!(stack_sent.len() >= 4, "{stack_sent:?}");
    assert_eq!(cmux_sent.len(), 2, "{cmux_sent:?}");

    only_in(
        refresh,
        &[
            "api.stack-auth.com POST /api/v1/auth/oauth/token: body",
            "api.stack-auth.com GET /api/v1/users/me: header x-hexclave-refresh-token",
            "cmux.com GET /api/teams: header x-stack-refresh-token",
        ],
    );
    only_in(
        &access,
        &[
            "api.stack-auth.com GET /api/v1/users/me: header x-hexclave-access-token",
            "cmux.com GET /api/teams: header authorization",
        ],
    );
    // The token's own claims ride inside it and nowhere else.
    only_in(
        "SEEDstackAccessTag-3e7a",
        &[
            "api.stack-auth.com GET /api/v1/users/me: header x-hexclave-access-token",
            "cmux.com GET /api/teams: header authorization",
        ],
    );
    only_in(password, &["api.stack-auth.com POST /api/v1/auth/password/sign-in: body"]);
    only_in(email, &["api.stack-auth.com POST /api/v1/auth/password/sign-in: body"]);
    only_in(code_email, &["api.stack-auth.com POST /api/v1/auth/otp/send-sign-in-code: body"]);
    only_in(recovery_email, &["cmux.com POST /api/auth/email-verification: body"]);
}
