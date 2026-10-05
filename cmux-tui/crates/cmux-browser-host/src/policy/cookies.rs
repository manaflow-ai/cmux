//! Cookie guards of the domain policy (main's BrowserReplDomainPolicy
//! cookieBlockReason and cookieSetBlockReason; scenario 38). Cookies
//! belong to hosts, not origins, so a pattern's scheme and port do not
//! narrow them.

use super::{DomainPattern, Layer, Policy};

/// `host` named by `p`, its scheme and port ignored.
fn names(p: &DomainPattern, host: &str) -> bool {
    if p.host == "*" {
        return true;
    }
    if let Some(base) = p.host.strip_prefix("*.") {
        return host == base || host.ends_with(&format!(".{base}"));
    }
    host == p.host || (p.host.split('.').count() == 2 && host == format!("www.{}", p.host))
}

/// `p`'s hosts receive cookies set on `host` (theirs or a parent domain's).
fn receives(p: &DomainPattern, host: &str) -> bool {
    names(p, host)
        || p.host == "*"
        || p.host.trim_start_matches("*.").ends_with(&format!(".{host}"))
}

fn is_ip(host: &str) -> bool {
    host.starts_with('[')
        || host.parse::<std::net::Ipv4Addr>().is_ok()
        || url::Url::parse(&format!("http://{host}/"))
            .is_ok_and(|u| matches!(u.host(), Some(url::Host::Ipv4(_) | url::Host::Ipv6(_))))
}

fn allowed_list(allowed: &[DomainPattern]) -> String {
    allowed.iter().map(|p| p.raw.as_str()).collect::<Vec<_>>().join(", ")
}

impl Layer {
    fn cookie_refusal(&self, host: &str) -> Option<String> {
        if self.block_ips && is_ip(host) {
            return Some("IP addresses are blocked (session.blockIPAddresses)".into());
        }
        if let Some(allowed) = &self.allowed
            && !allowed.iter().any(|p| receives(p, host))
        {
            return Some(format!("not in session.allowedDomains ({})", allowed_list(allowed)));
        }
        self.prohibited
            .iter()
            .find(|p| names(p, host))
            .map(|p| format!("prohibited by {} (session.prohibitedDomains)", p.raw))
    }

    fn cookie_set_refusal(&self, raw: &str, host: &str) -> Option<String> {
        if !raw.starts_with('.') {
            return match &self.allowed {
                Some(allowed) if !allowed.iter().any(|p| names(p, host)) => {
                    Some(format!("not in session.allowedDomains ({})", allowed_list(allowed)))
                }
                _ => None,
            };
        }
        let covers = |p: &DomainPattern| {
            p.host == "*"
                || p.host
                    .strip_prefix("*.")
                    .is_some_and(|base| host == base || host.ends_with(&format!(".{base}")))
        };
        if let Some(allowed) = &self.allowed
            && !allowed.iter().any(covers)
        {
            return Some(format!(
                "a cookie on {host} reaches its other subdomains, which session.allowedDomains ({}) does not all allow; set it on the allowed host itself",
                allowed_list(allowed)
            ));
        }
        let under = |p: &DomainPattern| {
            let named = p.host.trim_start_matches("*.");
            p.host == "*"
                || named == host
                || named.ends_with(&format!(".{host}"))
                || host.ends_with(&format!(".{named}"))
        };
        self.prohibited
            .iter()
            .find(|p| under(p))
            .map(|p| format!("a cookie on {host} reaches {} (session.prohibitedDomains)", p.raw))
    }
}

impl Policy {
    fn cookie_host(domain: &str) -> String {
        let host = domain.trim().trim_start_matches('.');
        super::normalize_host(domain, host).unwrap_or_default()
    }

    /// Why agent code may not read or clear the cookies of `domain` (a
    /// cookie's Domain value), or `None`.
    pub fn cookie_refusal(&self, domain: &str) -> Option<String> {
        if !self.base.is_active() && !self.agent.is_active() {
            return None;
        }
        let host = Self::cookie_host(domain);
        if host.is_empty() {
            return Some("the cookie names no domain".into());
        }
        self.base.cookie_refusal(&host).or_else(|| self.agent.cookie_refusal(&host))
    }

    /// Why agent code may not set a cookie with this Domain value, or `None`.
    /// A leading dot makes the cookie reach every subdomain.
    pub fn cookie_set_refusal(&self, domain: &str) -> Option<String> {
        if let Some(reason) = self.cookie_refusal(domain) {
            return Some(reason);
        }
        if !self.base.is_active() && !self.agent.is_active() {
            return None;
        }
        let raw = domain.trim();
        let host = Self::cookie_host(domain);
        self.base
            .cookie_set_refusal(raw, &host)
            .or_else(|| self.agent.cookie_set_refusal(raw, &host))
    }
}

#[cfg(test)]
#[path = "cookies_tests.rs"]
mod tests;
