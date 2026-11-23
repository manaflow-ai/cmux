use super::*;

#[test]
fn invite_codes_normalize_like_pairing_codes_and_never_have_a_pairing_code_length() {
    assert_eq!(normalize("abcde-12345").unwrap(), "ABCDE12345");
    assert_eq!(normalize(" ABCDE 1234O ").unwrap(), "ABCDE12340");
    assert_eq!(normalize("abcde-1234l").unwrap(), "ABCDE12341");
    assert_eq!(normalize("abcde-1234i").unwrap(), "ABCDE12341");
    for bad in
        ["7KQ4-M2XD", "ABCDE-1234U", "ABCDE-123456", "ABCDE_12345", "", "A".repeat(65).as_str()]
    {
        let error = normalize(bad).unwrap_err();
        assert_eq!(error.kind, crate::ExitKind::Usage, "{bad}");
        assert_eq!(error.message, "server.pair.invalid_invite");
    }
    assert_eq!(display("ABCDE12345"), "ABCDE-12345");
}

#[test]
fn begin_refusals_for_an_invite_are_named_and_others_stay_generic() {
    use reqwest::StatusCode;
    assert_eq!(super::super::network::invite_refusal(StatusCode::NOT_FOUND), UNKNOWN);
    assert_eq!(super::super::network::invite_refusal(StatusCode::CONFLICT), USED);
    assert_eq!(
        super::super::network::invite_refusal(StatusCode::BAD_REQUEST),
        "server.pair.api_refused"
    );
}

#[test]
fn the_inviter_shown_is_bounded_and_printable() {
    use serde_json::json;
    assert_eq!(inviter(&json!({"inviter":" Leo "})).as_deref(), Some("Leo"));
    assert_eq!(inviter(&json!({"inviter":"a\u{1b}[31mb"})), None);
    assert_eq!(inviter(&json!({"inviter":"x".repeat(121)})), None);
    assert_eq!(inviter(&json!({"inviter":null})), None);
    assert_eq!(inviter(&json!({})), None);
}
