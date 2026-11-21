//! Every model provider a person can connect for Cloud chats (cmux#48428,
//! cmux-tui/docs/model-connections.md "Revision 3"): one catalog the Mac's acpmux lists to Settings
//! (`_acpmux/connections` `providers`), checks a pasted key against ([`check`]), and turns into the
//! credential a Cloud machine's agent launches on ([`delivery`]); the machine's acpmux reads the same
//! catalog to give OpenCode its provider's own variable ([`opencode_env`]).
//!
//! A provider reaches a Cloud agent through at most three ways: an Anthropic Messages endpoint for
//! Claude Code ([`Anthropic`]), an OpenAI Responses endpoint for Codex (`responses`), and
//! OpenCode's built-in provider (`opencode`). A provider with none (SuperGrok, GitHub Copilot: no
//! key a program can use) is listed with the reason it does not serve Cloud, and no key is taken.
//!
//! The key itself is never here: the Mac app keeps it in the login Keychain and acpmux holds only
//! its `keychain:` reference until a check or a Cloud start resolves it.

use std::time::Duration;

use serde::Serialize;
use serde_json::{Value, json};

/// How a provider groups in Add a Connection.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "kebab-case")]
pub enum Group {
    /// A subscription or coding plan whose key the person pastes.
    Subscription,
    /// A pay-as-you-go API key.
    ApiKey,
    /// An endpoint the person names (a gateway, a router, their own server).
    Custom,
}

/// How an Anthropic Messages endpoint takes the key.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "kebab-case")]
pub enum AnthropicAuth {
    /// `x-api-key` (Claude Code's `ANTHROPIC_API_KEY`).
    XApiKey,
    /// `Authorization: Bearer` (Claude Code's `ANTHROPIC_AUTH_TOKEN`).
    Bearer,
    /// Claude Code's own Bedrock mode: a Bedrock API key as `AWS_BEARER_TOKEN_BEDROCK`.
    Bedrock,
}

impl AnthropicAuth {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::XApiKey => "x-api-key",
            Self::Bearer => "bearer",
            Self::Bedrock => "bedrock",
        }
    }

    pub fn parse(text: &str) -> Option<Self> {
        match text {
            "x-api-key" => Some(Self::XApiKey),
            "bearer" => Some(Self::Bearer),
            "bedrock" => Some(Self::Bedrock),
            _ => None,
        }
    }
}

/// An Anthropic Messages endpoint: the base URL Claude Code takes as `ANTHROPIC_BASE_URL`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Anthropic {
    pub base: &'static str,
    pub auth: AnthropicAuth,
}

/// OpenCode's own provider: its id (models.dev) and the variable it reads the key from.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct OpenCode {
    pub id: &'static str,
    pub env: &'static str,
}

/// A field Add a Connection asks for beside the key.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "kebab-case")]
pub enum Field {
    /// The endpoint's `https://` base URL, and the protocol it speaks.
    BaseUrl,
    /// An AWS region (`us-east-1`).
    Region,
}

/// How a check sends the key.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum CheckAuth {
    /// `x-api-key` and `anthropic-version`.
    Anthropic,
    /// `Authorization: Bearer`.
    Bearer,
    /// A header of the provider's own (`x-goog-api-key`).
    Header(&'static str),
}

/// How a key is checked: one request a wrong key answers with one of `rejects`.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Check {
    /// A fixed request.
    Fixed { url: &'static str, auth: CheckAuth, post: bool, rejects: &'static [u16] },
    /// The person's endpoint: its model list, by the protocol they picked.
    Endpoint,
    /// Bedrock's model list in the person's region, with the Bedrock API key as a bearer.
    Bedrock,
}

/// The statuses a wrong key gets from most providers.
const AUTH: &[u16] = &[401, 403];

const fn get(url: &'static str, auth: CheckAuth) -> Option<Check> {
    Some(Check::Fixed { url, auth, post: false, rejects: AUTH })
}

/// One provider.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Provider {
    pub id: &'static str,
    /// The product name (never localized).
    pub label: &'static str,
    pub group: Group,
    /// Where the person makes a key.
    pub console: Option<&'static str>,
    pub anthropic: Option<Anthropic>,
    /// An OpenAI Responses base URL (Codex).
    pub responses: Option<&'static str>,
    pub opencode: Option<OpenCode>,
    pub fields: &'static [Field],
    pub check: Option<Check>,
    /// Why it does not serve Cloud chats (a reason code), for a provider with no usable key.
    pub unavailable: Option<&'static str>,
}

const fn p(id: &'static str, label: &'static str, group: Group) -> Provider {
    Provider {
        id,
        label,
        group,
        console: None,
        anthropic: None,
        responses: None,
        opencode: None,
        fields: &[],
        check: None,
        unavailable: None,
    }
}

const fn anthropic(base: &'static str, auth: AnthropicAuth) -> Option<Anthropic> {
    Some(Anthropic { base, auth })
}

