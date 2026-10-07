//! Local model router. Initial contract scaffold; security is implemented next.
use http::{Request, StatusCode};
use std::net::SocketAddr;
use zeroize::Zeroize;

pub const BODY_LIMIT: usize = 64 * 1024 * 1024;

#[derive(Debug)]
pub struct Secret<T: Zeroize + std::fmt::Debug>(T);
impl<T: Zeroize + std::fmt::Debug> Secret<T> {
    pub fn new(value: T) -> Self { Self(value) }
    pub fn expose(&self) -> &T { &self.0 }
}
impl<T: Zeroize + std::fmt::Debug> Drop for Secret<T> {
    fn drop(&mut self) { self.0.zeroize(); }
}
#[derive(Debug, Clone, Copy)]
pub struct LoopbackAddr(SocketAddr);
impl TryFrom<SocketAddr> for LoopbackAddr {
    type Error = std::io::Error;
    fn try_from(value: SocketAddr) -> Result<Self, Self::Error> { Ok(Self(value)) }
}
impl LoopbackAddr {
    pub fn address(self) -> SocketAddr { self.0 }
}
#[derive(Debug, Clone)]
pub struct KeyScope {
    pub harness: String,
    pub session: String,
    pub surfaces: Vec<String>,
    pub expires_at: u64,
}
pub struct KeyRing;
impl KeyRing {
    pub fn new(_install_secret: Secret<Vec<u8>>) -> anyhow::Result<Self> { Ok(Self) }
    pub fn mint(&mut self, _scope: KeyScope) -> anyhow::Result<Secret<String>> {
        Ok(Secret::new(format!("crl_{}_{}_{}", uuid::Uuid::new_v4().simple(), uuid::Uuid::new_v4().simple(), "ab".repeat(32))))
    }
}
pub async fn handle_request<B: http_body_util::BodyExt<Data = bytes::Bytes> + Unpin>(
    _request: Request<B>, _port: u16, _keys: &KeyRing,
) -> StatusCode { StatusCode::NOT_IMPLEMENTED }
pub fn install_panic_hook() {}
