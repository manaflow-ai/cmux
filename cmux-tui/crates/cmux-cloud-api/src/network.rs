//! The team's Cloud network on cmux-platform: `GET /v1/host/network/target`, sent as the Mac's
//! install (`auth: worker`, the install token as the credential; the route refuses a Stack
//! session), never classic `/api/vm/network`. A team has one mesh, answered in the classic list's
//! shape; a team with no mesh yet (404) has none.

use std::time::Duration;

use reqwest::Method;
use serde_json::{Value, json};

use super::http::{Auth, Http, path_text, worker_error};
use super::Failure;

const TIMEOUT: Duration = Duration::from_secs(20);

pub(crate) async fn networks(http: &Http, auth: Auth) -> Result<Value, Failure> {
    if auth != Auth::Worker {
        return Err(Failure::Transport(
            "vm.networks is a cmux-platform route: send auth worker with the install token".into(),
        ));
    }
    let segments = ["v1", "host", "network", "target"];
    let path = path_text(&segments);
    let reply = http.send(Method::GET, http.url(&segments, &[]), None, None, TIMEOUT, &path).await?;
    if reply.status == 404 {
        return Ok(json!([]));
    }
    if !reply.ok() {
        return Err(worker_error(reply.status, reply.json().as_ref()));
    }
    team_networks(reply.json().as_ref())
        .ok_or_else(|| Failure::Decoding(format!("{path}: no mesh and ipv4_cidr")))
}

/// The target's mesh as the one network of the list.
fn team_networks(target: Option<&Value>) -> Option<Value> {
    let target = target?;
    let mesh = target.get("mesh")?.as_str()?;
    let cidr = target.get("ipv4_cidr")?.as_str()?;
    Some(json!([{ "id": mesh, "cidr": cidr, "cidrV6": null, "scope": "team" }]))
}