const fn opencode(id: &'static str, env: &'static str) -> Option<OpenCode> {
    Some(OpenCode { id, env })
}

use AnthropicAuth::{Bearer, XApiKey};
use Group::{ApiKey, Custom, Subscription};

/// The catalog, in the order Add a Connection lists each group. Codex and Claude subscriptions
/// are their own connection kinds (`chatgpt-plan`, `claude-token`), not rows here. Endpoints and
/// checks are each provider's documented ones (cmux#48428 has the sources); a provider whose model
/// list answers any caller has no check, and its key is kept unconfirmed.
pub const PROVIDERS: &[Provider] = &[
    // Subscriptions and coding plans.
    Provider {
        console: Some("https://grok.com/plans"),
        unavailable: Some("providers.sign_in_only"),
        ..p("supergrok", "SuperGrok", Subscription)
    },
    Provider {
        console: Some("https://github.com/settings/copilot"),
        unavailable: Some("providers.sign_in_only"),
        ..p("github-copilot", "GitHub Copilot", Subscription)
    },
    Provider {
        console: Some("https://opencode.ai/auth"),
        opencode: opencode("opencode-go", "OPENCODE_API_KEY"),
        ..p("opencode-go", "OpenCode Go", Subscription)
    },
    Provider {
        console: Some("https://z.ai/manage-apikey/apikey-list"),
        anthropic: anthropic("https://api.z.ai/api/anthropic", Bearer),
        responses: Some("https://api.z.ai/api/v1"),
        opencode: opencode("zai-coding-plan", "ZHIPU_API_KEY"),
        check: get("https://api.z.ai/api/coding/paas/v4/models", CheckAuth::Bearer),
        ..p("glm", "GLM Coding Plan", Subscription)
    },
    Provider {
        console: Some("https://ollama.com/settings/keys"),
        anthropic: anthropic("https://ollama.com", Bearer),
        responses: Some("https://ollama.com/v1"),
        opencode: opencode("ollama-cloud", "OLLAMA_API_KEY"),
        check: Some(Check::Fixed {
            url: "https://ollama.com/api/me",
            auth: CheckAuth::Bearer,
            post: true,
            rejects: AUTH,
        }),
        ..p("ollama-cloud", "Ollama Cloud", Subscription)
    },
    Provider {
        console: Some("https://www.kimi.com/code"),
        anthropic: anthropic("https://api.kimi.com/coding", Bearer),
        responses: Some("https://api.kimi.com/coding/v1"),
        opencode: opencode("kimi-code-plan-global", "KIMI_API_KEY"),
        check: get("https://api.kimi.com/coding/v1/models", CheckAuth::Bearer),
        ..p("kimi-code", "Kimi Code", Subscription)
    },
    Provider {
        console: Some("https://morphllm.com/dashboard/api-keys"),
        anthropic: anthropic("https://api.morphllm.com", Bearer),
        responses: Some("https://api.morphllm.com/v1"),
        opencode: opencode("morph", "MORPH_API_KEY"),
        check: get("https://api.morphllm.com/v1/models", CheckAuth::Bearer),
        ..p("morph", "Morph", Subscription)
    },
    // API keys.
    Provider {
        console: Some("https://console.anthropic.com/settings/keys"),
        anthropic: anthropic("https://api.anthropic.com", XApiKey),
        opencode: opencode("anthropic", "ANTHROPIC_API_KEY"),
        check: get("https://api.anthropic.com/v1/models", CheckAuth::Anthropic),
        ..p("anthropic", "Anthropic", ApiKey)
    },
    Provider {
        console: Some("https://platform.openai.com/api-keys"),
        responses: Some("https://api.openai.com/v1"),
        opencode: opencode("openai", "OPENAI_API_KEY"),
        check: get("https://api.openai.com/v1/models", CheckAuth::Bearer),
        ..p("openai", "OpenAI", ApiKey)
    },
    Provider {
        console: Some("https://openrouter.ai/settings/keys"),
        anthropic: anthropic("https://openrouter.ai/api", Bearer),
        responses: Some("https://openrouter.ai/api/v1"),
        opencode: opencode("openrouter", "OPENROUTER_API_KEY"),
        // Its model list answers any caller; `/key` needs the key.
        check: get("https://openrouter.ai/api/v1/key", CheckAuth::Bearer),
        ..p("openrouter", "OpenRouter", ApiKey)
    },
    Provider {
        console: Some("https://aistudio.google.com/app/apikey"),
        opencode: opencode("google", "GOOGLE_GENERATIVE_AI_API_KEY"),
        // A wrong key is a 400 "API key not valid".
        check: Some(Check::Fixed {
            url: "https://generativelanguage.googleapis.com/v1beta/models",
            auth: CheckAuth::Header("x-goog-api-key"),
            post: false,
            rejects: &[400, 401, 403],
        }),
        ..p("google", "Google", ApiKey)
    },
    Provider {
        console: Some("https://console.x.ai"),
        responses: Some("https://api.x.ai/v1"),
        opencode: opencode("xai", "XAI_API_KEY"),
        // A wrong key is a 400 "Incorrect API key".
        check: Some(Check::Fixed {
            url: "https://api.x.ai/v1/api-key",
            auth: CheckAuth::Bearer,
            post: false,
            rejects: &[400, 401, 403],
        }),
        ..p("xai", "xAI", ApiKey)
    },
    Provider {
        console: Some("https://app.baseten.co/settings/api_keys"),
        anthropic: anthropic("https://inference.baseten.co", Bearer),
        responses: Some("https://inference.baseten.co/v1"),
        opencode: opencode("baseten", "BASETEN_API_KEY"),
        check: get("https://inference.baseten.co/v1/models", CheckAuth::Bearer),
        ..p("baseten", "Baseten", ApiKey)
    },
    Provider {
        console: Some("https://vercel.com/d?to=%2F%5Bteam%5D%2F%7E%2Fai%2Fapi-keys"),
        anthropic: anthropic("https://ai-gateway.vercel.sh", Bearer),
        opencode: opencode("vercel", "AI_GATEWAY_API_KEY"),
        check: get("https://ai-gateway.vercel.sh/v1/credits", CheckAuth::Bearer),
        ..p("vercel", "Vercel AI Gateway", ApiKey)
    },
    Provider {
        // Its model list answers any caller: no check.
        console: Some("https://build.nvidia.com/settings/api-keys"),
        opencode: opencode("nvidia", "NVIDIA_API_KEY"),
        ..p("nvidia", "NVIDIA", ApiKey)
    },
    Provider {
        console: Some("https://app.fireworks.ai/settings/users/api-keys"),
        anthropic: anthropic("https://api.fireworks.ai/inference", Bearer),
        responses: Some("https://api.fireworks.ai/inference/v1"),
        opencode: opencode("fireworks-ai", "FIREWORKS_API_KEY"),
        check: get("https://api.fireworks.ai/inference/v1/models", CheckAuth::Bearer),
        ..p("fireworks", "Fireworks", ApiKey)
    },
    Provider {
        console: Some("https://console.aws.amazon.com/bedrock/home#/api-keys"),
        anthropic: anthropic("", AnthropicAuth::Bedrock),
        opencode: opencode("amazon-bedrock", "AWS_BEARER_TOKEN_BEDROCK"),
        fields: &[Field::Region],
        check: Some(Check::Bedrock),
        ..p("bedrock", "Amazon Bedrock", ApiKey)
    },
    Provider {
        // Meta's Model API, which replaced the Llama API.
        console: Some("https://dev.meta.ai"),
        anthropic: anthropic("https://api.meta.ai", Bearer),
        responses: Some("https://api.meta.ai/v1"),
        opencode: opencode("meta", "META_MODEL_API_KEY"),
        check: get("https://api.meta.ai/v1/models", CheckAuth::Bearer),
        ..p("meta", "Meta", ApiKey)
    },
    Provider {
        console: Some("https://app.router.com"),
        anthropic: anthropic("https://api.router.com", Bearer),
        responses: Some("https://api.router.com/v1"),
        check: get("https://api.router.com/v1/models", CheckAuth::Bearer),
        ..p("ramp", "Ramp Router", ApiKey)
    },
    Provider {
        console: Some("https://api.together.ai/settings/api-keys"),
        opencode: opencode("togetherai", "TOGETHER_API_KEY"),
        check: get("https://api.together.xyz/v1/models", CheckAuth::Bearer),
        ..p("together", "Together", ApiKey)
    },
    Provider {
        console: Some("https://deepinfra.com/dash/api_keys"),
        anthropic: anthropic("https://api.deepinfra.com/anthropic", Bearer),
        responses: Some("https://api.deepinfra.com/v1/openai"),
        opencode: opencode("deepinfra", "DEEPINFRA_API_KEY"),
        check: get("https://api.deepinfra.com/v1/openai/models", CheckAuth::Bearer),
        ..p("deepinfra", "DeepInfra", ApiKey)
    },
    // Endpoints the person names: their gateway's URL for one protocol.
    Provider {
        console: Some("https://dash.cloudflare.com/?to=/:account/ai/ai-gateway"),
        fields: &[Field::BaseUrl],
        check: Some(Check::Endpoint),
        ..p("cloudflare", "Cloudflare AI Gateway", Custom)
    },
    Provider {
        console: Some("https://console.neon.tech"),
        fields: &[Field::BaseUrl],
        check: Some(Check::Endpoint),
        ..p("neon", "Neon AI Gateway", Custom)
    },
    Provider {
        fields: &[Field::BaseUrl],
        check: Some(Check::Endpoint),
        ..p("custom", "Custom endpoint", Custom)
    },
];

