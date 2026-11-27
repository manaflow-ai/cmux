//! The three settings resolved to the endpoint a recording goes to.
//!
//! URL rule: https to any host. http only to a loopback host (`127.0.0.0/8`, `::1`, `localhost`)
//! for any provider, or to a private-LAN host (`10/8`, `172.16/12`, `192.168/16`, `fc00::/7`, a
//! `.local` mDNS name) when no key will be sent: a provider that requires a key is refused there,
//! and one whose key is optional is used without its key (the endpoint has no key account). Any
//! other http host, another scheme, a user or password in the URL, a query or a fragment:
//! `bad_endpoint`.
//!
//! The key account is `<providerId>@<origin>`, the origin being the effective base URL's
//! `scheme://host[:port]` as the URL standard serializes it (lowercase host, default port
//! omitted, IPv6 in brackets): a key saved for one origin is never sent to another.

use std::net::{Ipv4Addr, Ipv6Addr};

use url::{Host, Url};

use crate::catalog::{self, KeyUse, Provider, Wire};
use crate::error::{ErrorCode, VoiceError};

/// The settings as cmux-next.json holds them (`agentPane.dictationEngine`,
/// `agentPane.dictationEngineURL`, `agentPane.dictationEngineModel`); empty means the default.
#[derive(Debug, Clone, Default, PartialEq, Eq)]
pub struct Settings {
    pub engine: String,
    pub url: String,
    pub model: String,
}

/// Where a recording goes.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Endpoint {
    pub provider: &'static Provider,
    /// The base URL without a trailing `/`.
    pub base_url: String,
    /// `scheme://host[:port]`.
    pub origin: String,
    /// The model to ask for; empty: send no `model` field.
    pub model: String,
    /// Whether a key may be sent here (false over http to a LAN host).
    pub key_allowed: bool,
}

impl Endpoint {
    /// The Keychain account of this endpoint's key, or `None` when no key is ever sent here.
    pub fn key_account(&self) -> Option<String> {
        (self.key_allowed && self.provider.key != KeyUse::None)
            .then(|| format!("{}@{}", self.provider.id, self.origin))
    }

    /// `<base>/<path>`.
    pub fn url_for(&self, path: &str) -> String {
        format!("{}/{}", self.base_url, path.trim_start_matches('/'))
    }
}

/// The settings resolved: the provider (on-device for an unknown engine), its effective model and
/// the endpoint, or why there is none.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Resolved {
    pub provider: &'static Provider,
    pub model: String,
    pub endpoint: Result<Endpoint, VoiceError>,
}

/// Resolves the settings.
pub fn resolve(settings: &Settings) -> Resolved {
    let provider = catalog::find_or_on_device(settings.engine.trim());
    let model = match provider.wire {
        Wire::Builtin | Wire::WhisperCppInference => String::new(),
        Wire::OpenaiTranscriptions => {
            let given = settings.model.trim();
            if given.is_empty() { provider.default_model.to_owned() } else { given.to_owned() }
        }
    };
    let endpoint = endpoint(provider, settings.url.trim(), &model);
    Resolved { provider, model, endpoint }
}

fn endpoint(provider: &'static Provider, url: &str, model: &str) -> Result<Endpoint, VoiceError> {
    if provider.wire == Wire::Builtin {
        return Err(VoiceError::new(
            ErrorCode::NotConfigured,
            "the on-device engine sends nothing",
            None,
        ));
    }
    let raw = if url.is_empty() { provider.default_url } else { url };
    if raw.is_empty() {
        return Err(VoiceError::new(ErrorCode::NotConfigured, "this provider needs a URL", None));
    }
    let (parsed, key_allowed) = check_url(raw, provider.key)?;
    // Only a validated URL supplied in settings is person-named. Built-in provider
    // hosts belong in the shared egress allowlist instead.
    if !url.is_empty() {
        cmux_egress::allow_named(parsed.as_str());
    }
    Ok(Endpoint {
        provider,
        base_url: parsed.as_str().trim_end_matches('/').to_owned(),
        origin: parsed.origin().ascii_serialization(),
        model: model.to_owned(),
        key_allowed,
    })
}

/// How far a host is.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Reach {
    Loopback,
    Lan,
    Public,
}

fn reach_v4(ip: Ipv4Addr) -> Reach {
    if ip.is_loopback() {
        Reach::Loopback
    } else if ip.is_private() {
        Reach::Lan
    } else {
        Reach::Public
    }
}

