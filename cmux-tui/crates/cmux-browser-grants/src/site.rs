//! The site (registrable domain) of a host. Moved here from the browser
//! host's policy so the daemon's grant rows and the host's enforcement
//! name a site the same way.

/// Multi-label public suffixes common enough to matter; any other host is
/// treated as having a one-label suffix. The runtime's compact stand-in
/// (agent-tools.js registrableDomain) until a Public Suffix List lands
/// (port plan D6, a slice S1 proposal).
pub(crate) const MULTI_SUFFIXES: &[&str] = &[
    "co.uk",
    "org.uk",
    "ac.uk",
    "gov.uk",
    "me.uk",
    "ltd.uk",
    "plc.uk",
    "net.uk",
    "co.jp",
    "ne.jp",
    "or.jp",
    "ac.jp",
    "go.jp",
    "co.at",
    "or.at",
    "com.au",
    "net.au",
    "org.au",
    "edu.au",
    "gov.au",
    "co.nz",
    "org.nz",
    "govt.nz",
    "co.in",
    "net.in",
    "org.in",
    "gov.in",
    "ac.in",
    "com.br",
    "net.br",
    "org.br",
    "gov.br",
    "com.cn",
    "net.cn",
    "org.cn",
    "gov.cn",
    "edu.cn",
    "com.hk",
    "org.hk",
    "com.tw",
    "org.tw",
    "co.kr",
    "or.kr",
    "com.sg",
    "edu.sg",
    "com.mx",
    "org.mx",
    "co.za",
    "org.za",
    "com.tr",
    "com.ar",
    "com.co",
    "com.pe",
    "com.my",
    "com.ph",
    "com.vn",
    "co.id",
    "co.il",
    "co.th",
    "com.ua",
    "com.pl",
    "com.es",
    "com.sa",
    "com.eg",
    "com.ng",
    "github.io",
    "gitlab.io",
    "pages.dev",
    "workers.dev",
    "vercel.app",
    "netlify.app",
    "herokuapp.com",
    "web.app",
    "firebaseapp.com",
    "appspot.com",
    "blogspot.com",
    "azurewebsites.net",
    "cloudfront.net",
    "amazonaws.com",
    "s3.amazonaws.com",
    "fly.dev",
    "onrender.com",
    "glitch.me",
    "repl.co",
    "ngrok.io",
    "ngrok-free.app",
    "trycloudflare.com",
];

/// The site (registrable domain) of a host, for cookie scoping and
/// storageState; an IP address, a single label or a bracketed IPv6 address
/// is its own site.
pub fn site_of(host: &str) -> String {
    let h = host.trim_start_matches('.').trim_end_matches('.').to_ascii_lowercase();
    let is_ipv4 = h.split('.').count() == 4
        && h.split('.').all(|l| !l.is_empty() && l.chars().all(|c| c.is_ascii_digit()));
    if h.is_empty() || h.starts_with('[') || is_ipv4 || !h.contains('.') {
        return h;
    }
    let labels: Vec<&str> = h.split('.').collect();
    // `site` is a multi-label suffix plus the one label before it.
    for start in 0..labels.len().saturating_sub(1) {
        let (Some(site), Some(suffix)) =
            (labels.get(start..), labels.get(start.saturating_add(1)..))
        else {
            break;
        };
        if MULTI_SUFFIXES.contains(&suffix.join(".").as_str()) {
            return site.join(".");
        }
    }
    labels
        .get(labels.len().saturating_sub(2)..)
        .map_or_else(|| h.clone(), |last_two| last_two.join("."))
}
