#[test]
fn origin_is_scheme_and_host() {
    assert_eq!(super::origin("https://cmux.com/handler/cli-auth-confirm"), "https://cmux.com");
    assert_eq!(super::origin("http://localhost:3000"), "http://localhost:3000");
}
