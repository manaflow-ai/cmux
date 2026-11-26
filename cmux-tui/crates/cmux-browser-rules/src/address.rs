//! Rules for the address a person types.
//!
//! Ported 1:1 from the app's Swift (`CmuxNextBrowser`): `TopLevelDomains` and `HostTypoFixup`
//! (Omnibox/HostTypoFixup.swift) and `HTTPSUpgradeFallback.fallsBack`
//! (Omnibox/HTTPSUpgradeFallback.swift). The IANA root zone list moved here with them
//! (`data/top-level-domains.txt`, https://data.iana.org/TLD/tlds-alpha-by-domain.txt).

use serde::Serialize;
use std::collections::HashSet;
use std::sync::OnceLock;

const TOP_LEVEL_DOMAINS: &str = include_str!("../data/top-level-domains.txt");

fn top_level_domains() -> &'static HashSet<String> {
    static ALL: OnceLock<HashSet<String>> = OnceLock::new();
    ALL.get_or_init(|| {
        TOP_LEVEL_DOMAINS
            .lines()
            .filter(|line| !line.is_empty() && !line.starts_with('#'))
            .map(|line| line.trim().to_lowercase())
            .collect()
    })
}

/// `label` (any case, ASCII or punycode) is a delegated top-level domain: a label not in the
/// IANA root zone cannot resolve on the public internet.
pub fn is_top_level_domain(label: &str) -> bool {
    top_level_domains().contains(&label.to_lowercase())
}

/// Mistyped last label -> intended top-level domain (Firefox's `fixupTypos`, `URIFixup.sys.mjs`).
pub const TYPOS: &[(&str, &str)] = &[
    ("ocm", "com"),
    ("con", "com"),
    ("cmo", "com"),
    ("xom", "com"),
    ("vom", "com"),
    ("cpm", "com"),
    ("com'", "com"),
    ("ent", "net"),
    ("ner", "net"),
    ("nte", "net"),
    ("met", "net"),
    ("rog", "org"),
    ("ogr", "org"),
    ("prg", "org"),
    ("orh", "org"),
];

/// A fixed address.
#[derive(Clone, Debug, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct TypoFix {
    /// The typed text with the last host label replaced.
    pub text: String,
    /// The host as typed, lowercased (`example.con`).
    pub typed_host: String,
}

/// Fixes a mistyped top-level domain in typed text (`example.con` loads `example.com`). Only the
/// host's last label changes; scheme, port, path, query and fragment stay as typed. Nothing
/// changes when the last label is a real top-level domain, the host ends with a dot, is an IP
/// literal or a single label, the text has userinfo, whitespace or a scheme other than http(s).
pub fn fix_host_typo(text: &str) -> Option<TypoFix> {
    fix_host_typo_with(text, is_top_level_domain)
}

/// [`fix_host_typo`] with the top-level domain test given (tests pass their own).
pub fn fix_host_typo_with(text: &str, is_tld: impl Fn(&str) -> bool) -> Option<TypoFix> {
    let text = text.trim();
    if text.is_empty() || text.chars().any(char::is_whitespace) {
        return None;
    }
    let authority_start = match text.find("://") {
        Some(separator) => {
            let scheme = text[..separator].to_lowercase();
            if scheme != "http" && scheme != "https" {
                return None;
            }
            separator + 3
        }
        None => 0,
    };
    let rest = &text[authority_start..];
    let authority_end = rest.find(['/', '?', '#']).unwrap_or(rest.len());
    let authority = &rest[..authority_end];
    if authority.is_empty() || authority.contains('@') || authority.starts_with('[') {
        return None;
    }
    let host_end = match authority.find(':') {
        Some(colon) => {
            let port = &authority[colon + 1..];
            if port.is_empty() || !port.bytes().all(|byte| byte.is_ascii_digit()) {
                return None;
            }
            colon
        }
        None => authority.len(),
    };
    let host = &authority[..host_end];
    let labels: Vec<&str> = host.split('.').collect();
    if labels.len() < 2 || labels.iter().any(|label| label.is_empty()) {
        return None;
    }
    let last = labels[labels.len() - 1];
    let typed_label = last.to_lowercase();
    let intended = TYPOS.iter().find(|(typo, _)| *typo == typed_label).map(|(_, tld)| *tld)?;
    if is_tld(&typed_label) {
        return None;
    }
    let last_start = authority_start + host_end - last.len();
    let mut fixed = String::with_capacity(text.len());
    fixed.push_str(&text[..last_start]);
    fixed.push_str(intended);
    fixed.push_str(&text[last_start + last.len()..]);
    Some(TypoFix { text: fixed, typed_host: host.to_lowercase() })
}

/// `NSURLErrorDomain`.
pub const NSURL_ERROR_DOMAIN: &str = "NSURLErrorDomain";
/// `ChromiumNetError.domain`.
pub const CHROMIUM_NET_ERROR_DOMAIN: &str = "net";

/// Chromium's certificate errors (`net_error_list.h`, -200 to -299).
pub fn is_chromium_certificate_code(code: i64) -> bool {
    (-299..=-200).contains(&code)
}

/// A load error that is a certificate error (`BrowserLoadError.isCertificateError`).
pub fn is_certificate_error(domain: &str, code: i64) -> bool {
    match domain {
        CHROMIUM_NET_ERROR_DOMAIN => is_chromium_certificate_code(code),
        // NSURLErrorServerCertificateHasBadDate ... NSURLErrorServerCertificateNotYetValid.
        NSURL_ERROR_DOMAIN => matches!(code, -1204..=-1201),
        _ => false,
    }
}

/// Chrome's HTTPS-Upgrades fallback (`HTTPSUpgradeFallback.fallsBack`): a failure of the TLS
/// connection, not of the name, may load the typed address once over http. Refused, reset, timed
/// out, unreachable, and every TLS or certificate error.
pub fn https_upgrade_falls_back(domain: &str, code: i64) -> bool {
    if is_certificate_error(domain, code) {
        return true;
    }
    match domain {
        // CannotConnectToHost, NetworkConnectionLost, TimedOut, SecureConnectionFailed,
        // ClientCertificateRejected, ClientCertificateRequired, BadServerResponse.
        NSURL_ERROR_DOMAIN => matches!(code, -1004 | -1005 | -1001 | -1200 | -1205 | -1206 | -1011),
        // net_error_list.h: connection (-100 to -199, without the name errors -105 and -137 and
        // being offline, -106) and certificate (-200 to -299) errors, and -7 (timed out).
        CHROMIUM_NET_ERROR_DOMAIN => {
            ((-199..=-100).contains(&code) && ![-105, -106, -137].contains(&code))
                || is_chromium_certificate_code(code)
                || code == -7
        }
        _ => false,
    }
}
