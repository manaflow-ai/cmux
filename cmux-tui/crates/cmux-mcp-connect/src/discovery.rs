//! OAuth 2.1 for MCP (the MCP authorization spec, RFC 9728, RFC 8414,
//! RFC 7591, RFC 8707, RFC 9207): reading the metadata, checking it, and
//! building the requests. The daemon does the HTTP; this decides.

use serde::Deserialize;
use serde_json::{Value, json};
use url::Url;

use crate::Refusal;
use crate::pkce::state_matches;
use crate::target::check_url;

/// RFC 9728 protected resource metadata.
#[derive(Clone, Debug, Deserialize, PartialEq, Eq)]
pub struct ProtectedResource {
    pub resource: String,
    #[serde(default)]
    pub authorization_servers: Vec<String>,
    #[serde(default)]
    pub scopes_supported: Vec<String>,
}

/// RFC 8414 authorization server metadata (the fields cmux uses).
#[derive(Clone, Debug, Deserialize, PartialEq, Eq)]
pub struct AuthServer {
    pub issuer: String,
    pub authorization_endpoint: String,
    pub token_endpoint: String,
    #[serde(default)]
    pub registration_endpoint: Option<String>,
    #[serde(default)]
    pub revocation_endpoint: Option<String>,
    #[serde(default)]
    pub code_challenge_methods_supported: Vec<String>,
    #[serde(default)]
    pub scopes_supported: Vec<String>,
    #[serde(default)]
    pub authorization_response_iss_parameter_supported: bool,
    #[serde(default)]
    pub client_id_metadata_document_supported: bool,
}

/// The `resource_metadata` URL of a `WWW-Authenticate: Bearer ...` header.
pub fn resource_metadata_url(www_authenticate: &str) -> Option<String> {
    param(www_authenticate, "resource_metadata")
}

/// The `scope` a `WWW-Authenticate` header asks for, as a list.
pub fn challenge_scopes(www_authenticate: &str) -> Vec<String> {
    param(www_authenticate, "scope")
        .map(|s| s.split_whitespace().map(str::to_owned).collect())
        .unwrap_or_default()
}

fn param(header: &str, name: &str) -> Option<String> {
    let lower = header.to_ascii_lowercase();
    let mut from = 0;
    while let Some(at) = lower.get(from..)?.find(&format!("{name}=")) {
        let start = from + at;
        let before = lower.get(..start)?.chars().last();
        from = start + name.len() + 1;
        if before.is_some_and(|c| c.is_ascii_alphanumeric() || c == '_') {
            continue;
        }
        let rest = header.get(from..)?;
        return Some(match rest.strip_prefix('"') {
            Some(q) => q.split('"').next()?.to_owned(),
            None => rest.split([',', ' ']).next()?.to_owned(),
        });
    }
    None
}

/// The RFC 9728 well-known URL for a server URL with no header to follow:
/// `https://h/p` -> `https://h/.well-known/oauth-protected-resource/p`.
pub fn protected_resource_url(server: &str) -> Result<String, Refusal> {
    well_known(server, "oauth-protected-resource")
}

/// The RFC 8414 metadata URL of an issuer (path inserted after the
/// well-known segment).
pub fn auth_server_url(issuer: &str) -> Result<String, Refusal> {
    well_known(issuer, "oauth-authorization-server")
}

fn well_known(base: &str, which: &str) -> Result<String, Refusal> {
    let mut url = Url::parse(base).map_err(|e| Refusal::new(e.to_string()))?;
    let path = url.path().trim_end_matches('/').to_owned();
    url.set_path(&format!("/.well-known/{which}{path}"));
    url.set_query(None);
    Ok(url.to_string())
}

fn same_url(a: &str, b: &str) -> bool {
    let n = |s: &str| Url::parse(s).ok().map(|u| u.to_string().trim_end_matches('/').to_owned());
    n(a).is_some() && n(a) == n(b)
}

impl ProtectedResource {
    pub fn parse(text: &str) -> Result<Self, Refusal> {
        serde_json::from_str(text).map_err(|e| Refusal::new(format!("resource metadata: {e}")))
    }

    /// RFC 9728 section 3.3: the metadata must name the server it was
    /// fetched for, or another server's metadata is being passed off.
    pub fn check(&self, server: &str) -> Result<(), Refusal> {
        if !same_url(&self.resource, server) {
            return Err(Refusal::new(format!(
                "the server's metadata names {} as its resource, not {server}",
                self.resource
            )));
        }
        if self.authorization_servers.is_empty() {
            return Err(Refusal::new("the server names no authorization server"));
        }
        self.authorization_servers.iter().try_for_each(|a| check_url(a).map(|_| ()))
    }
}

impl AuthServer {
    pub fn parse(text: &str) -> Result<Self, Refusal> {
        serde_json::from_str(text).map_err(|e| Refusal::new(format!("server metadata: {e}")))
    }