/// Every provider id, in catalog order.
pub fn ids() -> Vec<&'static str> {
    PROVIDERS.iter().map(|p| p.id).collect()
}

/// The provider `id` names.
pub fn find(id: &str) -> Option<&'static Provider> {
    PROVIDERS.iter().find(|p| p.id == id)
}

/// The protocol a named endpoint speaks.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Protocol {
    /// Anthropic Messages with the key in `x-api-key` (Claude Code).
    Anthropic,
    /// Anthropic Messages with the key as a bearer (Claude Code), as most gateways take it.
    AnthropicBearer,
    /// OpenAI Responses (Codex).
    Responses,
}

impl Protocol {
    /// Every protocol, as Add a Connection offers them.
    pub const ALL: [&'static str; 3] = ["anthropic", "anthropic-bearer", "responses"];

    pub fn parse(text: &str) -> Option<Self> {
        match text {
            "anthropic" => Some(Self::Anthropic),
            "anthropic-bearer" => Some(Self::AnthropicBearer),
            "responses" => Some(Self::Responses),
            _ => None,
        }
    }
}

/// Where one connection's agents reach its provider: the catalog's endpoints, or for an endpoint
/// the person named, the one they gave.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Endpoints {
    pub anthropic: Option<(String, AnthropicAuth)>,
    pub responses: Option<String>,
    pub opencode: Option<OpenCode>,
    pub region: Option<String>,
}

