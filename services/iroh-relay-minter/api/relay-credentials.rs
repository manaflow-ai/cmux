use std::time::SystemTime;

use cmux_iroh_relay_minter::{
    configuration_error_response,
    mirror::{MirrorConfig, handle_mirror_request},
};
use vercel_runtime::{Error, Request, Response, ResponseBody, run, service_fn};

#[tokio::main]
async fn main() -> Result<(), Error> {
    run(service_fn(handler)).await
}

async fn handler(request: Request) -> Result<Response<ResponseBody>, Error> {
    // Off by default: with CMUX_RELAY_MIRROR_ENABLED unset this answers 404.
    let config = match MirrorConfig::from_env() {
        Ok(config) => config,
        Err(_) => return Ok(configuration_error_response()),
    };
    Ok(handle_mirror_request(request, config.as_ref(), SystemTime::now()).await)
}