fn reach_v6(ip: Ipv6Addr) -> Reach {
    if ip.is_loopback() {
        return Reach::Loopback;
    }
    if let Some(v4) = ip.to_ipv4_mapped() {
        return reach_v4(v4);
    }
    // fc00::/7, unique local addresses.
    if ip.octets().first().is_some_and(|b| b & 0xfe == 0xfc) { Reach::Lan } else { Reach::Public }
}

fn reach(host: &Host<&str>) -> Reach {
    match host {
        Host::Domain(name) => {
            let name = name.trim_end_matches('.');
            if name == "localhost" || name.ends_with(".localhost") {
                Reach::Loopback
            } else if name.ends_with(".local") {
                Reach::Lan
            } else {
                Reach::Public
            }
        }
        Host::Ipv4(ip) => reach_v4(*ip),
        Host::Ipv6(ip) => reach_v6(*ip),
    }
}

/// Checks `raw` against the URL rule for a provider whose key use is `key`: the parsed URL and
/// whether a key may be sent to it.
pub fn check_url(raw: &str, key: KeyUse) -> Result<(Url, bool), VoiceError> {
    let bad = |why: &str| Err(VoiceError::new(ErrorCode::BadEndpoint, why, None));
    let Ok(url) = Url::parse(raw.trim()) else {
        return bad("not a URL");
    };
    if !url.username().is_empty() || url.password().is_some() {
        return bad("the URL may not carry a user name or password");
    }
    if url.query().is_some() || url.fragment().is_some() {
        return bad("the URL may not carry a query or a fragment");
    }
    let Some(reach) = url.host().as_ref().map(reach) else {
        return bad("the URL has no host");
    };
    let key_allowed = match (url.scheme(), reach) {
        ("https", _) | ("http", Reach::Loopback) => true,
        ("http", Reach::Lan) if key == KeyUse::Required => {
            return bad("a key is never sent over http to another machine: use https");
        }
        ("http", Reach::Lan) => false,
        ("http", Reach::Public) => {
            return bad("http is only for this Mac or a private network: use https");
        }
        _ => return bad("the URL must start with https://"),
    };
    Ok((url, key_allowed))
}

