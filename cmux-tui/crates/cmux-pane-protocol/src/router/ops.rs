//! The router's control-plane ops (`cmux.router.*`).

use schemars::JsonSchema;
use serde::{Deserialize, Serialize};

pub const REFUSED: &str = "cmux.router.refused";
pub const NO_PROVIDER: &str = "cmux.router.no_provider";

/// The protocol version a provider sends in hello.
pub const PROTO: &str = "cmux.pane/0";

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
#[serde(rename_all = "lowercase")]
pub enum EndpointKind {
    /// `url` is `ws://<loopback>:<port>/<path>`.
    Ws,
    /// `path` is an absolute unix socket path.
    Unix,
}

/// How a page or peer reaches a provider directly.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct Endpoint {
    pub kind: EndpointKind,
    /// The socket path, for `unix`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub path: Option<String>,
    /// The WebSocket URL, for `ws`.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub url: Option<String>,
}

impl Endpoint {
    pub fn ws(url: impl Into<String>) -> Self {
        Self { kind: EndpointKind::Ws, path: None, url: Some(url.into()) }
    }

    pub fn unix(path: impl Into<String>) -> Self {
        Self { kind: EndpointKind::Unix, path: Some(path.into()), url: None }
    }
}

/// One op a provider serves.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct HelloOpRef {
    pub name: String,
    /// `read`, `mutation` or `stream`.
    pub kind: String,
    pub scope: String,
}

/// One event stream a provider serves.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct HelloEventRef {
    pub name: String,
    pub scope: String,
}

/// The IR (or IR fragment) a provider was generated from.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct HelloIr {
    pub version: String,
    /// Lowercase hex SHA-256 of the IR file.
    pub sha256: String,
}

/// A provider's admission request, its first call on the router connection.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct ProviderHello {
    /// [`PROTO`].
    pub proto: String,
    /// The app id: `cmux` or `cmux.<name>` first party, `<publisher>.<name>`
    /// third party.
    pub app: String,
    /// Namespaces the provider serves; each is its app id or below it.
    pub namespaces: Vec<String>,
    /// Every op the provider serves; each must sit inside `namespaces`.
    pub ops: Vec<HelloOpRef>,
    #[serde(default)]
    pub events: Vec<HelloEventRef>,
    /// Interfaces (`cmux.diff.source/1`) it implements for its first namespace.
    #[serde(default)]
    pub interfaces: Vec<String>,
    pub ir: HelloIr,
    /// Where pages connect to it (data plane).
    #[serde(default)]
    pub endpoints: Vec<Endpoint>,
    /// The app credential; required on the router's socket, unused on an
    /// inherited socketpair.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub credential: Option<String>,
}

/// The router's admission reply.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct ProviderWelcome {
    /// Unpadded base64url Ed25519 public key that signs capability tokens.
    pub router_key: String,
    /// The provider's id, which is the `aud` of tokens for it (its app id).
    pub provider: String,
}

/// A live provider of a namespace.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct ProviderInfo {
    pub app_id: String,
    pub namespace: String,
    pub endpoints: Vec<Endpoint>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct ResolveParams {
    /// A namespace (or an op name inside one).
    pub namespace: String,
}

/// Where to reach the namespace's provider, and a data-plane token for it.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
#[serde(deny_unknown_fields)]
#[schemars(transform = crate::ir::require_all)]
pub struct ResolveResult {
    pub app_id: String,
    pub namespace: String,
    pub endpoint: Endpoint,
    /// Hex SHA-256 of the IR (fragment) the provider serves, from its hello;
    /// a client fetches that schema once to validate the namespace.
    pub ir: String,
    /// A token with `aud` = `app_id`, for a page connection; null for a
    /// native peer on the router socket, which mints through its host.
    #[serde(deserialize_with = "crate::ir::nullable")]
    pub token: Option<String>,
    /// The token's expiry, unix seconds.
    #[serde(deserialize_with = "crate::ir::nullable")]
    pub exp: Option<u64>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct TokenRefreshParams {
    /// A page token or a data-plane token the router minted, not yet expired.
    pub token: String,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct TokenRefreshResult {
    pub token: String,
    pub exp: u64,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct InterfacesListParams {
    /// Only this interface (`cmux.diff.source/1`).
    #[serde(default)]
    pub name: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct InterfaceListing {
    pub name: String,
    pub version: u32,
    /// Live providers implementing it.
    pub providers: Vec<ProviderInfo>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct InterfacesListResult {
    pub interfaces: Vec<InterfaceListing>,
}

/// Who serves a page's namespace.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
#[serde(tag = "kind", rename_all = "kebab-case", deny_unknown_fields)]
pub enum PageProvider {
    /// Rust, inside the cmux-tui daemon.
    DaemonModule,
    /// Spawned by the router with a socketpair fd.
    Process {
        command: String,
        #[serde(default)]
        args: Vec<String>,
    },
    /// Self-started; connects to the router socket with an app credential.
    External,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
#[serde(rename_all = "lowercase")]
pub enum PageEngine {
    Webkit,
    Cef,
    Browser,
}

/// A page registration (manifest entry).
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct PageManifest {
    /// `cmux.settings`; third party `<publisher>.<name>[.<page>]`.
    pub id: String,
    /// `/settings`.
    pub route: String,
    /// The page's HTML entry, relative to the app.
    pub entry: String,
    /// The ops the page's backend serves.
    pub namespace: String,
    pub provider: PageProvider,
    /// Interfaces (`name/major`) and ops the page may call.
    #[serde(default)]
    pub consumes: Vec<String>,
    #[serde(default)]
    pub scopes: Vec<String>,
    #[serde(default)]
    pub engines: Vec<PageEngine>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct PagesListParams {}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, JsonSchema)]
#[serde(deny_unknown_fields)]
pub struct PagesListResult {
    pub pages: Vec<PageManifest>,
}

crate::pane_op! {
    /// Admit the calling connection as a provider.
    pub HelloOp {
        name: "cmux.router.hello", kind: Mutation, scope: "router:control",
        params: ProviderHello, result: ProviderWelcome,
        errors: ["cmux.router.refused"],
        risk: MutateShared,
        mcp: Never,
    }
}

crate::pane_op! {
    /// The live provider of a namespace, and a data-plane token for it.
    pub ResolveOp {
        name: "cmux.router.resolve", kind: Read, scope: "router:read",
        params: ResolveParams, result: ResolveResult,
        errors: ["cmux.router.no_provider"],
        mcp: Never,
    }
}

crate::pane_op! {
    /// Renew a page token or a data-plane token before it expires.
    pub TokenRefreshOp {
        name: "cmux.router.token.refresh", kind: Mutation, scope: "router:write",
        params: TokenRefreshParams, result: TokenRefreshResult,
        errors: [],
        risk: MutateOwn,
        mcp: Never,
    }
}

crate::pane_op! {
    /// Known interfaces and the live providers implementing each.
    pub InterfacesListOp {
        name: "cmux.router.interfaces.list", kind: Read, scope: "router:read",
        params: InterfacesListParams, result: InterfacesListResult,
        errors: [],
        mcp: Never,
    }
}

crate::pane_op! {
    /// Registered pages.
    pub PagesListOp {
        name: "cmux.router.pages.list", kind: Read, scope: "router:read",
        params: PagesListParams, result: PagesListResult,
        errors: [],
        mcp: Never,
    }
}
