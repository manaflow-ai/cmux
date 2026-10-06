//! `cookies.clear`, scoped as in the app (driver-protocol.md): the target
//! tab's site (registrable domain), narrowed by exact name, domain and path.
//! `{ all: true }` and a tab with no site are refused: the cmux backends
//! share goldens with the app, whose tabs use the person's profile.

use super::driver::{INTERNAL_TIMEOUT, Inner};
use crate::protocol::DriverError;
use serde_json::{Value, json};

/// Whether a cookie's Domain belongs to `site` (the site or a subdomain).
pub(super) fn on_site(domain: &str, site: &str) -> bool {
    let host = domain.trim_start_matches('.').to_ascii_lowercase();
    host == site || host.ends_with(&format!(".{site}"))
}

impl Inner {
    /// The `Storage.*Cookies` scope of a cookies call: the named tab's
    /// browser context, else the store the session engine named
    /// (`browserContextId`, the session's proxy store), else the default.
    pub(super) fn cookie_store(&self, params: &Value) -> Value {
        let tab_context = params
            .get("targetId")
            .and_then(Value::as_str)
            .and_then(|target| self.lock().tabs.get(target).and_then(|tab| tab.context.clone()));
        let context = match params.get("targetId") {
            Some(_) => tab_context,
            None => params["browserContextId"].as_str().map(str::to_owned),
        };
        let proxy = context.filter(|context| {
            self.proxy_contexts
                .lock()
                .unwrap_or_else(std::sync::PoisonError::into_inner)
                .contains(context)
        });
        match proxy {
            Some(context) => json!({"browserContextId": context}),
            None => json!({}),
        }
    }

    pub(super) fn cookies_clear(&self, params: &Value) -> Result<Value, DriverError> {
        if params.get("all").and_then(Value::as_bool) == Some(true) {
            return Err(DriverError::invalid(
                "cookies.clear: { all: true } would clear every site in the user's browser profile, which a session may not do; clear the current tab's site instead (a private tab's store, or one from session.configure({ proxy }), may be cleared whole)",
            ));
        }
        let session = self.session(params)?;
        let url =
            self.lock().tabs.get(&session.target_id).map(|tab| tab.url.clone()).unwrap_or_default();
        let site = url::Url::parse(&url)
            .ok()
            .filter(|u| matches!(u.scheme(), "http" | "https"))
            .and_then(|u| u.host_str().map(crate::policy::site_of));
        let Some(site) = site else {
            let shown = if url.is_empty() { "none" } else { url.as_str() };
            return Err(DriverError::invalid(format!(
                "cookies.clear: the tab ({shown}) has no site to scope to; open the site first"
            )));
        };
        let text = |name: &str| params.get(name).and_then(Value::as_str).filter(|s| !s.is_empty());
        let (name, domain, path) = (text("name"), text("domain"), text("path"));
        let cookies = self.conn.call(
            None,
            "Storage.getCookies",
            self.cookie_store(params),
            INTERNAL_TIMEOUT,
        )?;
        for cookie in cookies["cookies"].as_array().into_iter().flatten() {
            let field = |key: &str| cookie[key].as_str().unwrap_or("");
            if !on_site(field("domain"), &site)
                || name.is_some_and(|n| n != field("name"))
                || domain.is_some_and(|d| d != field("domain"))
                || path.is_some_and(|p| p != field("path"))
            {
                continue;
            }
            self.send(
                &session,
                "Network.deleteCookies",
                json!({"name": field("name"), "domain": field("domain"), "path": field("path")}),
            )?;
        }
        Ok(Value::Null)
    }
}

#[cfg(test)]
mod tests {
    use super::on_site;

    #[test]
    fn cookie_domains_belong_to_their_site_and_its_subdomains() {
        assert!(on_site(".example.com", "example.com"));
        assert!(on_site("a.Example.com", "example.com"));
        assert!(on_site("example.com", "example.com"));
        assert!(!on_site("notexample.com", "example.com"));
        assert!(!on_site("example.org", "example.com"));
    }
}
