//! [`url_parts`]: the parts Foundation's `URL` gives the app's URL rules.

use crate::{UrlParts, url_parts};

fn parts(
    scheme: &str,
    host: Option<&str>,
    port: Option<i64>,
    path: &str,
    query: Option<&str>,
) -> UrlParts {
    UrlParts {
        scheme: scheme.into(),
        host: host.map(Into::into),
        port,
        path: path.into(),
        query: query.map(Into::into),
    }
}

#[test]
fn reads_each_part_as_written() {
    assert_eq!(
        url_parts("HTTPS://User@Example.COM:8443/a%20b?x=1&y#frag"),
        Some(parts("HTTPS", Some("Example.COM"), Some(8443), "/a%20b", Some("x=1&y")))
    );
    assert_eq!(url_parts("https://a.org"), Some(parts("https", Some("a.org"), None, "", None)));
    assert_eq!(
        url_parts("http://[::1]:3000/"),
        Some(parts("http", Some("[::1]"), Some(3000), "/", None))
    );
    assert_eq!(
        url_parts("file:///Users/me"),
        Some(parts("file", Some(""), None, "/Users/me", None))
    );
    assert_eq!(url_parts("about:blank"), Some(parts("about", None, None, "blank", None)));
    assert_eq!(
        url_parts("https://a.org/?"),
        Some(parts("https", Some("a.org"), None, "/", Some("")))
    );
}

#[test]
fn encodes_what_url_string_encodes_and_refuses_what_it_refuses() {
    assert_eq!(url_parts("https://a.org/a b").map(|p| p.path), Some("/a%20b".into()));
    assert_eq!(url_parts("no scheme"), None);
    assert_eq!(url_parts("https://a.org:80x/"), None);
}
