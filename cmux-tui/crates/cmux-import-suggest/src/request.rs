//! A request, raised by an agent, to bring one site's sign-in over from a browser
//! (`ImportRequest`), and the site check that keeps such a request to one real site.

use serde::{Deserialize, Serialize};
use unicode_segmentation::UnicodeSegmentation;

/// The longest reason a request keeps, in characters (grapheme clusters, as Swift counts).
pub const MAXIMUM_REASON_LENGTH: usize = 280;

/// One agent's ask for a site's cookies.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Request {
    /// The browser's raw id (`chrome`).
    pub browser: String,
    pub site: String,
    pub reason: String,
    /// Milliseconds since 1970, as `JSONEncoder.importJobs` writes dates.
    pub requested_at: f64,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub raised_by: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub agent_session: Option<String>,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub terminal: Option<String>,
}

impl Request {
    /// A request whose reason is trimmed and cut to [`MAXIMUM_REASON_LENGTH`].
    pub fn new(
        browser: impl Into<String>,
        site: impl Into<String>,
        reason: &str,
        requested_at: f64,
    ) -> Self {
        Request {
            browser: browser.into(),
            site: site.into(),
            reason: clip_reason(reason),
            requested_at,
            raised_by: None,
            agent_session: None,
            terminal: None,
        }
    }

    /// `request.cookies.<browser>.<site>`.
    pub fn id(&self) -> String {
        format!("request.cookies.{}.{}", self.browser, self.site)
    }
}

/// The reason as a request keeps it: trimmed, then its first 280 characters.
pub fn clip_reason(reason: &str) -> String {
    reason.trim().graphemes(true).take(MAXIMUM_REASON_LENGTH).collect()
}

/// The one site a request names, or nil when the text is not one registrable site: a host
/// (from a URL or as typed), lowercased, without a leading dot, made of letters, digits, dots
/// and dashes, and never a public suffix like `co.uk` or `github.io`.
pub fn site(text: &str) -> Option<String> {
    let mut host = text.trim().to_lowercase();
    if host.contains("://")
        && let Some(parsed) = url_host(&host)
    {
        host = parsed;
    }
    if let Some(rest) = host.strip_prefix('.') {
        host = rest.to_owned();
    }
    let allowed = |c: char| c.is_ascii_lowercase() || c.is_ascii_digit() || c == '.' || c == '-';
    let ok = host.chars().count() <= 253
        && host.contains('.')
        && !host.starts_with('-')
        && !host.ends_with('.')
        && !host.contains("..")
        && host.chars().all(allowed)
        && !is_public_suffix(&host);
    ok.then_some(host)
}

/// The host of a `scheme://` URL, as `URL(string:)?.host` reads it: after the scheme, before
/// the path, query or fragment, past any user info and without a port. Nil when it is empty.
fn url_host(text: &str) -> Option<String> {
    let (_, rest) = text.split_once("://")?;
    let authority = rest.split(['/', '?', '#']).next().unwrap_or("");
    let authority = authority.rsplit_once('@').map_or(authority, |(_, host)| host);
    let host = match authority.rsplit_once(':') {
        Some((host, port)) if port.chars().all(|c| c.is_ascii_digit()) => host,
        _ => authority,
    };
    (!host.is_empty()).then(|| host.to_owned())
}

const COUNTRY_SECOND_LEVELS: [&str; 22] = [
    "ac", "co", "com", "edu", "go", "gob", "gov", "gv", "ltd", "me", "mil", "ne", "net", "nhs",
    "nic", "nom", "or", "org", "plc", "sch", "info", "biz",
];

const SHARED_HOSTING_SUFFIXES: [&str; 21] = [
    "amazonaws.com",
    "appspot.com",
    "azurewebsites.net",
    "blogspot.com",
    "cloudfront.net",
    "firebaseapp.com",
    "fly.dev",
    "github.io",
    "gitlab.io",
    "glitch.me",
    "herokuapp.com",
    "myshopify.com",
    "netlify.app",
    "ngrok-free.app",
    "ngrok.io",
    "onrender.com",
    "pages.dev",
    "repl.co",
    "vercel.app",
    "web.app",
    "workers.dev",
];

/// A host no one site owns: an IPv4 address, a two-part country suffix (`co.uk`), or a shared
/// host's suffix (`github.io`). Not the whole public suffix list: the common ones people meet.
pub fn is_public_suffix(host: &str) -> bool {
    let labels: Vec<&str> = host.split('.').collect();
    let Some(last) = labels.last() else { return true };
    if last.chars().all(char::is_numeric) {
        return true;
    }
    if labels.len() == 2 && last.chars().count() == 2 && COUNTRY_SECOND_LEVELS.contains(&labels[0])
    {
        return true;
    }
    SHARED_HOSTING_SUFFIXES.contains(&host)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn sites_people_type_are_kept() {
        assert_eq!(site("bbc.co.uk").as_deref(), Some("bbc.co.uk"));
        assert_eq!(site("https://Someone.GitHub.io/x").as_deref(), Some("someone.github.io"));
        assert_eq!(site("go.dev").as_deref(), Some("go.dev"));
        assert_eq!(site("accounts.google.com").as_deref(), Some("accounts.google.com"));
        assert_eq!(site(" linear.app ").as_deref(), Some("linear.app"));
        assert_eq!(site(".example.com").as_deref(), Some("example.com"));
        assert_eq!(site("https://me@example.com:8443/a?b#c").as_deref(), Some("example.com"));
    }

    #[test]
    fn what_is_not_one_site_is_refused() {
        for text in ["", "localhost", "github.com/../x", "a b.com", "-x.com", "x..com", "x.com."] {
            assert_eq!(site(text), None, "{text}");
        }
        let long = format!("{}.com", "a".repeat(250));
        assert_eq!(site(&long), None);
    }

    #[test]
    fn public_suffixes_are_refused() {
        for text in [
            "co.uk",
            "CO.UK",
            ".com.au",
            "https://ne.jp/login",
            "gov.br",
            "github.io",
            "vercel.app",
            "10.0.0.1",
            "192.168.1.20",
        ] {
            assert_eq!(site(text), None, "{text}");
        }
    }

    #[test]
    fn a_reason_is_trimmed_and_clipped() {
        let request = Request::new("chrome", "x.com", &format!("  {}  ", "é".repeat(300)), 0.0);
        assert_eq!(request.reason.chars().count(), 280);
        assert_eq!(request.id(), "request.cookies.chrome.x.com");
        assert_eq!(clip_reason("  why \n"), "why");
    }
}
