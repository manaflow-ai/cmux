//! `key.add` (cmux#48428, cmux-tui/docs/model-connections.md "Revision 3"): the parameters a
//! provider key is added with, the provider's own check of the key, and the route it is kept in.

use std::path::Path;

use serde_json::{Value, json};

use super::{blocking, resolve, route_error, state};
use crate::providers;
use crate::routes::{self, Auth, RouteFile, RouteKind};
use crate::rpc::RpcError;

/// What `key.add` asked for, checked before anything resolves the key.
pub(in crate::server) struct KeyAdd {
    pub provider: &'static providers::Provider,
    pub endpoints: providers::Endpoints,
    pub secret: String,
    pub label: Option<String>,
}

/// Checks `key.add`'s parameters: a provider the catalog has and that serves Cloud, a secret that
/// is a reference (never the key), and the fields its provider asks for (a named endpoint's
/// `https://` base URL and protocol; Bedrock's region).
pub(in crate::server) fn key_add_params(
    provider_id: &str,
    secret: &str,
    label: Option<&str>,
    base_url: Option<&str>,
    protocol: Option<&str>,
    region: Option<&str>,
) -> Result<KeyAdd, RpcError> {
    let bad =
        |m: String, reason: &str| RpcError::invalid_params(m).with_data(json!({"reason": reason}));
    let provider = providers::find(provider_id).ok_or_else(|| {
        bad(
            format!("unknown provider {provider_id:?}: one of {}", providers::ids().join(", ")),
            "connections.unknown_provider",
        )
    })?;
    if let Some(why) = provider.unavailable {
        return Err(bad(format!("{} has no key a Cloud agent can use", provider.label), why));
    }
    if !routes::is_reference(secret) {
        return Err(bad(
            "secret must be a reference (keychain:ITEM), never the key".into(),
            "route.secret_inline",
        ));
    }
    let endpoints = if provider.fields.contains(&providers::Field::BaseUrl) {
        let base = providers::check_base_url(base_url.unwrap_or_default())
            .map_err(|m| bad(m, "connections.bad_base_url"))?;
        let protocol = protocol.and_then(providers::Protocol::parse).ok_or_else(|| {
            bad(
                format!("protocol must be one of {}", providers::Protocol::ALL.join(", ")),
                "connections.bad_protocol",
            )
        })?;
        providers::named_endpoints(&base, protocol)
    } else if provider.fields.contains(&providers::Field::Region) {
        let region = providers::check_region(region.unwrap_or_default())
            .map_err(|m| bad(m, "connections.bad_region"))?;
        providers::endpoints(provider, Some(&region))
    } else {
        providers::endpoints(provider, None)
    };
    let label = label.map(str::trim).filter(|l| !l.is_empty()).map(str::to_owned);
    Ok(KeyAdd { provider, endpoints, secret: secret.to_owned(), label })
}

/// Writes the key connection `add` describes (its key already checked): a direct-api-key route
/// whose secret is the reference, with the endpoints local chats use too.
pub(in crate::server) fn add_key(
    dir: Option<&Path>,
    home: &Path,
    add: &KeyAdd,
) -> Result<(String, Value), RpcError> {
    let p = add.provider;
    let id = std::iter::once(format!("{}-key", p.id))
        .chain((2..1000).map(|n| format!("{}-key-{n}", p.id)))
        .find(|id| routes::find(dir, id).is_err())
        .ok_or_else(|| RpcError::invalid_params("too many keys for this provider"))?;
    let e = &add.endpoints;
    let anthropic = e.anthropic.as_ref().filter(|(_, a)| *a != providers::AnthropicAuth::Bedrock);
    let auth = match anthropic.map(|(_, a)| *a) {
        Some(providers::AnthropicAuth::Bearer) => Auth::Bearer,
        _ => Auth::ApiKey,
    };
    let health_url = match (&e.region, p.check) {
        (Some(region), Some(providers::Check::Bedrock)) => {
            Some(format!("https://bedrock-mantle.{region}.api.aws/v1/models"))
        }
        _ => None,
    };
    let file = RouteFile {
        name: Some(add.label.clone().unwrap_or_else(|| p.label.to_owned())),
        kind: RouteKind::DirectApiKey,
        families: e.families(),
        anthropic_base_url: anthropic.map(|(base, _)| base.clone()),
        openai_base_url: e.responses.clone(),
        auth: Some(auth),
        secret: Some(add.secret.clone()),
        headers: Default::default(),
        health_url,
        fallback: vec![],
        auto_fallback: false,
        notes: None,
        account_home: None,
        shadow_of: None,
        disabled: false,
        provider: Some(p.id.to_owned()),
    };
    // `add` validates again: an inline key is refused (route.secret_inline).
    routes::add(dir, &id, &file, false).map_err(|e| route_error(&e))?;
    Ok((id, state(dir, home)))
}

