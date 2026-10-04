//! The control-plane router: app registry, namespace reservations,
//! provider admission, page registrations, interface listing, and
//! capability-token minting.
//!
//! The router answers only `cmux.router.*` calls. It never forwards a call,
//! event or byte stream to a provider: pages and peers reach providers at
//! the endpoints the router hands out, and providers verify tokens offline,
//! so a router restart does not break open data-plane connections.

mod control;
pub mod ops;
mod pages;
#[cfg(unix)]
mod serve;

use std::collections::{BTreeMap, HashMap};
use std::sync::{Arc, Mutex, MutexGuard};
use std::time::Duration;

use base64::Engine;
use base64::engine::general_purpose::URL_SAFE_NO_PAD;
use cmux_local_auth::{parse_origin, tokens_match};

pub use pages::{DATA_TOKEN_TTL, PAGE_TOKEN_TTL, page_origin};
#[cfg(unix)]
pub use serve::{ROUTER_FD_ENV, connect_inherited, listen};

use crate::error::{self, ErrorBody};
use crate::ir::Catalog;
use crate::token::{Claims, SigningKey};
use ops::{
    Endpoint, EndpointKind, InterfaceListing, InterfacesListResult, NO_PROVIDER, PROTO,
    ProviderHello, ProviderInfo, ProviderWelcome, REFUSED,
};

/// Longest token lifetime the router mints.
pub const MAX_TOKEN_TTL: Duration = Duration::from_secs(15 * 60);

/// An installed app: its credential for self-started providers and the
/// scopes its surfaces may be granted.
#[derive(Debug, Clone)]
pub struct AppRecord {
    pub app_id: String,
    pub credential: Option<String>,
    pub grants: Vec<String>,
}

/// How a control connection reached the router.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Admission {
    /// Spawned by the router for this app, over an inherited socketpair.
    Spawned(String),
    /// Connected to the router's unix socket; a provider must present its
    /// app credential.
    SelfStarted,
    /// A page that authenticated with its page token; it may resolve,
    /// refresh and list, never say hello.
    Page(Claims),
    /// The host (engine bridge) in the daemon's own process; the only
    /// caller of server-only router ops such as `cmux.router.gesture.mint`.
    Host,
}

#[derive(Debug, Clone)]
struct Live {
    app_id: String,
    namespaces: Vec<String>,
    interfaces: Vec<String>,
    endpoints: Vec<Endpoint>,
    ir_sha256: String,
}

impl Live {
    fn info(&self, namespace: &str) -> ProviderInfo {
        ProviderInfo {
            app_id: self.app_id.clone(),
            namespace: namespace.to_owned(),
            endpoints: self.endpoints.clone(),
        }
    }
}

#[derive(Default)]
struct State {
    apps: HashMap<String, AppRecord>,
    /// Namespace -> owning app id. First-party namespaces are owned by `cmux`.
    reservations: HashMap<String, String>,
    /// Connection id -> admitted provider.
    live: HashMap<u64, Live>,
    /// Page id -> registration.
    pages: BTreeMap<String, pages::Page>,
}

impl State {
    fn live_for(&self, name: &str) -> Option<(&Live, &String)> {
        self.live
            .values()
            .find_map(|live| Some((live, live.namespaces.iter().find(|ns| within(name, ns))?)))
    }
}

pub struct Router {
    key: SigningKey,
    catalog: Catalog,
    /// Hex SHA-256 of the catalog's IR text; first-party hellos must match.
    digest: String,
    state: Mutex<State>,
}

/// A request to mint a data-plane token for a surface.
#[derive(Debug, Clone)]
pub struct MintRequest {
    pub sub: String,
    pub app: String,
    pub ns: Vec<String>,
    pub scopes: Vec<String>,
    /// Workspace roots; canonicalized at mint (decision 20).
    pub roots: Vec<String>,
    pub origin: Option<String>,
    pub aud: String,
    pub ttl: Duration,
}

fn refused(message: impl Into<String>) -> ErrorBody {
    ErrorBody::new(REFUSED, message)
}

fn forbidden(message: impl Into<String>) -> ErrorBody {
    ErrorBody::new(error::FORBIDDEN, message)
}

/// `inner` is `outer` or sits below it (`cmux.git` inside `cmux`).
pub fn within(inner: &str, outer: &str) -> bool {
    inner == outer
        || (inner.len() > outer.len()
            && inner.starts_with(outer)
            && inner.as_bytes()[outer.len()] == b'.')
}