impl Endpoints {
    /// The agent families these endpoints serve on a Cloud machine.
    pub fn families(&self) -> Vec<String> {
        let mut out = Vec::new();
        if self.anthropic.is_some() {
            out.push("claude".to_owned());
        }
        if self.responses.is_some() {
            out.push("codex".to_owned());
        }
        if self.opencode.is_some() {
            out.push("opencode".to_owned());
        }
        out
    }
}

/// A catalog provider's endpoints (an endpoint the person names has none of its own).
pub fn endpoints(p: &Provider, region: Option<&str>) -> Endpoints {
    Endpoints {
        anthropic: p.anthropic.map(|a| (a.base.to_owned(), a.auth)),
        responses: p.responses.map(str::to_owned),
        opencode: p.opencode,
        region: region.map(str::to_owned),
    }
}

/// A named endpoint: its base URL for its one protocol.
pub fn named_endpoints(base: &str, protocol: Protocol) -> Endpoints {
    let anthropic = match protocol {
        Protocol::Anthropic => Some((base.to_owned(), XApiKey)),
        Protocol::AnthropicBearer => Some((base.to_owned(), Bearer)),
        Protocol::Responses => None,
    };
    Endpoints {
        anthropic,
        responses: (protocol == Protocol::Responses).then(|| base.to_owned()),
        opencode: None,
        region: None,
    }
}

/// An endpoint a Cloud machine may be sent to: `https://`, a host, no user, password, query or
/// fragment, nothing a key could hide in, and only URL characters a launch credential carries
/// (`agent_credentials::token_shaped`). The trailing `/` is dropped. Errors never repeat the URL.
pub fn check_base_url(url: &str) -> Result<String, String> {
    let url = crate::byo_endpoint::check_base_url(url).map_err(|e| match e {
        crate::byo_endpoint::UrlError::Invalid(m) | crate::byo_endpoint::UrlError::Secret(m) => m,
    })?;
    let parsed = reqwest::Url::parse(&url).map_err(|_| "baseUrl must be a full URL".to_owned())?;
    if parsed.scheme() != "https" {
        return Err("a Cloud machine reaches the endpoint over https only".into());
    }
    if parsed.query().is_some() {
        return Err("baseUrl may not have a ?query".into());
    }
    if !url.bytes().all(|b| b.is_ascii_alphanumeric() || b"-._~/:".contains(&b)) {
        return Err("baseUrl may hold only letters, digits and - . _ ~ / :".into());
    }
    // A key pasted into the path (`https://host/sk-ant-…`) would travel in every request line and log.
    if parsed.path_segments().into_iter().flatten().any(crate::byo_endpoint::looks_like_secret) {
        return Err("baseUrl holds what looks like a key; paste the key in the key field".into());
    }
    if parsed.host_str().is_none_or(is_private_host) {
        return Err("baseUrl must name a public host, not this machine or a private network".into());
    }
    Ok(url)
}

/// A host a key must never be sent to from a named endpoint: this machine, a private or
/// link-local network (cloud metadata), or a name only an internal resolver answers.
fn is_private_host(host: &str) -> bool {
    let bare = host.trim_start_matches('[').trim_end_matches(']');
    match bare.parse::<std::net::IpAddr>() {
        Ok(ip) => is_private_ip(ip),
        Err(_) => {
            let name = bare.trim_end_matches('.').to_ascii_lowercase();
            name == "localhost"
                || [".localhost", ".local", ".internal", ".lan", ".home.arpa", ".ts.net"]
                    .iter()
                    .any(|suffix| name.ends_with(suffix))
                || !name.contains('.')
        }
    }
}