/// Checks `add`'s key with its provider before it is kept: resolves the reference (off the
/// runtime's threads: the keychain may ask) and sends the provider's check request. A refused
/// key or an unreachable provider is an error naming why, never the key; any other answer
/// keeps it, with what the check saw.
pub(in crate::server) async fn check_key(add: &KeyAdd) -> Result<providers::Checked, RpcError> {
    let reference = add.secret.clone();
    let key = blocking(move || resolve("the new key", &reference)).await??;
    let checked = providers::check(add.provider, &add.endpoints, &key).await;
    drop(key);
    let label = add.provider.label;
    match checked {
        providers::Checked::Rejected(code) => Err(RpcError::invalid_params(format!(
            "{label} refused this key (HTTP {code}): check that it is the whole key and still active"
        ))
        .with_data(json!({"reason": "connections.key_rejected", "http": code}))),
        providers::Checked::PrivateHost => Err(RpcError::invalid_params(
            "baseUrl's name points at this machine or a private network: a key is sent only to a public host",
        )
        .with_data(json!({"reason": "connections.bad_base_url"}))),
        providers::Checked::Unreachable => Err(RpcError::invalid_params(format!(
            "{label} could not be reached to check this key: check the network or the URL"
        ))
        .with_data(json!({"reason": "connections.unreachable"}))),
        other => Ok(other),
    }
}

#[cfg(test)]
mod tests {
    use super::super::credential_plan;
    use super::super::tests::{self, dirs, secret_file};
    use super::*;