    /// Checks the metadata fetched for `issuer`: it names that issuer, its
    /// endpoints pass the URL rules, and it does PKCE S256 (OAuth 2.1).
    pub fn check(&self, issuer: &str) -> Result<(), Refusal> {
        if !same_url(&self.issuer, issuer) {
            return Err(Refusal::new(format!(
                "the metadata's issuer {} is not {issuer}",
                self.issuer
            )));
        }
        if !self.code_challenge_methods_supported.iter().any(|m| m == "S256") {
            return Err(Refusal::new(
                "the server does not support PKCE S256; cmux does not sign in without it",
            ));
        }
        for e in [Some(&self.authorization_endpoint), Some(&self.token_endpoint)]
            .into_iter()
            .chain([self.registration_endpoint.as_ref(), self.revocation_endpoint.as_ref()])
            .flatten()
        {
            check_url(e)?;
        }
        Ok(())
    }

    /// The authorize URL the sign-in tab opens.
    pub fn authorize_url(&self, req: &AuthorizeRequest<'_>) -> Result<String, Refusal> {
        let mut url =
            Url::parse(&self.authorization_endpoint).map_err(|e| Refusal::new(e.to_string()))?;
        {
            let mut q = url.query_pairs_mut();
            q.append_pair("response_type", "code")
                .append_pair("client_id", req.client_id)
                .append_pair("redirect_uri", req.redirect_uri)
                .append_pair("state", req.state)
                .append_pair("code_challenge", req.code_challenge)
                .append_pair("code_challenge_method", "S256")
                .append_pair("resource", req.resource);
            if !req.scopes.is_empty() {
                q.append_pair("scope", &req.scopes.join(" "));
            }
        }
        Ok(url.to_string())
    }

    /// Checks the redirect's query and returns the code (T12): the state
    /// matches, there is no error, and `iss` is this issuer when the server
    /// says it sends one (RFC 9207 mix-up defense).
    pub fn callback_code(&self, query: &str, expected_state: &str) -> Result<String, Refusal> {
        let pairs: Vec<(String, String)> = url::form_urlencoded::parse(query.as_bytes())
            .map(|(k, v)| (k.into_owned(), v.into_owned()))
            .collect();
        let get = |k: &str| pairs.iter().find(|(n, _)| n == k).map(|(_, v)| v.as_str());
        if !state_matches(expected_state, get("state").unwrap_or("")) {
            return Err(Refusal::new("the sign-in answer's state does not match; ignored"));
        }
        if let Some(e) = get("error") {
            return Err(Refusal::new(format!("the server refused the sign-in: {e}")));
        }
        if self.authorization_response_iss_parameter_supported
            && !get("iss").is_some_and(|i| same_url(i, &self.issuer))
        {
            return Err(Refusal::new("the sign-in answer came from another issuer"));
        }
        get("code")
            .filter(|c| !c.is_empty())
            .map(str::to_owned)
            .ok_or_else(|| Refusal::new("the sign-in answer has no code"))
    }
}

/// What an authorize URL carries.
pub struct AuthorizeRequest<'a> {
    pub client_id: &'a str,
    pub redirect_uri: &'a str,
    pub state: &'a str,
    pub code_challenge: &'a str,
    /// RFC 8707: the MCP server URL, so the token is bound to it.
    pub resource: &'a str,
    pub scopes: &'a [String],
}

/// The token request form for an authorization code.
pub fn token_form(
    code: &str,
    verifier: &str,
    redirect_uri: &str,
    client_id: &str,
    resource: &str,
) -> Vec<(&'static str, String)> {
    vec![
        ("grant_type", "authorization_code".to_owned()),
        ("code", code.to_owned()),
        ("code_verifier", verifier.to_owned()),
        ("redirect_uri", redirect_uri.to_owned()),
        ("client_id", client_id.to_owned()),
        ("resource", resource.to_owned()),
    ]
}

/// The RFC 7591 registration cmux sends: a public client (no secret) with
/// one loopback redirect.
pub fn registration(redirect_uri: &str) -> Value {
    json!({
        "client_name": "cmux",
        "client_uri": "https://cmux.com",
        "redirect_uris": [redirect_uri],
        "grant_types": ["authorization_code", "refresh_token"],
        "response_types": ["code"],
        "token_endpoint_auth_method": "none"
    })
}

/// The least scopes to ask for (T13): the registry's when it names any,
/// else what the server's challenge asks, else what it supports minus
/// admin scopes.
pub fn choose_scopes(
    registry: &[String],
    challenge: &[String],
    supported: &[String],
) -> Vec<String> {
    if !registry.is_empty() {
        return registry.to_vec();
    }
    if !challenge.is_empty() {
        return challenge.to_vec();
    }
    supported.iter().filter(|s| !s.to_ascii_lowercase().contains("admin")).cloned().collect()
}