/// An address a key must never be sent to: this machine, a private, link-local, CGNAT or
/// unique-local network (an IPv4-mapped IPv6 address is read as its IPv4 one).
fn is_private_ip(ip: std::net::IpAddr) -> bool {
    use std::net::IpAddr;
    let ip = match ip {
        IpAddr::V6(v6) => v6.to_ipv4_mapped().map_or(IpAddr::V6(v6), IpAddr::V4),
        ip => ip,
    };
    match ip {
        IpAddr::V4(v4) => {
            let [a, b, ..] = v4.octets();
            v4.is_loopback()
                || v4.is_private()
                || v4.is_link_local()
                || v4.is_unspecified()
                || v4.is_broadcast()
                || (a == 100 && (64..128).contains(&b)) // CGNAT, tailnets
        }
        IpAddr::V6(v6) => {
            let first = v6.segments()[0];
            v6.is_loopback()
                || v6.is_unspecified()
                || (first & 0xfe00) == 0xfc00
                || (first & 0xffc0) == 0xfe80
        }
    }
}

/// An AWS region as Bedrock names one (`us-east-1`, `us-gov-west-1`, `ap-southeast-2`).
pub fn check_region(region: &str) -> Result<String, String> {
    let region = region.trim();
    let parts: Vec<&str> = region.split('-').collect();
    let ok = (3..=4).contains(&parts.len())
        && parts.iter().all(|w| !w.is_empty() && w.len() <= 12)
        && parts.split_last().is_some_and(|(last, words)| {
            last.bytes().all(|b| b.is_ascii_digit())
                && words.iter().all(|w| w.bytes().all(|b| b.is_ascii_lowercase()))
        });
    if ok {
        Ok(region.to_owned())
    } else {
        Err("region must be an AWS region such as us-east-1".into())
    }
}

/// What a key check saw.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Checked {
    /// The provider took the key (a 2xx).
    Accepted,
    /// The provider refused it (its check's `rejects`: 401 or 403, for some a 400).
    Rejected(u16),
    /// The provider was not reached.
    Unreachable,
    /// Another answer (a 404 model list, a 429, a 5xx): the key is kept, unconfirmed.
    Unconfirmed(u16),
    /// The endpoint's name resolves to this machine or a private network: nothing was sent.
    PrivateHost,
}

impl Checked {
    pub fn as_json(&self) -> Value {
        match self {
            Self::Accepted => json!({"status": "accepted"}),
            Self::Rejected(code) => json!({"status": "rejected", "http": code}),
            Self::Unreachable => json!({"status": "unreachable"}),
            Self::Unconfirmed(code) => json!({"status": "unconfirmed", "http": code}),
            Self::PrivateHost => json!({"status": "private_host"}),
        }
    }
}

// timeout: a key check is one request the person waits on in Add a Connection; a dead endpoint
// must answer "unreachable" instead of holding the sheet.
const CHECK_TIMEOUT: Duration = Duration::from_secs(8);

/// The request that checks `key` for provider `p` (with `endpoints` for a named endpoint or a
/// region): its URL, whether it is a POST, its headers and the statuses that refuse the key.
/// None when the provider has no check.
pub fn check_request(p: &Provider, endpoints: &Endpoints, key: &str) -> Option<Request> {
    let headers = |auth: CheckAuth| match auth {
        CheckAuth::Anthropic => {
            vec![("x-api-key", key.to_owned()), ("anthropic-version", "2023-06-01".to_owned())]
        }
        CheckAuth::Bearer => vec![("authorization", format!("Bearer {key}"))],
        CheckAuth::Header(name) => vec![(name, key.to_owned())],
    };
    let get =
        |url: String, auth| Request { url, post: false, headers: headers(auth), rejects: AUTH };
    match p.check? {
        Check::Fixed { url, auth, post, rejects } => {
            Some(Request { url: url.to_owned(), post, headers: headers(auth), rejects })
        }
        Check::Bedrock => {
            let region = endpoints.region.as_deref()?;
            Some(get(
                format!("https://bedrock-mantle.{region}.api.aws/v1/models"),
                CheckAuth::Bearer,
            ))
        }
        Check::Endpoint => match (&endpoints.anthropic, &endpoints.responses) {
            (Some((base, AnthropicAuth::XApiKey)), _) => {
                Some(get(format!("{base}/v1/models"), CheckAuth::Anthropic))
            }
            (Some((base, _)), _) => {
                let mut request = get(format!("{base}/v1/models"), CheckAuth::Bearer);
                request.headers.push(("anthropic-version", "2023-06-01".to_owned()));
                Some(request)
            }
            (None, Some(base)) => Some(get(format!("{base}/models"), CheckAuth::Bearer)),
            (None, None) => None,
        },
    }
}

