//! `embed` panes (plans/cmux-next/extensions/DESIGN.md section 5, roadmap
//! step 5): a `cmux.pane/1` implementation `{"embed": {"url", "origins"}}` is
//! an external web app (a design tool, a tracker) in the browser engine with
//! a profile of this app only, so sign-in and cookies work and never mix with
//! the person's browser profile or another app's.
//!
//! Rust owns every decision; the Mac client only creates the web view on the
//! data store named by [`EmbedPage::profile`] and cancels a navigation that
//! [`embed_allows`] refuses:
//! - which implementations are embeds, their url and allowed origins
//!   ([`embed_pages`]); the url's own origin is always allowed;
//! - the rules ([`check`]): `cmux.pane/1` only, https, a public host, no
//!   port or credentials, `*.` only as a whole leading label;
//! - the profile id, one per app id and stable across installs and
//!   updates ([`embed_profile_id`]).

use serde_json::Value;
use sha2::{Digest, Sha256};

use crate::issue::{Issue, escape};
use crate::module_store::is_public_host;

/// The only interface an embed may implement.
pub const EMBED_INTERFACE: &str = "cmux.pane/1";

/// Domain separation for [`embed_profile_id`]: changing it would sign every
/// person out of every embedded app.
const PROFILE_NAMESPACE: &[u8] = b"cmux.embed-profile/1\0";

/// One embedded web app an app implements.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct EmbedPage {
    /// The interface it implements (always `cmux.pane/1`).
    pub interface: String,
    /// The page the pane opens first.
    pub url: String,
    /// Where the pane may navigate: the url's own origin first, then the
    /// declared ones, lowercased, without duplicates (`https://a.com`,
    /// `https://*.a.com`).
    pub origins: Vec<String>,
    /// The browser profile: a lowercase UUID derived from the app id only.
    pub profile: String,
    pub symbol: Option<String>,
}

/// The browser profile of app `id`'s embeds: a UUID (RFC 9562 version 8)
/// from SHA-256 of the app id, so the same app keeps its sign-in across
/// reinstalls and updates, and two apps never share one.
pub fn embed_profile_id(app_id: &str) -> String {
    let mut hasher = Sha256::new();
    hasher.update(PROFILE_NAMESPACE);
    hasher.update(app_id.as_bytes());
    let digest = hasher.finalize();
    let mut b = [0u8; 16];
    b.copy_from_slice(&digest[..16]);
    b[6] = (b[6] & 0x0f) | 0x80;
    b[8] = (b[8] & 0x3f) | 0x80;
    let h = hex::encode(b);
    format!("{}-{}-{}-{}-{}", &h[0..8], &h[8..12], &h[12..16], &h[16..20], &h[20..32])
}

/// Every valid `embed` implementation of a manifest. One that breaks a rule
/// of [`check`] is left out (the validator reports it; a client never opens it).
pub fn embed_pages(manifest: &Value) -> Vec<EmbedPage> {
    let Some(implements) = manifest["implements"].as_object() else { return Vec::new() };
    let id = manifest["id"].as_str().unwrap_or_default();
    implements
        .iter()
        .filter(|(interface, _)| interface.as_str() == EMBED_INTERFACE)
        .filter_map(|(interface, imp)| {
            let embed = imp.get("embed")?;
            let (url, origins) = resolve(embed).ok()?;
            Some(EmbedPage {
                interface: interface.clone(),
                url,
                origins,
                profile: embed_profile_id(id),
                symbol: imp.get("symbol").and_then(Value::as_str).map(str::to_string),
            })
        })
        .collect()
}

/// Whether an embed with allowed `origins` (as [`EmbedPage::origins`]) may
/// navigate to `url`: https on the default port, no credentials, and a host
/// equal to an allowed origin's, or under a `*.` origin's domain.
pub fn embed_allows(origins: &[String], url: &str) -> bool {
    let Ok(host) = url_host(url) else { return false };
    origins.iter().any(|origin| {
        let Some(allowed) = origin.strip_prefix("https://") else { return false };
        match allowed.strip_prefix("*.") {
            Some(domain) => host.len() > domain.len() + 1 && host.ends_with(&format!(".{domain}")),
            None => host == allowed,
        }
    })
}

