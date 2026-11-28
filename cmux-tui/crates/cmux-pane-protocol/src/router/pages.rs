//! Pages (spec "Pages"): registration, page tokens, and the page-facing
//! control ops (resolve with a data-plane token, token refresh, listing).
//!
//! A page token has `page` set and `aud` = `router`. With it a page asks
//! `cmux.router.resolve {namespace}` for `{endpoint, token}`, where the
//! token's `aud` is that namespace's provider, then talks to the provider
//! directly. A bundled page's origin is `cmux-page://<page id>`; in dev it is
//! the loopback dev origin.

use std::time::Duration;

use super::ops::{EndpointKind, PageManifest, PagesListResult, ResolveResult, TokenRefreshResult};
use super::{Admission, Router, State, first_party, forbidden, normalized_origin, refused, within};
use crate::error::{self, ErrorBody};
use crate::token::{Claims, ROUTER_AUDIENCE, verify_signature};

/// Lifetime of a page token, and of each refresh.
pub const PAGE_TOKEN_TTL: Duration = Duration::from_secs(10 * 60);
/// Lifetime of a data-plane token from resolve, and of each refresh.
pub const DATA_TOKEN_TTL: Duration = Duration::from_secs(10 * 60);

/// The bundled origin of page `id`.
pub fn page_origin(id: &str) -> String {
    format!("cmux-page://{id}")
}

#[derive(Debug, Clone)]
pub(super) struct Page {
    app_id: String,
    manifest: PageManifest,
    /// The manifest's scopes plus the scopes of the IR ops it consumes.
    scopes: Vec<String>,
}

impl Page {
    /// Whether this page may use `namespace` served by a provider that
    /// implements `interfaces` there.
    fn may_use(&self, namespace: &str, provider_namespace: &str, interfaces: &[String]) -> bool {
        within(namespace, &self.manifest.namespace)
            || self.manifest.consumes.iter().any(|consumed| {
                if consumed.contains('/') {
                    interfaces.contains(consumed) && within(namespace, provider_namespace)
                } else {
                    within(consumed, namespace) && consumed != namespace
                }
            })
    }
}

impl Router {
    /// Register a page of installed app `app_id`. Its id and namespace must
    /// sit inside the app's namespace (first party: inside `cmux`). A third
    /// party page's scopes must all be granted to the app at install.
    pub fn register_page(&self, app_id: &str, manifest: PageManifest) -> Result<(), ErrorBody> {
        let mut state = self.state();
        let app = state.apps.get(app_id).ok_or_else(|| refused(format!("unknown app {app_id}")))?;
        let home = if first_party(app_id) { "cmux" } else { app_id };
        if !within(&manifest.id, home) || !within(&manifest.namespace, home) {
            return Err(refused(format!("page {} must sit inside namespace {home}", manifest.id)));
        }
        if !manifest.route.starts_with('/') {
            return Err(refused("a page route starts with /"));
        }
        let mut scopes = manifest.scopes.clone();
        for consumed in manifest.consumes.iter().filter(|consumed| !consumed.contains('/')) {
            let op = self
                .catalog
                .op_decl(consumed)
                .ok_or_else(|| refused(format!("page consumes unknown op {consumed}")))?;
            if !scopes.contains(&op.scope) {
                scopes.push(op.scope.clone());
            }
        }
        if !first_party(app_id)
            && let Some(scope) = scopes.iter().find(|scope| !app.grants.contains(scope))
        {
            return Err(refused(format!("{app_id} is not granted {scope}")));
        }
        if state.pages.contains_key(&manifest.id) {
            return Err(refused(format!("page {} is already registered", manifest.id)));
        }
        let page = Page { app_id: app_id.to_owned(), manifest: manifest.clone(), scopes };
        state.pages.insert(manifest.id, page);
        Ok(())
    }

    /// Mint the page token the engine bridge hands a page instance `sub`.
    /// `roots` are the instance's workspace roots; data tokens from resolve
    /// carry the same roots.
    /// `origin` is `cmux-page://<id>` for a bundled page, or the dev origin.
    pub fn mint_page_token(
        &self,
        page_id: &str,
        sub: &str,
        origin: Option<&str>,
        roots: &[String],
    ) -> Result<String, ErrorBody> {
        let roots = super::canonical_roots(roots)?;
        let origin = normalized_origin(origin)?;
        let state = self.state();
        let page =
            state.pages.get(page_id).ok_or_else(|| forbidden(format!("unknown page {page_id}")))?;
        let iat = crate::token::now();
        let claims = Claims {
            sub: sub.to_owned(),
            page: Some(page_id.to_owned()),
            app: page.app_id.clone(),
            ns: Vec::new(),
            scopes: page.scopes.clone(),
            roots,
            origin,
            aud: ROUTER_AUDIENCE.to_owned(),
            exp: iat + PAGE_TOKEN_TTL.as_secs(),
            iat,
        };
        Ok(self.key.sign(&claims))
    }

