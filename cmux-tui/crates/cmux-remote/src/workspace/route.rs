use std::collections::HashMap;
use std::net::{IpAddr, SocketAddr};
use std::sync::Arc;
use std::sync::atomic::{AtomicU64, Ordering};
use std::time::Duration;

use cmux_remote_protocol::{RouteId, RoutePolicy, RpcError, WorkspaceId, WorkspaceResponse};
use tokio::net::TcpStream;
use tokio::sync::RwLock;

use super::ClientScope;

const DIAL_TIMEOUT: Duration = Duration::from_secs(10);
const RESOLVE_TIMEOUT: Duration = Duration::from_secs(5);
const MAX_ROUTES: usize = 1_024;

#[derive(Debug, Clone)]
struct Route {
    owner: ClientScope,
    workspace: WorkspaceId,
    host: String,
    port: u16,
    policy: RoutePolicy,
}

#[derive(Debug)]
pub(crate) struct RouteManager {
    next_id: AtomicU64,
    routes: RwLock<HashMap<RouteId, Arc<Route>>>,
}

impl Default for RouteManager {
    fn default() -> Self {
        Self { next_id: AtomicU64::new(1), routes: RwLock::new(HashMap::new()) }
    }
}

impl RouteManager {
    pub(crate) async fn create(
        &self,
        owner: ClientScope,
        workspace: WorkspaceId,
        host: String,
        port: u16,
        policy: RoutePolicy,
    ) -> Result<WorkspaceResponse, RpcError> {
        let host = validate_host(&host)?;
        if port == 0 {
            return Err(RpcError::new("invalid-route", "route port cannot be zero"));
        }
        resolve_allowed(&host, port, policy).await?;
        let mut routes = self.routes.write().await;
        if routes.len() >= MAX_ROUTES {
            return Err(RpcError::new(
                "resource-exhausted",
                format!("route limit of {MAX_ROUTES} reached"),
            ));
        }
        let id = RouteId(self.next_id.fetch_add(1, Ordering::Relaxed));
        routes.insert(id, Arc::new(Route { owner, workspace, host: host.clone(), port, policy }));
        Ok(WorkspaceResponse::RouteCreated { route: id, host, port })
    }

    pub(crate) async fn close(&self, id: RouteId) -> Result<WorkspaceResponse, RpcError> {
        if self.routes.write().await.remove(&id).is_none() {
            return Err(RpcError::new("unknown-route", format!("unknown route {}", id.0)));
        }
        Ok(WorkspaceResponse::Closed)
    }

    pub(crate) async fn close_workspace(&self, owner: &ClientScope, workspace: &WorkspaceId) {
        self.routes
            .write()
            .await
            .retain(|_, route| &route.owner != owner || &route.workspace != workspace);
    }

    pub(crate) async fn close_client(&self, owner: &ClientScope) {
        self.routes.write().await.retain(|_, route| &route.owner != owner);
    }

    pub(crate) async fn shutdown(&self) {
        self.routes.write().await.clear();
    }

    pub(crate) async fn dial(&self, id: RouteId) -> Result<TcpStream, RpcError> {
        let route = self
            .routes
            .read()
            .await
            .get(&id)
            .cloned()
            .ok_or_else(|| RpcError::new("unknown-route", format!("unknown route {}", id.0)))?;
        let addresses = resolve_allowed(&route.host, route.port, route.policy).await?;
        let stream = tokio::time::timeout(DIAL_TIMEOUT, TcpStream::connect(addresses.as_slice()))
            .await
            .map_err(|_| RpcError::new("route-unavailable", "connection timed out"))?
            .map_err(|error| RpcError::new("route-unavailable", error.to_string()))?;
        stream
            .set_nodelay(true)
            .map_err(|error| RpcError::new("route-error", error.to_string()))?;
        Ok(stream)
    }
}

fn validate_host(host: &str) -> Result<String, RpcError> {
    let host = host.trim();
    let host = host.strip_prefix('[').and_then(|host| host.strip_suffix(']')).unwrap_or(host);
    if host.is_empty()
        || host.len() > 253
        || host.contains('\0')
        || host.chars().any(char::is_whitespace)
        || host.contains('/')
        || host.contains("//")
    {
        return Err(RpcError::new("invalid-route", "route host is invalid"));
    }
    Ok(host.to_string())
}

async fn resolve_allowed(
    host: &str,
    port: u16,
    policy: RoutePolicy,
) -> Result<Vec<SocketAddr>, RpcError> {
    let resolved = tokio::time::timeout(RESOLVE_TIMEOUT, tokio::net::lookup_host((host, port)))
        .await
        .map_err(|_| RpcError::new("route-resolution-failed", "DNS resolution timed out"))?
        .map_err(|error| RpcError::new("route-resolution-failed", error.to_string()))?;
    let mut addresses =
        resolved.filter(|address| address_allowed(address.ip(), policy)).collect::<Vec<_>>();
    addresses.sort();
    addresses.dedup();
    if addresses.is_empty() {
        return Err(RpcError::new(
            "route-policy-denied",
            format!("{host}:{port} has no address allowed by {policy:?}"),
        ));
    }
    Ok(addresses)
}

fn address_allowed(address: IpAddr, policy: RoutePolicy) -> bool {
    let address = match address {
        IpAddr::V6(address) => {
            address.to_ipv4_mapped().map(IpAddr::V4).unwrap_or(IpAddr::V6(address))
        }
        address => address,
    };
    if address.is_unspecified() || address.is_multicast() {
        return false;
    }
    match policy {
        RoutePolicy::LoopbackOnly => address.is_loopback(),
        RoutePolicy::PrivateNetwork => match address {
            IpAddr::V4(address) => {
                address.is_loopback() || address.is_private() || address.is_link_local()
            }
            IpAddr::V6(address) => {
                address.is_loopback()
                    || address.is_unique_local()
                    || address.is_unicast_link_local()
            }
        },
        RoutePolicy::Any => match address {
            IpAddr::V4(address) => !address.is_broadcast(),
            IpAddr::V6(_) => true,
        },
    }
}

#[cfg(test)]
mod tests {
    use tokio::io::{AsyncReadExt, AsyncWriteExt};
    use tokio::net::TcpListener;

    use super::*;

    #[tokio::test]
    async fn loopback_route_dials_and_forwards_bytes() {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let port = listener.local_addr().unwrap().port();
        let server = tokio::spawn(async move {
            let (mut stream, _) = listener.accept().await.unwrap();
            let mut byte = [0u8; 1];
            stream.read_exact(&mut byte).await.unwrap();
            stream.write_all(&byte).await.unwrap();
        });
        let routes = RouteManager::default();
        let response = routes
            .create(
                ClientScope::local(),
                WorkspaceId("workspace".into()),
                "127.0.0.1".into(),
                port,
                RoutePolicy::LoopbackOnly,
            )
            .await
            .unwrap();
        let WorkspaceResponse::RouteCreated { route, .. } = response else { panic!() };
        let mut stream = routes.dial(route).await.unwrap();
        stream.write_all(b"x").await.unwrap();
        let mut byte = [0u8; 1];
        stream.read_exact(&mut byte).await.unwrap();
        assert_eq!(&byte, b"x");
        server.await.unwrap();
    }

    #[tokio::test]
    async fn public_address_is_denied_by_private_policy() {
        let error =
            resolve_allowed("192.0.2.1", 80, RoutePolicy::PrivateNetwork).await.unwrap_err();
        assert_eq!(error.code, "route-policy-denied");
    }
}
