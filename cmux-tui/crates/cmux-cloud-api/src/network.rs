//! The team's Cloud network on cmux-platform: `GET /v1/host/network/target`, sent as the Mac's
//! install (`auth: worker`, the install token as the credential; the route refuses a Stack
//! session), never classic `/api/vm/network`. A team has one network, answered in the classic
//! list's shape with the team id as its `id` (what `vm.tunnel_attach` takes as the network) and
//! the provider mesh as `meshId`; a team with no mesh yet (404) has none.

use std::time::Duration;

use reqwest::Method;
use serde_json::{Value, json};

use super::Failure;
use super::http::{Auth, Http, path_text, worker_error};

const TIMEOUT: Duration = Duration::from_secs(20);

pub(crate) async fn networks(http: &Http, auth: Auth) -> Result<Value, Failure> {
    if auth != Auth::Worker {
        return Err(Failure::Transport(
            "vm.networks is a cmux-platform route: send auth worker with the install token".into(),
        ));
    }
    let segments = ["v1", "host", "network", "target"];
    let path = path_text(&segments);
    let reply =
        http.send(Method::GET, http.url(&segments, &[]), None, None, TIMEOUT, &path).await?;
    if reply.status == 404 {
        return Ok(json!([]));
    }
    if !reply.ok() {
        return Err(worker_error(reply.status, reply.json().as_ref()));
    }
    team_networks(reply.json().as_ref())
        .ok_or_else(|| Failure::Decoding(format!("{path}: no team, mesh and ipv4_cidr")))
}

/// The target's team network as the one network of the list.
fn team_networks(target: Option<&Value>) -> Option<Value> {
    let target = target?;
    let read = |name: &str| target.get(name).and_then(Value::as_str);
    let (team, mesh, cidr) = (read("team")?, read("mesh")?, read("ipv4_cidr")?);
    Some(json!([{
        "id": team,
        "meshId": mesh,
        "cidr": cidr,
        "cidrV6": null,
        "scope": "team",
    }]))
}