/// `<provider>@<origin>` of `base_url` (the Keychain account its key is saved under), or `None`
/// when `base_url` is not a URL.
pub fn key_account(provider: &str, base_url: &str) -> Option<String> {
    let url = Url::parse(base_url.trim()).ok()?;
    let origin = url.origin();
    origin.is_tuple().then(|| format!("{provider}@{}", origin.ascii_serialization()))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn settings(engine: &str, url: &str, model: &str) -> Settings {
        Settings { engine: engine.into(), url: url.into(), model: model.into() }
    }

    #[test]
    fn egress_allows_valid_settings_and_lists_builtin_providers() {
        let custom = "https://voice-egress-configured.com/v1";
        assert_eq!(cmux_egress::verdict(custom), cmux_egress::Verdict::Unlisted);
        assert!(resolve(&settings("custom", custom, "")).endpoint.is_ok());
        assert_eq!(cmux_egress::verdict(custom), cmux_egress::Verdict::Named);

        let rejected = "http://voice-egress-rejected.com/v1";
        assert!(resolve(&settings("custom", rejected, "")).endpoint.is_err());
        assert_eq!(cmux_egress::verdict(rejected), cmux_egress::Verdict::Unlisted);

        for engine in ["openai", "groq"] {
            let endpoint = resolve(&settings(engine, "", "")).endpoint.unwrap();
            assert_eq!(cmux_egress::verdict(&endpoint.base_url), cmux_egress::Verdict::Listed);
        }
    }

    #[test]
    fn url_rule_table() {
        use KeyUse::{None as NoKey, Optional, Required};
        let cases: &[(&str, KeyUse, Option<bool>)] = &[
            ("https://api.openai.com/v1", Required, Some(true)),
            ("https://example.com", Optional, Some(true)),
            ("http://127.0.0.1:8000/v1", Required, Some(true)),
            ("http://127.9.9.9:8000", Optional, Some(true)),
            ("http://localhost:8080", NoKey, Some(true)),
            ("http://[::1]:8080", Required, Some(true)),
            ("http://192.168.1.20:8000/v1", Optional, Some(false)),
            ("http://10.0.0.5", NoKey, Some(false)),
            ("http://172.16.4.4", Optional, Some(false)),
            ("http://mini.local:9000", Optional, Some(false)),
            ("http://[fd00::1]:80", Optional, Some(false)),
            ("http://192.168.1.20:8000/v1", Required, None),
            ("http://api.openai.com/v1", Optional, None),
            ("http://8.8.8.8", NoKey, None),
            ("http://169.254.169.254", NoKey, None),
            ("ftp://127.0.0.1", NoKey, None),
            ("file:///tmp/x", NoKey, None),
            ("not a url", NoKey, None),
            ("", NoKey, None),
            ("https://user:pw@example.com", Optional, None),
            ("https://example.com/v1?key=1", Optional, None),
            ("https://example.com/v1#x", Optional, None),
        ];
        for (url, key, want) in cases {
            let got = check_url(url, *key);
            match want {
                Some(allowed) => {
                    let (_, k) = got.unwrap_or_else(|e| panic!("{url}: {e}"));
                    assert_eq!(k, *allowed, "{url}");
                }
                None => {
                    let e = got.err().unwrap_or_else(|| panic!("{url} passed"));
                    assert_eq!(e.code, ErrorCode::BadEndpoint, "{url}");
                }
            }
        }
    }

    #[test]
    fn key_account_is_provider_at_origin() {
        assert_eq!(
            key_account("openai", "https://API.OpenAI.com/v1/").as_deref(),
            Some("openai@https://api.openai.com")
        );
        assert_eq!(
            key_account("localServer", "http://127.0.0.1:8000/v1").as_deref(),
            Some("localServer@http://127.0.0.1:8000")
        );
        assert_eq!(
            key_account("custom", "https://x.dev:443/a").as_deref(),
            Some("custom@https://x.dev")
        );
        assert_eq!(
            key_account("custom", "http://[::1]:9/").as_deref(),
            Some("custom@http://[::1]:9")
        );
        assert_eq!(key_account("custom", "nope"), None);
    }

    #[test]
    fn resolution_uses_defaults_and_overrides() {
        let r = resolve(&settings("openai", "", ""));
        let e = r.endpoint.unwrap();
        assert_eq!(e.base_url, "https://api.openai.com/v1");
        assert_eq!(e.model, "gpt-4o-mini-transcribe");
        assert_eq!(e.key_account().as_deref(), Some("openai@https://api.openai.com"));
        assert_eq!(
            e.url_for("audio/transcriptions"),
            "https://api.openai.com/v1/audio/transcriptions"
        );

        let r = resolve(&settings(
            "groq",
            " https://proxy.example.com/openai/v1/ ",
            " whisper-large-v3 ",
        ));
        let e = r.endpoint.unwrap();
        assert_eq!(e.base_url, "https://proxy.example.com/openai/v1");
        assert_eq!(e.model, "whisper-large-v3");
        assert_eq!(e.key_account().as_deref(), Some("groq@https://proxy.example.com"));

        let e = resolve(&settings("localServer", "", "")).endpoint.unwrap();
        assert_eq!(e.model, "");
        assert_eq!(e.key_account().as_deref(), Some("localServer@http://127.0.0.1:8000"));

        let e =
            resolve(&settings("localServer", "http://192.168.0.9:8000/v1", "")).endpoint.unwrap();
        assert!(!e.key_allowed);
        assert_eq!(e.key_account(), None);

        let r = resolve(&settings("whisperCpp", "", "ignored"));
        assert_eq!(r.model, "");
        let e = r.endpoint.unwrap();
        assert_eq!(e.base_url, "http://127.0.0.1:8080");
        assert_eq!(e.key_account(), None, "whisper.cpp takes no key");
    }

    #[test]
    fn unconfigured_and_forbidden_endpoints() {
        for engine in ["onDevice", "", "bogus"] {
            let r = resolve(&settings(engine, "https://example.com", ""));
            assert_eq!(r.provider.id, "onDevice");
            assert_eq!(r.endpoint.unwrap_err().code, ErrorCode::NotConfigured);
        }
        let r = resolve(&settings("custom", "", ""));
        assert_eq!(r.endpoint.unwrap_err().code, ErrorCode::NotConfigured);
        let r = resolve(&settings("openai", "http://api.openai.com/v1", ""));
        assert_eq!(r.endpoint.unwrap_err().code, ErrorCode::BadEndpoint);
        let r = resolve(&settings("openai", "http://10.1.1.1/v1", ""));
        assert_eq!(r.endpoint.unwrap_err().code, ErrorCode::BadEndpoint);
    }
}
