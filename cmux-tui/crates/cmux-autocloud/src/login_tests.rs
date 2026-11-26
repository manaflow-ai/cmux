#[test]
fn origin_is_scheme_and_host() {
    assert_eq!(super::origin("https://cmux.com/handler/cli-auth-confirm"), "https://cmux.com");
    assert_eq!(super::origin("http://localhost:3000"), "http://localhost:3000");
}

/// Seeded secrets on the wire (cmux_egress::capture) through the login's own client: the
/// polling code rides only in the poll's body and the refresh token only in its
/// `x-stack-refresh-token` header. tests/egress_seeded.json names this test for
/// `cmux_autocloud::login`.
#[tokio::test]
async fn seeded_secrets_ride_only_where_stack_needs_them() {
    use super::cli_sign_in;
    cmux_egress::capture::install().unwrap();
    let polling = "SEEDpollingCode-8a51";
    let refresh = "SEEDrefreshToken-c06d";
    let project = super::Project {
        stack_base_url: "https://api.stack-auth.com".into(),
        project_id: "seeded-project".into(),
        publishable_client_key: "pck_seeded".into(),
    };
    let client = super::client().unwrap();
    super::send(&client, &cli_sign_in::start_request(&project)).await.unwrap();
    super::send(&client, &cli_sign_in::poll_request(&project, polling)).await.unwrap();
    super::send(&client, &cli_sign_in::token_request(&project, refresh)).await.unwrap();
    let sent = cmux_egress::capture::requests_to("api.stack-auth.com");
    assert_eq!(sent.len(), 3, "{sent:?}");
    let places = cmux_egress::capture::leaks(polling);
    assert_eq!(places.len(), 1, "{places:?}");
    assert!(places[0].ends_with("/api/v1/auth/cli/poll: body"), "{places:?}");
    let places = cmux_egress::capture::leaks(refresh);
    assert_eq!(places.len(), 1, "{places:?}");
    assert!(places[0].ends_with(": header x-stack-refresh-token"), "{places:?}");
}
