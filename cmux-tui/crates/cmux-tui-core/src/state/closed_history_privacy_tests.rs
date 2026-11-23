use super::strip_url;

#[test]
fn strip_url_drops_secret_query_keys_byte_for_byte() {
    assert_eq!(strip_url("https://a.example/p?q=1&token=s"), "https://a.example/p?q=1");
    assert_eq!(strip_url("https://a.example/p?token=s"), "https://a.example/p");
    assert_eq!(strip_url("https://a.example/p?q=a%20b&x"), "https://a.example/p?q=a%20b&x");
}

#[test]
fn strip_url_drops_user_info() {
    assert_eq!(strip_url("https://user:pass@a.example/p"), "https://a.example/p");
    assert_eq!(strip_url("https://user@a.example"), "https://a.example");
    // An `@` in the path is not user info.
    assert_eq!(strip_url("https://a.example/@me"), "https://a.example/@me");
}

#[test]
fn strip_url_drops_secret_fragment_keys() {
    assert_eq!(strip_url("https://a.example/cb#access_token=t&x=1"), "https://a.example/cb#x=1");
    assert_eq!(strip_url("https://a.example/cb#access_token=t"), "https://a.example/cb");
    // A fragment part without a value is an anchor, not a key.
    assert_eq!(strip_url("https://a.example/doc#token"), "https://a.example/doc#token");
    assert_eq!(strip_url("https://a.example/doc#section"), "https://a.example/doc#section");
}

#[test]
fn strip_url_strips_every_part_together() {
    assert_eq!(
        strip_url("https://user:pass@a.example/p?q=1&token=s#access_token=t&x=1"),
        "https://a.example/p?q=1#x=1"
    );
}

#[test]
fn strip_url_drops_secret_keys_of_a_hash_route_query() {
    // A single-page app's route keeps its query in the fragment.
    assert_eq!(strip_url("https://h/#/cb?code=abc"), "https://h/#/cb");
    assert_eq!(strip_url("https://h/#/cb?code=abc&x=1"), "https://h/#/cb?x=1");
    assert_eq!(strip_url("https://h/#/cb?x=1&state=s"), "https://h/#/cb?x=1&state=s");
    assert_eq!(strip_url("https://h/#!/cb?access_token=t"), "https://h/#!/cb");
    assert_eq!(strip_url("https://h/#!/cb?code=x"), "https://h/#!/cb");
}

#[test]
fn strip_url_reads_a_fragment_that_is_not_a_route_as_keys_even_with_a_question_mark() {
    // An OAuth fragment whose value holds a `?` is not a hash route.
    assert_eq!(
        strip_url("https://h/cb#access_token=abc&redirect=https://x/?a=b"),
        "https://h/cb#redirect=https://x/?a=b"
    );
    assert_eq!(strip_url("https://h/cb#token=abc?x"), "https://h/cb");
    assert_eq!(strip_url("https://h/doc#section?x=1"), "https://h/doc#section?x=1");
}

#[test]
fn strip_url_reads_the_pairs_after_a_question_mark_in_a_fragment() {
    assert_eq!(strip_url("https://h/p#login?code=xyz"), "https://h/p#login");
    assert_eq!(strip_url("https://h/p#section?token=abc"), "https://h/p#section");
    assert_eq!(strip_url("https://h/p#cb?code="), "https://h/p#cb");
    assert_eq!(strip_url("https://h/p#?code=xyz"), "https://h/p");
}

#[test]
fn strip_url_drops_session_ids_from_the_query_path_and_route() {
    assert_eq!(strip_url("https://h/p?jsessionid=X&a=1"), "https://h/p?a=1");
    assert_eq!(strip_url("https://h/p;jsessionid=X"), "https://h/p");
    assert_eq!(strip_url("https://h/p;jsessionid=X;v=1/q"), "https://h/p;v=1/q");
    assert_eq!(strip_url("https://h/p;JSESSIONID=X?a=1"), "https://h/p?a=1");
    assert_eq!(strip_url("https://h/#/path;jsessionid=X"), "https://h/#/path");
    assert_eq!(strip_url("https://h/#/path;jsessionid=X?x=1"), "https://h/#/path?x=1");
    // A matrix parameter that is not a secret stays.
    assert_eq!(strip_url("https://h/p;v=1/q"), "https://h/p;v=1/q");
}

#[test]
fn strip_url_catches_run_together_and_upper_case_secret_keys() {
    for key in ["accesstoken", "ACCESSTOKEN", "idtoken", "authtoken", "refreshtoken"] {
        assert_eq!(strip_url(&format!("https://h/p?{key}=s&a=1")), "https://h/p?a=1", "{key}");
    }
    for key in ["code_verifier", "oauth_verifier", "SAMLResponse", "session"] {
        assert_eq!(strip_url(&format!("https://h/p?{key}=s&a=1")), "https://h/p?a=1", "{key}");
    }
    // Page cursors and OAuth `state` are not credentials.
    for key in ["pagetoken", "next_page_token", "state"] {
        let url = format!("https://h/p?{key}=s&a=1");
        assert_eq!(strip_url(&url), url, "{key}");
    }
}

#[test]
fn strip_url_strips_one_level_into_an_encoded_redirect() {
    assert_eq!(
        strip_url("https://h/login?redirect=https%3A%2F%2Fx%2Fcb%3Ftoken%3Ds%26a%3D1&b=2"),
        "https://h/login?redirect=https%3A%2F%2Fx%2Fcb%3Fa%3D1&b=2"
    );
    assert_eq!(
        strip_url("https://h/login?return_to=https%3A%2F%2Fu%3Ap%40x%2F"),
        "https://h/login?return_to=https%3A%2F%2Fx%2F"
    );
    // A redirect with nothing to strip stays byte for byte.
    let url = "https://h/login?next=https%3a%2f%2fx%2f%3fa%3d1";
    assert_eq!(strip_url(url), url);
}

#[test]
fn strip_url_treats_a_semicolon_as_a_query_separator() {
    assert_eq!(strip_url("https://h/p?a=1;token=x"), "https://h/p?a=1");
    assert_eq!(strip_url("https://h/p?token=x;a=1&b=2"), "https://h/p?a=1&b=2");
    assert_eq!(strip_url("https://h/p?a=1;b=2&c=3"), "https://h/p?a=1;b=2&c=3");
}

#[test]
fn strip_url_drops_user_info_without_slashes() {
    // Browsers read `https:user:pass@h/p` as `https://user:pass@h/p`.
    assert_eq!(strip_url("https:user:pass@h/p"), "https:h/p");
    assert_eq!(strip_url("https:/user@h/p"), "https:/h/p");
    assert_eq!(strip_url("https:\\\\user:pass@h/p"), "https:\\\\h/p");
    assert_eq!(strip_url("https:h/@me"), "https:h/@me");
}

#[test]
fn strip_url_leaves_non_web_urls_alone() {
    assert_eq!(strip_url("file:///tmp/a?token=s"), "file:///tmp/a?token=s");
    assert_eq!(strip_url("cmux://history#access_token=t"), "cmux://history#access_token=t");
}