fn first_party(app_id: &str) -> bool {
    within(app_id, "cmux")
}

/// The reservation owner of an app's namespaces.
fn owner(app_id: &str) -> &str {
    if first_party(app_id) { "cmux" } else { app_id }
}

/// An app id, which is also the app's namespace: `cmux` or `cmux.<name>`
/// for first party, `<publisher>.<name>` for a third party (see
/// [`namespace_for`]). Labels are `[a-z0-9_]`, starting with a letter or
/// digit.
pub fn valid_app_id(app_id: &str) -> bool {
    let labels: Vec<&str> = app_id.split('.').collect();
    let label_ok = |label: &&str| {
        label.as_bytes().first().is_some_and(u8::is_ascii_alphanumeric)
            && label.bytes().all(|byte| matches!(byte, b'a'..=b'z' | b'0'..=b'9' | b'_'))
    };
    app_id.len() <= 128 && labels.iter().all(label_ok) && (first_party(app_id) || labels.len() >= 2)
}

/// The namespace of third-party app `<publisher>/<name>`: lowercase, `-`
/// becomes `_`, `/` becomes `.` (`octo/diff-tools` is `octo.diff_tools`).
pub fn namespace_for(app: &str) -> String {
    app.to_ascii_lowercase().replace('-', "_").replace('/', ".")
}

fn loopback_endpoint(endpoint: &Endpoint) -> bool {
    match endpoint.kind {
        EndpointKind::Unix => endpoint.path.as_deref().is_some_and(|path| path.starts_with('/')),
        EndpointKind::Ws => endpoint.url.as_deref().is_some_and(|url| {
            ["ws://127.0.0.1:", "ws://localhost:", "ws://[::1]:"]
                .iter()
                .any(|prefix| url.starts_with(prefix))
        }),
    }
}

/// Canonicalize workspace roots for a token: each must be an absolute path
/// to an existing directory; symlinks are resolved so the claim names the
/// real directory.
pub fn canonical_roots(roots: &[String]) -> Result<Vec<String>, ErrorBody> {
    roots
        .iter()
        .map(|root| {
            let bad = || {
                ErrorBody::new(
                    error::INVALID_PARAMS,
                    format!("root {root:?} is not an absolute directory"),
                )
            };
            let path = std::path::Path::new(root);
            if !path.is_absolute() {
                return Err(bad());
            }
            let canonical = std::fs::canonicalize(path).map_err(|_| bad())?;
            if !canonical.is_dir() {
                return Err(bad());
            }
            canonical.into_os_string().into_string().map_err(|_| bad())
        })
        .collect()
}

fn normalized_origin(origin: Option<&str>) -> Result<Option<String>, ErrorBody> {
    origin
        .map(|raw| {
            parse_origin(raw)
                .ok_or_else(|| ErrorBody::new(error::INVALID_PARAMS, format!("bad origin {raw:?}")))
        })
        .transpose()
}

impl Router {
    pub fn new(key: SigningKey, catalog: Catalog) -> Arc<Self> {
        let digest = catalog.digest();
        Arc::new(Self { key, catalog, digest, state: Mutex::default() })
    }