/// Validator rules for embeds (called from `rules::check`).
pub(crate) fn check(m: &Value, out: &mut Vec<Issue>) {
    for (name, imp) in m["implements"].as_object().into_iter().flatten() {
        let Some(embed) = imp.get("embed") else { continue };
        let at = format!("/implements/{}/embed", escape(name));
        if name != EMBED_INTERFACE {
            out.push(Issue::error(
                &at,
                "embed.interface",
                format!("an embed implements {EMBED_INTERFACE} only, not {name}"),
            ));
            continue;
        }
        if let Err((path, message)) = resolve(embed) {
            out.push(Issue::error(format!("{at}{path}"), "embed.origin", message));
        }
    }
}

/// The url and the allowed origins of an `embed` object, or the first
/// refused field (a JSON pointer under the object) and why.
fn resolve(embed: &Value) -> Result<(String, Vec<String>), (String, String)> {
    let url = embed["url"].as_str().ok_or(("/url".to_string(), "no url".to_string()))?;
    let host = url_host(url).map_err(|m| ("/url".to_string(), m))?;
    let mut origins = vec![format!("https://{host}")];
    for (i, value) in embed["origins"].as_array().into_iter().flatten().enumerate() {
        let origin = value
            .as_str()
            .ok_or_else(|| "an origin is not a string".to_string())
            .and_then(origin_pattern)
            .map_err(|m| (format!("/origins/{i}"), m))?;
        if !origins.contains(&origin) {
            origins.push(origin);
        }
    }
    Ok((url.to_string(), origins))
}

/// `https://host` or `https://*.host`, normalized, or why it is refused.
fn origin_pattern(origin: &str) -> Result<String, String> {
    let rest =
        origin.strip_prefix("https://").ok_or(format!("{origin:?} is not an https origin"))?;
    let (wild, host) = match rest.strip_prefix("*.") {
        Some(host) => ("*.", host),
        None => ("", rest),
    };
    if host.contains(['/', '*', '@', ':', '?', '#']) {
        return Err(format!("{origin:?} must be https:// and a host only (no path, port or *)"));
    }
    if !is_public_host(host) {
        return Err(format!("{host:?} is not a public host name"));
    }
    Ok(format!("https://{wild}{}", host.to_ascii_lowercase()))
}

/// The lowercased host of an https URL with no credentials and no port but
/// 443, or why it is refused.
fn url_host(url: &str) -> Result<String, String> {
    let scheme_end = url.find("://").ok_or(format!("{url:?} is not a URL"))?;
    if !url[..scheme_end].eq_ignore_ascii_case("https") {
        return Err(format!("{url:?} is not https"));
    }
    let rest = &url[scheme_end + 3..];
    let authority = rest.split(['/', '?', '#']).next().unwrap_or_default();
    if authority.contains('@') {
        return Err(format!("{url:?} carries credentials"));
    }
    let host = match authority.rsplit_once(':') {
        Some((host, "443")) => host,
        Some(_) => return Err(format!("{url:?} names a port")),
        None => authority,
    };
    if !is_public_host(host) {
        return Err(format!("{host:?} is not a public host name"));
    }
    Ok(host.to_ascii_lowercase())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn profile_ids_are_uuids_per_app() {
        let a = embed_profile_id("octo/figma");
        assert_eq!(a, embed_profile_id("octo/figma"));
        assert_ne!(a, embed_profile_id("octo/linear"));
        assert_eq!(a.len(), 36);
        assert_eq!(&a[14..15], "8", "version 8: {a}");
        assert!(matches!(&a[19..20], "8" | "9" | "a" | "b"), "variant: {a}");
    }

    #[test]
    fn hosts_refuse_ports_credentials_and_local_names() {
        assert_eq!(url_host("https://Figma.com/file/x?y#z").unwrap(), "figma.com");
        assert_eq!(url_host("https://figma.com:443").unwrap(), "figma.com");
        for bad in [
            "http://figma.com",
            "https://figma.com:8443/",
            "https://u:p@figma.com/",
            "https://localhost/",
            "https://10.0.0.1/",
        ] {
            assert!(url_host(bad).is_err(), "{bad}");
        }
    }
}
