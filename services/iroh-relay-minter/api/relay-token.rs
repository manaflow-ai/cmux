use std::time::SystemTime;

use cmux_iroh_relay_minter::{MinterConfig, configuration_error_response, handle_request};
use vercel_runtime::{Error, Request, Response, ResponseBody, run, service_fn};

#[tokio::main]
async fn main() -> Result<(), Error> {
    run(service_fn(handler)).await
}

async fn handler(request: Request) -> Result<Response<ResponseBody>, Error> {
    let config = match MinterConfig::from_env() {
        Ok(config) => config,
        Err(_) => return Ok(configuration_error_response()),
    };

    Ok(handle_request(request, &config, SystemTime::now()).await)
}