    fn state(&self) -> MutexGuard<'_, State> {
        self.state.lock().unwrap_or_else(|poisoned| poisoned.into_inner())
    }

    pub fn public_key(&self) -> [u8; 32] {
        self.key.public_key()
    }

    pub fn catalog(&self) -> &Catalog {
        &self.catalog
    }

    /// Hex SHA-256 of the router's IR.
    pub fn ir_digest(&self) -> &str {
        &self.digest
    }

    /// Install an app. App ids are unique; a second record for the same id
    /// is refused.
    pub fn register_app(&self, record: AppRecord) -> Result<(), ErrorBody> {
        if !valid_app_id(&record.app_id) {
            return Err(refused(format!("{} is not a valid app id", record.app_id)));
        }
        let mut state = self.state();
        if state.apps.contains_key(&record.app_id) {
            return Err(refused(format!("app id {} is already registered", record.app_id)));
        }
        state.apps.insert(record.app_id.clone(), record);
        Ok(())
    }

    fn check_identity(
        &self,
        state: &State,
        admission: &Admission,
        hello: &ProviderHello,
    ) -> Result<(), ErrorBody> {
        if hello.proto != PROTO {
            return Err(refused(format!("protocol {:?} is not {PROTO}", hello.proto)));
        }
        let app = state
            .apps
            .get(&hello.app)
            .ok_or_else(|| refused(format!("unknown app {}", hello.app)))?;
        match admission {
            Admission::Spawned(app_id) if *app_id != hello.app => {
                Err(refused(format!("spawned as {app_id}, said hello as {}", hello.app)))
            }
            Admission::Spawned(_) => Ok(()),
            Admission::SelfStarted => {
                let presented = hello.credential.as_deref().unwrap_or_default();
                let expected = app.credential.as_deref().unwrap_or_default();
                if tokens_match(presented, expected) {
                    Ok(())
                } else {
                    Err(refused("missing or wrong app credential"))
                }
            }
            Admission::Page(_) => Err(forbidden("a page cannot say hello")),
            Admission::Host => Err(forbidden("the host connection does not say hello")),
        }
    }

    fn check_namespaces(&self, state: &State, hello: &ProviderHello) -> Result<(), ErrorBody> {
        if hello.namespaces.is_empty() {
            return Err(refused("no namespaces"));
        }
        for ns in &hello.namespaces {
            let allowed =
                if first_party(&hello.app) { within(ns, "cmux") } else { within(ns, &hello.app) };
            if !allowed {
                return Err(refused(format!("{} may not serve namespace {ns}", hello.app)));
            }
            if let Some(holder) = state.reservations.get(ns)
                && holder != owner(&hello.app)
            {
                return Err(refused(format!("namespace {ns} is reserved by {holder}")));
            }
            let mut live_namespaces = state.live.values().flat_map(|live| &live.namespaces);
            if let Some(other) =
                live_namespaces.find(|other| within(ns, other) || within(other, ns))
            {
                return Err(refused(format!("namespace {ns} overlaps live namespace {other}")));
            }
        }
        Ok(())
    }

    fn check_served(&self, hello: &ProviderHello) -> Result<(), ErrorBody> {
        // A first-party provider is built from this tree, so its IR must
        // be exactly the router's. A third party serves its own fragment,
        // validated separately; its digest is only recorded.
        if first_party(&hello.app) && hello.ir.sha256 != self.digest {
            let body = ErrorBody::new(
                error::BAD_MESSAGE,
                format!(
                    "{} was built from IR {}, the router serves {}",
                    hello.app, hello.ir.sha256, self.digest
                ),
            );
            return Err(body.with_details(serde_json::json!({ "reason": "ir_mismatch" })));
        }
        let inside = |name: &str| hello.namespaces.iter().any(|ns| within(name, ns) && name != ns);
        for op in &hello.ops {
            crate::envelope::check_name(&op.name)
                .map_err(|problem| refused(problem.to_string()))?;
            if !inside(&op.name) {
                return Err(refused(format!(
                    "op {} is outside the provider's namespaces",
                    op.name
                )));
            }
            if first_party(&hello.app) {
                let declared = self
                    .catalog
                    .op_decl(&op.name)
                    .ok_or_else(|| refused(format!("op {} is not in the IR", op.name)))?;
                let kind = serde_json::to_value(declared.kind).unwrap_or_default();
                if kind != op.kind.as_str() || declared.scope != op.scope {
                    return Err(refused(format!(
                        "op {} does not match its IR kind and scope",
                        op.name
                    )));
                }
            }
        }
        for event in &hello.events {
            if !inside(&event.name) {
                return Err(refused(format!(
                    "event {} is outside the provider's namespaces",
                    event.name
                )));
            }
            if first_party(&hello.app)
                && self.catalog.event_decl(&event.name).is_none_or(|e| e.scope != event.scope)
            {
                return Err(refused(format!("event {} does not match the IR", event.name)));
            }
        }
        let known = |name: &&String| {
            self.catalog.interfaces().iter().any(|interface| interface.name == **name)
        };
        if let Some(unknown) = hello.interfaces.iter().find(|name| !known(name)) {
            return Err(refused(format!("unknown interface {unknown}")));
        }
        if let Some(endpoint) = hello.endpoints.iter().find(|endpoint| !loopback_endpoint(endpoint))
        {
            return Err(refused(format!("endpoint {endpoint:?} is not loopback")));
        }
        Ok(())
    }

    /// Admit connection `conn` as a provider, or say why not.
    pub fn admit(
        &self,
        conn: u64,
        admission: &Admission,
        hello: ProviderHello,
    ) -> Result<ProviderWelcome, ErrorBody> {
        let mut state = self.state();
        self.check_identity(&state, admission, &hello)?;
        if state.live.contains_key(&conn) {
            return Err(refused("this connection already said hello"));
        }
        self.check_namespaces(&state, &hello)?;
        self.check_served(&hello)?;
        for ns in &hello.namespaces {
            state.reservations.insert(ns.clone(), owner(&hello.app).to_owned());
        }
        let welcome = ProviderWelcome {
            router_key: URL_SAFE_NO_PAD.encode(self.key.public_key()),
            provider: hello.app.clone(),
        };
        let live = Live {
            app_id: hello.app,
            namespaces: hello.namespaces,
            interfaces: hello.interfaces,
            endpoints: hello.endpoints,
            ir_sha256: hello.ir.sha256,
        };
        state.live.insert(conn, live);
        Ok(welcome)
    }

    /// Forget connection `conn` (its reservations stay).
    pub fn disconnect(&self, conn: u64) {
        self.state().live.remove(&conn);
    }

    /// Known interfaces (optionally only `name`) and the live providers
    /// implementing each (for their first namespace).
    pub fn interfaces_list(&self, name: Option<&str>) -> InterfacesListResult {
        let state = self.state();
        let interfaces = self
            .catalog
            .interfaces()
            .iter()
            .filter(|interface| name.is_none_or(|name| interface.name == name))
            .map(|interface| {
                let mut providers: Vec<ProviderInfo> = state
                    .live
                    .values()
                    .filter(|live| live.interfaces.contains(&interface.name))
                    .filter_map(|live| Some(live.info(live.namespaces.first()?)))
                    .collect();
                providers.sort_by(|a, b| a.namespace.cmp(&b.namespace));
                InterfaceListing {
                    name: interface.name.clone(),
                    version: interface.version,
                    providers,
                }
            })
            .collect();
        InterfacesListResult { interfaces }
    }

    /// The live provider serving a namespace or op name.
    pub fn provider_of(&self, name: &str) -> Result<ProviderInfo, ErrorBody> {
        let state = self.state();
        let (live, ns) = state.live_for(name).ok_or_else(|| {
            ErrorBody::new(NO_PROVIDER, format!("no live provider serves {name}"))
        })?;
        Ok(live.info(ns))
    }

    fn sign_data(&self, state: &State, claims: Claims) -> Result<String, ErrorBody> {
        for ns in &claims.ns {
            let owned = state
                .reservations
                .iter()
                .any(|(reserved, holder)| holder == owner(&claims.aud) && within(ns, reserved));
            if !owned {
                return Err(forbidden(format!("namespace {ns} does not belong to {}", claims.aud)));
            }
        }
        Ok(self.key.sign(&claims))
    }

    /// Mint a data-plane token for a surface of `app`, for provider `aud`.
    /// Scopes must be granted to the app, and every namespace must belong
    /// to `aud`. The host calls this; pages get theirs from resolve.
    pub fn mint(&self, request: MintRequest) -> Result<String, ErrorBody> {
        if request.ttl.is_zero() || request.ttl > MAX_TOKEN_TTL {
            return Err(ErrorBody::new(
                error::INVALID_PARAMS,
                "ttl must be between 1 s and 15 min",
            ));
        }
        let origin = normalized_origin(request.origin.as_deref())?;
        let state = self.state();
        let app = state.apps.get(&request.app).ok_or_else(|| forbidden("unknown app"))?;
        if let Some(scope) = request.scopes.iter().find(|scope| !app.grants.contains(scope)) {
            return Err(forbidden(format!("{} is not granted {scope}", request.app)));
        }
        let iat = crate::token::now();
        let claims = Claims {
            sub: request.sub,
            page: None,
            app: request.app,
            ns: request.ns,
            scopes: request.scopes,
            roots: canonical_roots(&request.roots)?,
            origin,
            aud: request.aud,
            exp: iat + request.ttl.as_secs(),
            iat,
        };
        self.sign_data(&state, claims)
    }
}

#[cfg(test)]
mod tests;