    pub fn pages_list(&self) -> PagesListResult {
        PagesListResult {
            pages: self.state().pages.values().map(|page| page.manifest.clone()).collect(),
        }
    }

    /// `cmux.router.resolve`: the provider of `namespace` and, for a page,
    /// a data-plane token for it.
    pub(super) fn resolve_for(
        &self,
        admission: &Admission,
        namespace: &str,
    ) -> Result<ResolveResult, ErrorBody> {
        let state = self.state();
        let (live, provider_namespace) = state.live_for(namespace).ok_or_else(|| {
            ErrorBody::new(super::ops::NO_PROVIDER, format!("no live provider serves {namespace}"))
        })?;
        let prefer = if matches!(admission, Admission::Page(_)) {
            EndpointKind::Ws
        } else {
            EndpointKind::Unix
        };
        let endpoint = live
            .endpoints
            .iter()
            .find(|endpoint| endpoint.kind == prefer)
            .or_else(|| live.endpoints.first())
            .cloned()
            .ok_or_else(|| {
                ErrorBody::new(super::ops::NO_PROVIDER, format!("{} has no endpoint", live.app_id))
            })?;
        let (token, exp) = match admission {
            Admission::Page(page_claims) => {
                let page = page_of(&state, page_claims)?;
                if !page.may_use(namespace, provider_namespace, &live.interfaces) {
                    return Err(forbidden(format!(
                        "page {} does not consume {namespace}",
                        page.manifest.id
                    )));
                }
                let iat = crate::token::now();
                let claims = Claims {
                    sub: page_claims.sub.clone(),
                    page: page_claims.page.clone(),
                    app: page.app_id.clone(),
                    ns: vec![namespace.to_owned()],
                    scopes: page.scopes.clone(),
                    roots: page_claims.roots.clone(),
                    origin: page_claims.origin.clone(),
                    aud: live.app_id.clone(),
                    exp: iat + DATA_TOKEN_TTL.as_secs(),
                    iat,
                };
                let exp = claims.exp;
                (Some(self.sign_data(&state, claims)?), Some(exp))
            }
            _ => (None, None),
        };
        Ok(ResolveResult {
            app_id: live.app_id.clone(),
            namespace: namespace.to_owned(),
            endpoint,
            ir: live.ir_sha256.clone(),
            token,
            exp,
        })
    }

    /// `cmux.router.token.refresh`: a fresh token with the same subject,
    /// rechecked against the page's current registration. A page may only
    /// refresh its own tokens.
    pub(super) fn refresh(
        &self,
        admission: &Admission,
        token: &str,
    ) -> Result<TokenRefreshResult, ErrorBody> {
        let old = verify_signature(&self.key.public_key(), token)
            .map_err(|problem| forbidden(problem.to_string()))?;
        let now = crate::token::now();
        if old.exp <= now {
            return Err(ErrorBody::new(
                error::TOKEN_EXPIRED,
                "token already expired; get a new page token",
            ));
        }
        if let Admission::Page(page_claims) = admission
            && (old.sub != page_claims.sub || old.page != page_claims.page)
        {
            return Err(forbidden("a page may only refresh its own tokens"));
        }
        let state = self.state();
        let mut fresh = old.clone();
        fresh.iat = now;
        if old.aud == ROUTER_AUDIENCE {
            let page = page_of(&state, &old)?;
            fresh.scopes = page.scopes.clone();
            fresh.exp = now + PAGE_TOKEN_TTL.as_secs();
            return Ok(TokenRefreshResult { exp: fresh.exp, token: self.key.sign(&fresh) });
        }
        if old.page.is_some() {
            let page = page_of(&state, &old)?;
            for ns in &old.ns {
                let (live, provider_namespace) = state
                    .live_for(ns)
                    .ok_or_else(|| forbidden(format!("no live provider serves {ns}")))?;
                if live.app_id != old.aud || !page.may_use(ns, provider_namespace, &live.interfaces)
                {
                    return Err(forbidden(format!(
                        "page {} may no longer use {ns}",
                        page.manifest.id
                    )));
                }
            }
            fresh.scopes.retain(|scope| page.scopes.contains(scope));
        }
        fresh.exp = now + DATA_TOKEN_TTL.as_secs();
        Ok(TokenRefreshResult { exp: fresh.exp, token: self.sign_data(&state, fresh)? })
    }
}

fn page_of<'a>(state: &'a State, claims: &Claims) -> Result<&'a Page, ErrorBody> {
    let id = claims.page.as_deref().ok_or_else(|| forbidden("not a page token"))?;
    state.pages.get(id).ok_or_else(|| forbidden(format!("page {id} is no longer registered")))
}
