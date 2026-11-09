//! The preview's browser URL (moved from the app's CloudLivePreviewTests).

use super::*;

const BOOTSTRAP: &str = "https://preview.standin.invalid/__cmux/open?token=temporary";

#[test]
fn the_root_opens_the_bootstrap_url_as_it_is() {
    assert_eq!(browser_url(BOOTSTRAP, "/").as_deref(), Some(BOOTSTRAP));
}

#[test]
fn a_path_keeps_the_bootstrap_and_its_token() {
    let opened = browser_url(BOOTSTRAP, "/docs?q=a&sort=up#part").unwrap();
    assert_eq!(
        opened,
        "https://preview.standin.invalid/__cmux/open?token=temporary&return_to=/docs%3Fq%3Da%26sort%3Dup%23part"
    );
    // An earlier return_to is replaced, not repeated.
    let again = browser_url(&opened, "/b").unwrap();
    assert_eq!(again, "https://preview.standin.invalid/__cmux/open?token=temporary&return_to=/b");
    assert_eq!(browser_url("https://p.invalid", "/x").unwrap(), "https://p.invalid?return_to=/x");
    assert_eq!(
        browser_url("https://p.invalid:8443/o#f", "/x").unwrap(),
        "https://p.invalid:8443/o?return_to=/x#f"
    );
}

#[test]
fn a_preview_never_opens_an_insecure_or_credential_bearing_url() {
    for url in [
        "http://preview.standin.invalid/",
        "https://user:secret@preview.standin.invalid/",
        "file:///tmp/a",
        "https:///x",
        "https://a b/",
    ] {
        assert_eq!(browser_url(url, "/"), None, "{url}");
    }
}
