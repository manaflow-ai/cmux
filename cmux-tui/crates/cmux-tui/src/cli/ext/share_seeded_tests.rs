//! Seeded secrets through `cmux ext search` on the wire (cmux_egress::capture): the person's
//! GitHub token rides only in `Authorization`, and the words they search for only in the query.
//! tests/egress_seeded.json names this test for the `cmux_tui::cli::ext::share` gate site.

use cmux_egress::capture;

use super::search_as;

const HOST: &str = "api.github.com";

#[test]
fn the_github_token_rides_only_in_authorization_and_the_words_only_in_the_query() {
    let _ = rustls::crypto::ring::default_provider().install_default();
    capture::install().unwrap();
    let token = "SEEDextSearchGithubToken-5c21";
    let words = "SEEDextSearchWords-9d07";
    let runtime = tokio::runtime::Builder::new_current_thread().enable_all().build().unwrap();
    let answer = runtime.block_on(search_as(Some(words), Some(token)));
    assert!(answer.is_ok(), "{answer:?}");
    let sent: Vec<_> = capture::requests_to(HOST)
        .into_iter()
        .filter(|request| request.target.contains(words))
        .collect();
    assert_eq!(sent.len(), 1, "{sent:?}");
    assert!(sent[0].target.starts_with("/search/repositories?"), "{sent:?}");
    assert_eq!(capture::leaks(token).len(), 1, "{:?}", capture::leaks(token));
    assert!(
        capture::leaks(token)[0].ends_with(": header authorization"),
        "{:?}",
        capture::leaks(token)
    );
    assert_eq!(capture::leaks(words).len(), 1, "{:?}", capture::leaks(words));
    assert!(capture::leaks(words)[0].ends_with(": target"), "{:?}", capture::leaks(words));
}