    #[test]
    fn a_named_endpoint_or_a_region_is_checked_and_delivered_as_given() {
        let d = dirs();
        let key = secret_file(&d, "k", "gw-key-1");
        let params = |p: &str, base: Option<&str>, protocol: Option<&str>, region: Option<&str>| {
            key_add_params(p, &key, None, base, protocol, region)
        };
        for (p, base, protocol, region, reason) in [
            ("custom", None, Some("responses"), None, "connections.bad_base_url"),
            (
                "custom",
                Some("http://llm.example.com"),
                Some("responses"),
                None,
                "connections.bad_base_url",
            ),
            (
                "custom",
                Some("https://llm.example.com/v1?k=1"),
                Some("responses"),
                None,
                "connections.bad_base_url",
            ),
            ("custom", Some("https://llm.example.com/v1"), None, None, "connections.bad_protocol"),
            (
                "custom",
                Some("https://llm.example.com/v1"),
                Some("chat"),
                None,
                "connections.bad_protocol",
            ),
            ("bedrock", None, None, None, "connections.bad_region"),
            ("bedrock", None, None, Some("us-east-1; x"), "connections.bad_region"),
        ] {
            let e = params(p, base, protocol, region).err().unwrap();
            assert_eq!(e.data.unwrap()["reason"], reason, "{p} {base:?} {protocol:?} {region:?}");
        }
        let gw = params(
            "cloudflare",
            Some("https://gateway.ai.cloudflare.com/v1/a/g/anthropic/"),
            Some("anthropic"),
            None,
        )
        .unwrap();
        let (id, _) = add_key(Some(&d.routes), &d.home, &gw).unwrap();
        assert_eq!(id, "cloudflare-key");
        let plan = credential_plan(Some(&d.routes), &d.home, &id).unwrap();
        assert_eq!(plan.family, "claude");
        let env = plan.env("gw-key-1".into());
        assert_eq!(
            env["CMUX_PROVIDER_ANTHROPIC_URL"],
            "https://gateway.ai.cloudflare.com/v1/a/g/anthropic"
        );
        assert_eq!(env["CMUX_PROVIDER_ANTHROPIC_AUTH"], "x-api-key");
        assert!(!env.contains_key("CMUX_PROVIDER_RESPONSES_URL"));
        let bedrock = params("bedrock", None, None, Some("eu-west-1")).unwrap();
        let (id, _) = add_key(Some(&d.routes), &d.home, &bedrock).unwrap();
        let plan = credential_plan(Some(&d.routes), &d.home, &id).unwrap();
        let env = plan.env("k".into());
        assert_eq!(
            env["CMUX_PROVIDER_REGION"], "eu-west-1",
            "the region comes back from the route"
        );
        assert_eq!(env["CMUX_PROVIDER_ANTHROPIC_AUTH"], "bedrock");
        assert!(!env.contains_key("CMUX_PROVIDER_ANTHROPIC_URL"));
        let route = routes::find(Some(&d.routes), &id).unwrap();
        assert_eq!(route.file.secret.as_deref(), Some(key.as_str()), "only the reference is kept");
    }

    /// A provider key on this Mac (cmux#48428): a local OpenCode chat gets the key in its built-in
    /// provider's own variable, and a local Claude Code on a Bedrock key runs Bedrock mode, never the
    /// generic OpenAI or Anthropic key variables.
    #[test]
    fn a_local_opencode_or_bedrock_spawn_reads_its_providers_own_variables() {
        let d = dirs();
        let key = secret_file(&d, "k", "sk-or-v1-local");
        let (id, _) = tests::add_key(Some(&d.routes), &d.home, "openrouter", &key, None).unwrap();
        let route = routes::find(Some(&d.routes), &id).unwrap();
        let env = routes::env_for(&route, "opencode", &d.home).unwrap();
        // The route env names the reference; the spawn resolves it, as on the base-URL path.
        let placeholder = format!("${{{key}}}");
        assert_eq!(env.set.get("OPENROUTER_API_KEY"), Some(&placeholder));
        assert!(
            !env.set.contains_key("OPENAI_API_KEY") && !env.set.contains_key("OPENAI_BASE_URL")
        );
        assert!(
            env.unset.iter().any(|k| k == "GOOGLE_GENERATIVE_AI_API_KEY"),
            "another provider's variable is cleared"
        );
        // Claude Code on the same key keeps the base-URL path.
        let claude = routes::env_for(&route, "claude", &d.home).unwrap();
        assert_eq!(
            claude.set.get("ANTHROPIC_BASE_URL").map(String::as_str),
            Some("https://openrouter.ai/api")
        );

        let bedrock = key_add_params("bedrock", &key, None, None, None, Some("eu-west-1")).unwrap();
        let (id, _) = add_key(Some(&d.routes), &d.home, &bedrock).unwrap();
        let route = routes::find(Some(&d.routes), &id).unwrap();
        let env = routes::env_for(&route, "claude", &d.home).unwrap();
        assert_eq!(env.set.get("CLAUDE_CODE_USE_BEDROCK").map(String::as_str), Some("1"));
        assert_eq!(env.set.get("AWS_BEARER_TOKEN_BEDROCK"), Some(&placeholder));
        assert_eq!(env.set.get("AWS_REGION").map(String::as_str), Some("eu-west-1"));
        assert!(!env.set.contains_key("ANTHROPIC_API_KEY"));
    }
}