/// One key check's request.
#[derive(Clone, PartialEq, Eq)]
pub struct Request {
    pub url: String,
    pub post: bool,
    /// Holds the key: never printed (no `Debug`).
    pub headers: Vec<(&'static str, String)>,
    pub rejects: &'static [u16],
}

/// Sends the check. Never logs or returns the key; the answer's body is not read.
pub async fn check(p: &Provider, endpoints: &Endpoints, key: &str) -> Checked {
    let Some(Request { url, post, headers, rejects }) = check_request(p, endpoints, key) else {
        return Checked::Unconfirmed(0);
    };
    let _ = rustls::crypto::ring::default_provider().install_default();
    // The name is resolved here and every address it gives is checked; the request then goes to
    // exactly those addresses, so a name that answers differently a moment later cannot carry the
    // key to this machine or a private network.
    let Ok(parsed) = reqwest::Url::parse(&url) else { return Checked::Unreachable };
    let Some(host) = parsed.host_str().map(str::to_owned) else { return Checked::Unreachable };
    let mut builder = reqwest::Client::builder()
        .timeout(CHECK_TIMEOUT)
        .redirect(reqwest::redirect::Policy::none());
    if host.trim_start_matches('[').trim_end_matches(']').parse::<std::net::IpAddr>().is_err() {
        let port = parsed.port_or_known_default().unwrap_or(443);
        let lookup =
            tokio::time::timeout(CHECK_TIMEOUT, tokio::net::lookup_host((host.as_str(), port)))
                .await;
        let Ok(Ok(addrs)) = lookup else { return Checked::Unreachable };
        let addrs: Vec<std::net::SocketAddr> = addrs.collect();
        if addrs.is_empty() {
            return Checked::Unreachable;
        }
        if addrs.iter().any(|a| is_private_ip(a.ip())) {
            return Checked::PrivateHost;
        }
        builder = builder.resolve_to_addrs(&host, &addrs);
    }
    let Ok(client) = builder.build() else {
        return Checked::Unreachable;
    };
    let mut request = if post { client.post(url) } else { client.get(url) };
    for (name, value) in headers {
        request = request.header(name, value);
    }
    match request.send().await {
        Ok(response) => classify(response.status().as_u16(), rejects),
        Err(_) => Checked::Unreachable,
    }
}

/// What an HTTP status says of a key.
pub fn classify(status: u16, rejects: &[u16]) -> Checked {
    match status {
        200..=299 => Checked::Accepted,
        s if rejects.contains(&s) => Checked::Rejected(s),
        _ => Checked::Unconfirmed(status),
    }
}

/// The catalog as `_acpmux/connections` lists it (`providers`).
pub fn listed() -> Value {
    Value::Array(
        PROVIDERS
            .iter()
            .map(|p| {
                let families = endpoints(p, None).families();
                let named = p.group == Group::Custom;
                json!({
                    "id": p.id,
                    "label": p.label,
                    "group": p.group,
                    "console": p.console,
                    "fields": p.fields,
                    "families": families,
                    "protocols": if named { json!(Protocol::ALL) } else { json!([]) },
                    "checked": p.check.is_some(),
                    "serves_cloud": p.unavailable.is_none() && (named || !families.is_empty()),
                    "unavailable": p.unavailable,
                })
            })
            .collect(),
    )
}

/// The launch credential's variables for a provider connection (Revision 3): the key and where
/// it goes. Revision 2's kinds (an Anthropic or OpenAI key alone) keep their one variable.
pub mod wire {
    pub const KEY: &str = "CMUX_PROVIDER_API_KEY";
    pub const ID: &str = "CMUX_PROVIDER_ID";
    pub const ANTHROPIC_URL: &str = "CMUX_PROVIDER_ANTHROPIC_URL";
    pub const ANTHROPIC_AUTH: &str = "CMUX_PROVIDER_ANTHROPIC_AUTH";
    pub const RESPONSES_URL: &str = "CMUX_PROVIDER_RESPONSES_URL";
    pub const REGION: &str = "CMUX_PROVIDER_REGION";
    /// Every name a provider credential may carry.
    pub const NAMES: [&str; 6] = [KEY, ID, ANTHROPIC_URL, ANTHROPIC_AUTH, RESPONSES_URL, REGION];
}

/// The env a Cloud machine's agent launches on for provider `id` with `key` (the delivery half
/// of `_acpmux/connections/credential`).
pub fn delivery(id: &str, endpoints: &Endpoints, key: String) -> Vec<(&'static str, String)> {
    let mut env = vec![(wire::KEY, key), (wire::ID, id.to_owned())];
    if let Some((base, auth)) = &endpoints.anthropic {
        if *auth != AnthropicAuth::Bedrock {
            env.push((wire::ANTHROPIC_URL, base.clone()));
        }
        env.push((wire::ANTHROPIC_AUTH, auth.as_str().to_owned()));
    }
    if let Some(base) = &endpoints.responses {
        env.push((wire::RESPONSES_URL, base.clone()));
    }
    if let Some(region) = &endpoints.region {
        env.push((wire::REGION, region.clone()));
    }
    env
}

/// The variables OpenCode reads provider `id`'s key from on the machine, from this catalog
/// (a launch credential names a provider, never a variable).
/// The AWS region a Bedrock route keeps in its `health_url` (`https://bedrock-mantle.REGION.api.aws/v1/models`).
pub fn bedrock_region(url: &str) -> Option<&str> {
    url.strip_prefix("https://bedrock-mantle.")?.split_once(".api.aws/")?.0.into()
}

pub fn opencode_env(id: &str) -> Option<OpenCode> {
    find(id).and_then(|p| p.opencode)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn every_issue_provider_is_listed_once_with_a_way_to_cloud_or_a_reason() {
        let mut seen = std::collections::BTreeSet::new();
        for p in PROVIDERS {
            assert!(seen.insert(p.id), "{} twice", p.id);
            let families = endpoints(p, None).families();
            let named = p.group == Group::Custom;
            assert!(
                p.unavailable.is_some() || named || !families.is_empty(),
                "{} reaches no Cloud agent",
                p.id
            );
            // Only a provider whose model list answers any caller goes unchecked.
            assert_eq!(
                p.check.is_none() && p.unavailable.is_none(),
                matches!(p.id, "nvidia" | "opencode-go"),
                "{}",
                p.id
            );
            for url in [p.anthropic.map(|a| a.base), p.responses].into_iter().flatten() {
                if !url.is_empty() {
                    assert_eq!(check_base_url(url).as_deref(), Ok(url), "{}", p.id);
                }
            }
        }
        for id in [
            "supergrok",
            "github-copilot",
            "opencode-go",
            "glm",
            "ollama-cloud",
            "kimi-code",
            "morph",
            "anthropic",
            "openai",
            "openrouter",
            "google",
            "xai",
            "baseten",
            "vercel",
            "nvidia",
            "fireworks",
            "bedrock",
            "meta",
            "cloudflare",
            "neon",
            "ramp",
            "together",
            "deepinfra",
            "custom",
        ] {
            assert!(find(id).is_some(), "{id}");
        }
    }

    #[test]
    fn a_named_endpoint_is_https_with_nothing_a_key_could_hide_in() {
        assert_eq!(
            check_base_url("https://gateway.ai.cloudflare.com/v1/acc/gw/anthropic/").as_deref(),
            Ok("https://gateway.ai.cloudflare.com/v1/acc/gw/anthropic")
        );
        for bad in [
            "http://llm.example.com",
            "http://localhost:8080",
            "https://u:p@llm.example.com",
            "https://llm.example.com/v1?key=abc",
            "https://llm.example.com/#x",
            "https://llm.example.com/sk-ant-api03-abcdefghijklmnopqrstuvwxyz0123456789",
            "https://llm.example.com/a b",
            "ftp://llm.example.com",
            // This machine, a private network, cloud metadata or a tailnet never gets the key.
            "https://127.0.0.1:8443",
            "https://localhost",
            "https://10.0.0.5/v1",
            "https://192.168.1.2",
            "https://169.254.169.254/latest",
            "https://100.89.225.106:31415",
            "https://[::1]/v1",
            "https://[fd00::1]",
            "https://[::ffff:10.0.0.1]",
            "https://coderouter.cmux.internal",
            "https://box.tail137216.ts.net",
            "https://intranet",
        ] {
            assert!(check_base_url(bad).is_err(), "{bad}");
        }
        assert!(check_base_url("https://8.8.8.8/v1").is_ok());
        for private in [
            "127.0.0.1",
            "10.1.2.3",
            "169.254.169.254",
            "100.100.1.1",
            "::1",
            "fe80::1",
            "::ffff:192.168.0.1",
        ] {
            assert!(is_private_ip(private.parse().unwrap()), "{private}");
        }
        assert!(
            !is_private_ip("1.1.1.1".parse().unwrap())
                && !is_private_ip("2606:4700::1111".parse().unwrap())
        );
        // A real gateway path (a Cloudflare account id is 32 hex characters) is not a key.
        let gateway =
            "https://gateway.ai.cloudflare.com/v1/0123456789abcdef0123456789abcdef/main/anthropic";
        assert_eq!(check_base_url(gateway).as_deref(), Ok(gateway));
    }

    /// The page reads the catalog's field names as they are listed (`base-url`, `region`).
    #[test]
    fn the_listed_catalog_names_its_fields_as_the_page_reads_them() {
        let listed = listed();
        let fields = |id: &str| {
            listed.as_array().unwrap().iter().find(|p| p["id"] == id).unwrap()["fields"].clone()
        };
        assert_eq!(fields("custom"), serde_json::json!(["base-url"]));
        assert_eq!(fields("bedrock"), serde_json::json!(["region"]));
        let custom = listed.as_array().unwrap().iter().find(|p| p["id"] == "custom").unwrap();
        assert_eq!(custom["group"], "custom");
        assert_eq!(
            custom["protocols"],
            serde_json::json!(["anthropic", "anthropic-bearer", "responses"])
        );
    }

    #[test]
    fn regions_are_aws_regions() {
        for ok in ["us-east-1", "eu-central-1", "us-gov-west-1", "ap-southeast-2"] {
            assert_eq!(check_region(ok).as_deref(), Ok(ok));
        }
        for bad in ["", "us", "US-EAST-1", "us-east-x", "us-east-1;rm", "a-b-c-d-1"] {
            assert!(check_region(bad).is_err(), "{bad}");
        }
    }

    #[test]
    fn statuses_read_as_a_key_answer() {
        assert_eq!(classify(200, AUTH), Checked::Accepted);
        assert_eq!(classify(401, AUTH), Checked::Rejected(401));
        assert_eq!(classify(403, AUTH), Checked::Rejected(403));
        assert_eq!(classify(400, AUTH), Checked::Unconfirmed(400));
        assert_eq!(classify(404, AUTH), Checked::Unconfirmed(404));
        assert_eq!(classify(429, AUTH), Checked::Unconfirmed(429));
        // Google and xAI answer a wrong key with a 400.
        let google = find("google").unwrap();
        let request = check_request(google, &endpoints(google, None), "AIza-x").unwrap();
        assert_eq!(classify(400, request.rejects), Checked::Rejected(400));
        assert_eq!(request.headers, vec![("x-goog-api-key", "AIza-x".to_owned())]);
    }

    #[test]
    fn a_check_sends_the_key_only_in_its_header() {
        let or = find("openrouter").unwrap();
        let request = check_request(or, &endpoints(or, None), "sk-or-1").unwrap();
        assert_eq!(request.url, "https://openrouter.ai/api/v1/key");
        assert_eq!(request.headers, vec![("authorization", "Bearer sk-or-1".to_owned())]);
        assert!(!request.url.contains("sk-or-1"));
        let bedrock = find("bedrock").unwrap();
        assert!(check_request(bedrock, &endpoints(bedrock, None), "k").is_none(), "no region");
        let request = check_request(bedrock, &endpoints(bedrock, Some("eu-west-1")), "k").unwrap();
        assert_eq!(request.url, "https://bedrock-mantle.eu-west-1.api.aws/v1/models");
        let ollama = check_request(
            find("ollama-cloud").unwrap(),
            &endpoints(find("ollama-cloud").unwrap(), None),
            "k",
        );
        assert!(ollama.unwrap().post);
        let custom = find("custom").unwrap();
        let named = named_endpoints("https://llm.example.com/v1", Protocol::Responses);
        assert_eq!(
            check_request(custom, &named, "k").unwrap().url,
            "https://llm.example.com/v1/models"
        );
        let named = named_endpoints("https://gw.example.com/anthropic", Protocol::Anthropic);
        let request = check_request(custom, &named, "k").unwrap();
        assert_eq!(request.url, "https://gw.example.com/anthropic/v1/models");
        assert!(request.headers.contains(&("x-api-key", "k".to_owned())));
        assert!(
            check_request(find("nvidia").unwrap(), &endpoints(find("nvidia").unwrap(), None), "k")
                .is_none()
        );
    }

    #[test]
    fn delivery_names_the_key_once_and_the_endpoints_beside_it() {
        let or = find("openrouter").unwrap();
        let env = delivery("openrouter", &endpoints(or, None), "sk-or-1".into());
        let get = |n: &str| env.iter().find(|(k, _)| *k == n).map(|(_, v)| v.as_str());
        assert_eq!(get(wire::KEY), Some("sk-or-1"));
        assert_eq!(get(wire::ID), Some("openrouter"));
        assert_eq!(get(wire::ANTHROPIC_URL), Some("https://openrouter.ai/api"));
        assert_eq!(get(wire::ANTHROPIC_AUTH), Some("bearer"));
        assert_eq!(get(wire::RESPONSES_URL), Some("https://openrouter.ai/api/v1"));
        assert_eq!(env.iter().filter(|(_, v)| v == "sk-or-1").count(), 1);
        let bedrock = find("bedrock").unwrap();
        let env = delivery("bedrock", &endpoints(bedrock, Some("us-west-2")), "k".into());
        assert!(env.iter().all(|(k, _)| *k != wire::ANTHROPIC_URL));
        assert!(env.contains(&(wire::ANTHROPIC_AUTH, "bedrock".into())));
        assert!(env.contains(&(wire::REGION, "us-west-2".into())));
        for (name, _) in env {
            assert!(wire::NAMES.contains(&name));
        }
    }
}
