//! One control connection: the `cmux.router.*` op handler. Anything else is
//! refused with `cmux.protocol.not_routed`: the router is not a relay.

use std::sync::Arc;
use std::sync::atomic::{AtomicU64, Ordering};

use cmux_local_auth::ListenerPolicy;
use serde_json::{Value, json};
use tokio::net::TcpListener;

use super::ops::{
    GestureMintOp, HelloOp, InterfacesListOp, InterfacesListParams, PagesListOp, ResolveOp,
    ResolveParams, TokenRefreshOp, TokenRefreshParams,
};
use super::{Admission, Router};
use crate::envelope::Role;
use crate::error::{self, ErrorBody};
use crate::op::Op;
use crate::rpc::{CallFuture, Handler, Peer};
use crate::token::{Claims, ROUTER_AUDIENCE, Verifier};
use crate::transport::Transport;

static NEXT_CONN: AtomicU64 = AtomicU64::new(1);

struct Control {
    router: Arc<Router>,
    conn: u64,
    admission: Admission,
    /// A page connection's current page-token expiry (moves on refresh).
    page_exp: AtomicU64,
}

fn decode<T: serde::de::DeserializeOwned>(params: Value) -> Result<T, ErrorBody> {
    serde_json::from_value(params).map_err(|e| ErrorBody::new(error::INVALID_PARAMS, e.to_string()))
}

fn encode<T: serde::Serialize>(value: T) -> Result<Value, ErrorBody> {
    serde_json::to_value(value).map_err(|e| ErrorBody::new(error::INVALID_RESULT, e.to_string()))
}

impl Control {
    fn answer(&self, op: &str, params: Value) -> Result<Value, ErrorBody> {
        if matches!(self.admission, Admission::Page(_))
            && self.page_exp.load(Ordering::Relaxed) <= crate::token::now()
        {
            return Err(ErrorBody::new(
                error::TOKEN_EXPIRED,
                "page token expired; reconnect with a new one",
            )
            .retryable());
        }
        let router = &self.router;
        match op {
            HelloOp::NAME => encode(router.admit(self.conn, &self.admission, decode(params)?)?),
            ResolveOp::NAME => {
                let params: ResolveParams = decode(params)?;
                encode(router.resolve_for(&self.admission, &params.namespace)?)
            }
            TokenRefreshOp::NAME => {
                let params: TokenRefreshParams = decode(params)?;
                let refreshed = router.refresh(&self.admission, &params.token)?;
                if let Admission::Page(claims) = &self.admission
                    && let Ok(fresh) =
                        crate::token::verify_signature(&router.public_key(), &refreshed.token)
                    && fresh.aud == ROUTER_AUDIENCE
                    && fresh.sub == claims.sub
                {
                    self.page_exp.store(fresh.exp, Ordering::Relaxed);
                }
                encode(refreshed)
            }
            InterfacesListOp::NAME => {
                let params: InterfacesListParams = decode(params)?;
                encode(router.interfaces_list(params.name.as_deref()))
            }
            GestureMintOp::NAME => match self.admission {
                Admission::Host => encode(router.mint_gesture(decode(params)?)?),
                _ => {
                    Err(ErrorBody::new(error::FORBIDDEN, "cmux.router.gesture.mint is server-only")
                        .with_details(serde_json::json!({ "reason": "server_only" })))
                }
            },
            PagesListOp::NAME => {
                let _: super::ops::PagesListParams = decode(params)?;
                encode(router.pages_list())
            }
            other if other.starts_with("cmux.router.") => {
                Err(ErrorBody::new(error::UNKNOWN_OP, format!("no router op {other}")))
            }
            other => Err(ErrorBody::new(
                error::NOT_ROUTED,
                format!(
                    "the router does not relay {other}; resolve its provider and connect to it"
                ),
            )),
        }
    }
}

impl Handler for Control {
    fn call(&self, op: String, params: Value, _gesture: Option<String>) -> CallFuture {
        let result = self.answer(&op, params);
        Box::pin(async move { result })
    }
}

impl Router {
    /// Serve one control connection (the router accepted it) until it
    /// closes, then drop whatever it registered.
    pub async fn serve_connection(self: Arc<Self>, transport: Transport, admission: Admission) {
        let conn = NEXT_CONN.fetch_add(1, Ordering::Relaxed);
        let page_exp = match &admission {
            Admission::Page(claims) => claims.exp,
            _ => u64::MAX,
        };
        let handler = Arc::new(Control {
            router: self.clone(),
            conn,
            admission,
            page_exp: AtomicU64::new(page_exp),
        });
        let (_peer, task) = Peer::start(transport, Role::Accepting, handler);
        let _ = task.await;
        self.disconnect(conn);
    }

    /// Authenticate a page connection by its first frame (a page token,
    /// `aud` = `router`, bound to `origin`), then serve it.
    pub async fn serve_page(
        self: Arc<Self>,
        mut transport: Transport,
        origin: Option<String>,
    ) -> Result<(), ErrorBody> {
        let verifier = Verifier::new(self.public_key(), ROUTER_AUDIENCE);
        let claims = crate::provider::authenticate(
            &mut transport,
            |token| {
                let claims = verifier.verify(token, crate::token::now(), origin.as_deref()).map_err(|e| e.to_string())?;
                if claims.page.is_none() {
                    return Err("not a page token".to_owned());
                }
                Ok(claims)
            },
            |claims: &Claims| json!({ "sub": claims.sub, "page": claims.page, "exp": claims.exp, "provider": ROUTER_AUDIENCE }),
        )
        .await?;
        self.serve_connection(transport, Admission::Page(claims)).await;
        Ok(())
    }

    /// Serve pages on a loopback WebSocket listener (the `router` endpoint
    /// of the page handshake).
    pub async fn serve_pages_ws(self: Arc<Self>, listener: TcpListener, policy: ListenerPolicy) {
        let policy = Arc::new(policy);
        let handle = |(stream, _): (tokio::net::TcpStream, std::net::SocketAddr)| {
            let (router, policy) = (self.clone(), policy.clone());
            tokio::spawn(async move {
                if let Ok((transport, origin)) = crate::ws::accept(stream, &policy).await {
                    let _ = router.serve_page(transport, origin).await;
                }
            });
        };
        let log = crate::net::log_accept_error("router page websocket");
        crate::net::accept_loop(|| crate::net::accept(&listener), handle, log).await;
    }
}
