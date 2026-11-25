//! Just enough URL reading for the configuration rules, without a URL parser
//! (the app FFI links none): an absolute `scheme://authority/path?query#fragment`
//! split into its parts. A string without `://` has no host.

/// An absolute URL's parts. `host` is lowercased, without brackets.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Parts<'a> {
    pub scheme: String,
    pub user: Option<&'a str>,
    pub password: Option<&'a str>,
    pub host: String,
    pub port: Option<&'a str>,
    pub path: &'a str,
    pub query: Option<&'a str>,
    pub fragment: Option<&'a str>,
}

/// The parts of `raw`, or `None` when it is not `scheme://…` with a valid scheme.
pub fn parse(raw: &str) -> Option<Parts<'_>> {
    let (scheme, rest) = raw.split_once("://")?;
    let mut chars = scheme.chars();
    if !chars.next().is_some_and(|c| c.is_ascii_alphabetic())
        || !chars.all(|c| c.is_ascii_alphanumeric() || matches!(c, '+' | '-' | '.'))
    {
        return None;
    }
    let (rest, fragment) = match rest.split_once('#') {
        Some((rest, fragment)) => (rest, Some(fragment)),
        None => (rest, None),
    };
    let (rest, query) = match rest.split_once('?') {
        Some((rest, query)) => (rest, Some(query)),
        None => (rest, None),
    };
    let (authority, path) = match rest.split_once('/') {
        Some((authority, _)) => (authority, rest.strip_prefix(authority).unwrap_or_default()),
        None => (rest, ""),
    };
    let (userinfo, hostport) = match authority.rsplit_once('@') {
        Some((userinfo, hostport)) => (Some(userinfo), hostport),
        None => (None, authority),
    };
    let (user, password) = match userinfo {
        Some(info) => match info.split_once(':') {
            Some((user, password)) => (Some(user), Some(password)),
            None => (Some(info), None),
        },
        None => (None, None),
    };
    let (host, port) = if let Some(bracketed) = hostport.strip_prefix('[') {
        let (host, after) = bracketed.split_once(']')?;
        (host, after.strip_prefix(':'))
    } else {
        match hostport.rsplit_once(':') {
            Some((host, port)) => (host, Some(port)),
            None => (hostport, None),
        }
    };
    Some(Parts {
        scheme: scheme.to_ascii_lowercase(),
        user,
        password,
        host: host.to_ascii_lowercase(),
        port,
        path,
        query,
        fragment,
    })
}

/// The lowercased host of `raw`, `None` when it has none.
pub fn host(raw: &str) -> Option<String> {
    parse(raw).map(|parts| parts.host).filter(|host| !host.is_empty())
}

/// Whether `raw` names this machine (or no host at all, which reaches nothing but this machine).
pub fn is_loopback(raw: &str) -> bool {
    match host(raw) {
        None => true,
        Some(host) => matches!(host.as_str(), "localhost" | "127.0.0.1" | "::1"),
    }
}

/// Whether `raw` is a bare origin: https, a host, and no credentials, port, path, query or fragment.
pub fn is_bare_https_origin(raw: &str) -> bool {
    parse(raw).is_some_and(|parts| {
        parts.scheme == "https"
            && !parts.host.is_empty()
            && parts.user.is_none()
            && parts.password.is_none()
            && parts.port.is_none()
            && (parts.path.is_empty() || parts.path == "/")
            && parts.query.is_none()
            && parts.fragment.is_none()
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn reads_the_parts_of_an_origin() {
        let parts = parse("HTTPS://u:p@Example.COM:8443/a/b?q=1#f").expect("parts");
        assert_eq!(parts.scheme, "https");
        assert_eq!((parts.user, parts.password), (Some("u"), Some("p")));
        assert_eq!(parts.host, "example.com");
        assert_eq!(parts.port, Some("8443"));
        assert_eq!(parts.path, "/a/b");
        assert_eq!((parts.query, parts.fragment), (Some("q=1"), Some("f")));
        assert_eq!(host("http://[::1]:3777"), Some("::1".to_owned()));
        assert_eq!(host("not a url"), None);
        assert!(parse("1x://host").is_none());
    }

    #[test]
    fn loopback_is_this_machine_or_no_host() {
        for url in [
            "http://localhost:3777",
            "http://127.0.0.1",
            "http://[::1]:1",
            "garbage",
            "file:///tmp",
        ] {
            assert!(is_loopback(url), "{url}");
        }
        for url in ["https://cmux.com", "http://127.0.0.2", "https://localhost.example"] {
            assert!(!is_loopback(url), "{url}");
        }
    }

    #[test]
    fn a_bare_origin_has_nothing_but_scheme_and_host() {
        assert!(is_bare_https_origin("https://cloud-api.cmux.dev"));
        assert!(is_bare_https_origin("https://cloud-api.cmux.dev/"));
        for url in [
            "http://cloud-api.cmux.dev",
            "https://cloud-api.cmux.dev:443",
            "https://u@cloud-api.cmux.dev",
            "https://cloud-api.cmux.dev/v1",
            "https://cloud-api.cmux.dev?x",
            "https://cloud-api.cmux.dev#x",
            "https://",
        ] {
            assert!(!is_bare_https_origin(url), "{url}");
        }
    }
}
