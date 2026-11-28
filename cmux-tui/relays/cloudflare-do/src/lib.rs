mod abuse;
mod attachment;
mod auth;
mod circuit;
mod routing;
mod slot;
mod wire;

pub use circuit::RelayCircuit;
pub use slot::RelaySlot;

use worker::{Context, Env, Request, Response, Result, event};

#[event(fetch, respond_with_errors)]
pub async fn main(request: Request, env: Env, _context: Context) -> Result<Response> {
    routing::route(request, env).await
}
