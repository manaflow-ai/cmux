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
mod tests {
    use super::*;

    const BASE: &str = "http://127.0.0.1:47380";

    #[test]
    fn rewrites_release_assets_and_archives_only() {
        let asset = "https://github.com/openai/codex/releases/download/rust-v0.156.1/codex.tar.gz";
        assert_eq!(
            rewrite(asset, BASE).unwrap(),
            "http://127.0.0.1:47380/github.com/openai/codex/releases/download/rust-v0.156.1/codex.tar.gz"
        );
        assert!(
            rewrite("https://codeload.github.com/oven-sh/bun/tar.gz/bun-v1.2.0", BASE).is_some()
        );
        assert!(
            rewrite("https://github.com/oven-sh/bun/archive/refs/tags/v1.tar.gz", BASE).is_some()
        );
        for no in [
            "http://github.com/a/b/releases/download/t/f",
            "https://github.com/a/b/releases/download/t",
            "https://github.com/a/b/releases/download/t/f/g",
            "https://github.com/a/b/releases/latest/download/f",
            "https://github.com/a/b.git/info/refs",
            "https://github.com/a/b/releases/download/t/f?x=1",
            "https://github.com/a/../releases/download/t/f",
            "https://api.github.com/repos/a/b/releases/assets/1",
            "https://codeload.github.com/a/b/raw/main",
            "https://example.com/a/b/releases/download/t/f",
        ] {
            assert!(rewrite(no, BASE).is_none(), "{no}");
        }
    }

    #[test]
    fn base_file_must_name_a_loopback_port() {
        let dir =
            std::env::temp_dir().join(format!("cmux-transport-rewrite-{}", std::process::id()));
        std::fs::create_dir_all(&dir).unwrap();
        let file = dir.join("base");
        std::fs::write(&file, "http://127.0.0.1:47380\n").unwrap();
        assert_eq!(read_base(&file).as_deref(), Some(BASE));
        std::fs::write(&file, "http://evil.example:80\n").unwrap();
        assert_eq!(read_base(&file), None);
        std::fs::remove_file(&file).unwrap();
        assert_eq!(read_base(&file), None);
        std::fs::remove_dir(&dir).unwrap();
    }
}
