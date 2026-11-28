//! Where to read a GitHub release asset or archive from on this machine.
//!
//! A Cloud machine's git cache proxy (`cmux host git-cache serve`, crate `cmux-git-cache`)
//! writes [`BASE_FILE`] while it listens and removes it when it stops. For a URL it caches
//! ([`cacheable`]: `github.com/OWNER/REPO/releases/download/...`, `github.com/OWNER/REPO/archive/...`
//! and `codeload.github.com/...`), [`cached_url`] names the same file at the proxy. The proxy
//! answers from its cache when GitHub still names the same bytes (a release asset's id, a
//! codeload archive's ETag), and otherwise redirects to the original URL, so a caller reads
//! identical bytes either way. A caller still tries the original URL itself when the proxied
//! one fails ([`fetch_order`]).
//!
//! Off for one process tree: `CMUX_TRANSPORT_REWRITE=0` ([`SWITCH`], shared with the package
//! manager rewrites). Off on a machine: the proxy is not running, so there is no base file.

use std::path::Path;

/// The switch every transport rewrite shares: `0` turns them off.
pub const SWITCH: &str = "CMUX_TRANSPORT_REWRITE";
/// The proxy's base URL (`http://127.0.0.1:PORT`), present only while it listens.
pub const BASE_FILE: &str = "/run/cmux/git-cache/base";

/// True unless `CMUX_TRANSPORT_REWRITE=0`.
pub fn enabled() -> bool {
    std::env::var(SWITCH).map_or(true, |v| v.trim() != "0")
}

/// The proxy's base URL from `path`, when it names a loopback HTTP listener.
pub fn read_base(path: &Path) -> Option<String> {
    let text = std::fs::read_to_string(path).ok()?;
    let base = text.trim().trim_end_matches('/');
    let port = base.strip_prefix("http://127.0.0.1:")?;
    (!port.is_empty() && port.bytes().all(|b| b.is_ascii_digit())).then(|| base.to_owned())
}

/// `url` without `https://` when it is a GitHub release asset or archive the proxy caches.
pub fn cacheable(url: &str) -> Option<&str> {
    let rest = url.strip_prefix("https://")?;
    if rest.contains(['?', '#']) || rest.split('/').any(|s| s.is_empty() || s == "." || s == "..") {
        return None;
    }
    let mut parts = rest.splitn(5, '/');
    let (host, _owner, _repo, kind, tail) =
        (parts.next()?, parts.next()?, parts.next()?, parts.next()?, parts.next()?);
    let ok = match host {
        "github.com" => {
            (kind == "releases" && tail.starts_with("download/") && tail.matches('/').count() == 2)
                || kind == "archive"
        }
        "codeload.github.com" => {
            matches!(kind, "tar.gz" | "zip" | "legacy.tar.gz" | "legacy.zip")
        }
        _ => false,
    };
    ok.then_some(rest)
}

/// The proxied URL of `url` for a proxy at `base`, if it caches `url`.
pub fn rewrite(url: &str, base: &str) -> Option<String> {
    cacheable(url).map(|rest| format!("{}/{rest}", base.trim_end_matches('/')))
}

/// The proxied URL of `url` on this machine: `None` when the switch is off, no proxy listens
/// or the proxy does not cache `url`.
pub fn cached_url(url: &str) -> Option<String> {
    if !enabled() {
        return None;
    }
    rewrite(url, &read_base(Path::new(BASE_FILE))?)
}

/// The URLs to try in order: the proxied one first (when there is one), then `url` itself.
pub fn fetch_order(url: &str) -> Vec<String> {
    let mut order: Vec<String> = cached_url(url).into_iter().collect();
    order.push(url.to_owned());
    order
}

#[cfg(test)]
#[path = "tests.rs"]
mod tests;
