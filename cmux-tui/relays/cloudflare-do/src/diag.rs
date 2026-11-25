//! A staging-only probe of far-viewer circuit placement (RFD 0163 pick 6, cmux#54175).
//!
//! `GET /diag/v1/far-viewer?daemon=wnam&n=5` runs a synthetic far-viewer join from the edge the
//! request reached, with no ticket, so an outside vantage (Globalping) can measure what
//! `CMUX_RELAY_VIEWER_CIRCUITS` changes without a daemon there. It is answered only when
//! `CMUX_RELAY_DIAG` is "1", which only the staging deploy sets; anywhere else the path is an
//! ordinary non-upgrade request.
//!
//! One call creates a fresh slot object (a unique id, hinted to `daemon`, as a daemon's control
//! upgrade places a slot) and two fresh circuit objects the slot creates, as `slot.rs`
//! `place_circuit` does: one with no hint (near the slot: the switch off) and one hinted to the
//! edge's own region (near the viewer: the switch on). It times, over `n` rounds each:
//!
//! - `inline`: edge -> slot. Off, a far viewer's frames ride inline in the slot object, so this is
//!   the viewer's leg of the data path.
//! - each circuit arm: the slot's create + first request (`place_ms`, the wake), edge -> circuit
//!   (the viewer's leg), and slot -> circuit (the daemon's leg: the daemon's edge sits by the slot).
//!
//! The objects store nothing, so they cost a request each and nothing after. Work is bounded:
//! `n` <= [`MAX_ROUNDS`], every step times out at [`STEP_TIMEOUT_MS`].

use std::future::Future;
use std::pin::pin;
use std::time::Duration;

use futures_util::future::{Either, select};
use serde_json::{Value, json};
use worker::{Date, Delay, Env, Fetch, Method, Request, Response, Result, Stub, Url};

use crate::placement::{hint_of, region};
use crate::wire::valid_circuit_id;

/// "1" turns the probe on. Set only by the staging deploy (.github/workflows/cloudflare-relay.yml);
/// wrangler.toml keeps it "0", so production never answers it.
pub(crate) const DIAG_VAR: &str = "CMUX_RELAY_DIAG";
/// The public route.
pub(crate) const PROBE_ROUTE: &str = "/diag/v1/far-viewer";
/// Internal: answer at once, with the object's colo when `trace=1`.
const PING_PATH: &str = "/internal/v1/diag/ping";
/// Internal, to a slot: create circuit `circuit` (hinted to `hint` when given), then time `n`
/// requests to it.
const PLACE_PATH: &str = "/internal/v1/diag/place";

const DEFAULT_DAEMON: &str = "wnam";
const DEFAULT_ROUNDS: u32 = 5;
pub(crate) const MAX_ROUNDS: u32 = 10;
pub(crate) const STEP_TIMEOUT_MS: u64 = 5_000;
const TRACE_URL: &str = "https://www.cloudflare.com/cdn-cgi/trace";

pub(crate) fn enabled(env: &Env) -> bool {
    env.var(DIAG_VAR).is_ok_and(|value| value.to_string() == "1")
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) struct ProbeParams {
    pub(crate) daemon: &'static str,
    pub(crate) rounds: u32,
}

/// The probe's query: `daemon` (a location hint, default `wnam`) and `n` (1..=[`MAX_ROUNDS`],
/// default 5). Other keys are ignored; a bad value is an error, not a clamp.
pub(crate) fn parse_params<K, V>(
    query: impl IntoIterator<Item = (K, V)>,
) -> std::result::Result<ProbeParams, &'static str>
where
    K: AsRef<str>,
    V: AsRef<str>,
{
    let mut params = ProbeParams { daemon: DEFAULT_DAEMON, rounds: DEFAULT_ROUNDS };
    for (key, value) in query {
        match key.as_ref() {
            "daemon" => params.daemon = region(value.as_ref()).ok_or("daemon is not a region")?,
            "n" => params.rounds = parse_rounds(value.as_ref())?,
            _ => {}
        }
    }
    Ok(params)
}

pub(crate) fn parse_rounds(value: &str) -> std::result::Result<u32, &'static str> {
    match value.parse::<u32>() {
        Ok(rounds) if (1..=MAX_ROUNDS).contains(&rounds) => Ok(rounds),
        _ => Err("n must be 1 to 10"),
    }
}

/// Nearest-rank percentile `p` (0..=100) of `samples`; `None` when empty.
pub(crate) fn percentile(samples: &[u64], p: u32) -> Option<u64> {
    if samples.is_empty() {
        return None;
    }
    let mut sorted = samples.to_vec();
    sorted.sort_unstable();
    let rank = (u64::from(p.min(100)) * sorted.len() as u64).div_ceil(100).max(1) as usize;
    sorted.get(rank - 1).copied()
}

/// The `colo=` line of a `/cdn-cgi/trace` body.
pub(crate) fn trace_colo(body: &str) -> Option<String> {
    body.lines()
        .find_map(|line| line.strip_prefix("colo="))
        .map(str::trim)
        .filter(|colo| {
            !colo.is_empty() && colo.len() <= 8 && colo.bytes().all(|b| b.is_ascii_alphanumeric())
        })
        .map(str::to_owned)
}

fn rtt(samples: &[u64]) -> Value {
    json!({ "samples": samples, "p50": percentile(samples, 50), "p90": percentile(samples, 90) })
}

fn add(left: Option<u64>, right: Option<u64>) -> Option<u64> {
    Some(left?.saturating_add(right?))
}

async fn bounded<T>(step: impl Future<Output = Result<T>>) -> Result<T> {
    let step = pin!(step);
    let timeout = pin!(Delay::from(Duration::from_millis(STEP_TIMEOUT_MS)));
    match select(step, timeout).await {
        Either::Left((result, _)) => result,
        Either::Right(_) => Err(worker::Error::RustError("diag step timed out".into())),
    }
}

/// Milliseconds `step` took (Workers' clock advances across I/O, which is all a step is).
async fn timed<T>(step: impl Future<Output = Result<T>>) -> Result<(u64, T)> {
    let start = Date::now().as_millis();
    let value = bounded(step).await?;
    Ok((Date::now().as_millis().saturating_sub(start), value))
}

fn internal(path: &str, query: &str) -> Result<Request> {
    let separator = if query.is_empty() { "" } else { "?" };
    Request::new(&format!("https://relay.internal{path}{separator}{query}"), Method::Post)
}

async fn colo_of(mut response: Response) -> Option<String> {
    if response.status_code() != 200 {
        return None;
    }
    let body: Value = response.json().await.ok()?;
    body.get("colo")?.as_str().map(str::to_owned)
}

/// `stub`'s first request (it creates the object): its time and the object's colo.
async fn wake(stub: &Stub) -> Result<(u64, Option<String>)> {
    let (ms, response) = timed(stub.fetch_with_request(internal(PING_PATH, "trace=1")?)).await?;
    Ok((ms, colo_of(response).await))
}

async fn pings(stub: &Stub, rounds: u32) -> Result<Vec<u64>> {
    let mut samples = Vec::with_capacity(rounds as usize);
    for _ in 0..rounds {
        let (ms, _) = timed(stub.fetch_with_request(internal(PING_PATH, "")?)).await?;
        samples.push(ms);
    }
    Ok(samples)
}

/// The colo of the object that runs this (an outgoing fetch leaves from it).
async fn own_colo() -> Option<String> {
    let url = Url::parse(TRACE_URL).ok()?;
    let mut response = bounded(Fetch::Url(url).send()).await.ok()?;
    trace_colo(&response.text().await.ok()?)
}

/// The internal diag requests, in either object class; `None` when `request` is not one or the
/// probe is off.
pub(crate) async fn handle_internal(request: &Request, env: &Env) -> Result<Option<Response>> {
    if request.method() != Method::Post || !enabled(env) {
        return Ok(None);
    }
    let path = request.path();
    let query: Vec<(String, String)> =
        request.url()?.query_pairs().map(|(k, v)| (k.into_owned(), v.into_owned())).collect();
    let param = |name: &str| query.iter().find(|(key, _)| key == name).map(|(_, v)| v.as_str());
    if path == PING_PATH {
        if param("trace") == Some("1") {
            return Response::from_json(&json!({ "colo": own_colo().await })).map(Some);
        }
        return Response::empty().map(|response| Some(response.with_status(204)));
    }
    if path != PLACE_PATH {
        return Ok(None);
    }
    let Some(circuit) = param("circuit").filter(|circuit| valid_circuit_id(circuit)) else {
        return Response::error("Invalid circuit", 400).map(Some);
    };
    let Ok(rounds) = parse_rounds(param("n").unwrap_or("1")) else {
        return Response::error("Invalid n", 400).map(Some);
    };
    let id = env.durable_object("RELAY_CIRCUITS")?.id_from_string(circuit)?;
    let stub = match param("hint").and_then(region) {
        Some(hint) => id.get_stub_with_location_hint(hint)?,
        None => id.get_stub()?,
    };
    let (place_ms, colo) = wake(&stub).await?;
    let samples = pings(&stub, rounds).await?;
    Response::from_json(&json!({ "place_ms": place_ms, "colo": colo, "samples": samples }))
        .map(Some)
}

/// `GET /diag/v1/far-viewer`.
pub(crate) async fn probe(request: &Request, env: &Env) -> Result<Response> {
    let query: Vec<(String, String)> =
        request.url()?.query_pairs().map(|(k, v)| (k.into_owned(), v.into_owned())).collect();
    let params = match parse_params(query) {
        Ok(params) => params,
        Err(message) => return Response::error(message, 400),
    };
    let edge_colo = request.cf().map(|cf| cf.colo());
    let viewer = hint_of(request);

    let slot_id = env.durable_object("RELAY_SLOTS")?.unique_id()?;
    let slot_key = slot_id.to_string();
    let slot = slot_id.get_stub_with_location_hint(params.daemon)?;
    let (slot_wake_ms, slot_colo) = wake(&slot).await?;
    let inline = pings(&slot, params.rounds).await?;

    // Run the two circuit arms in an order the slot's random id picks, so neither always goes first.
    let viewer_first = slot_key.bytes().last().is_some_and(|byte| byte % 2 == 1);
    let mut arms = [("near_slot", None), ("near_viewer", viewer)];
    if viewer_first {
        arms.swap(0, 1);
    }
    let circuits = env.durable_object("RELAY_CIRCUITS")?;
    let mut results = serde_json::Map::new();
    for (name, hint) in arms {
        let circuit = circuits.unique_id()?.to_string();
        let mut query = format!("circuit={circuit}&n={}", params.rounds);
        if let Some(hint) = hint {
            query.push_str(&format!("&hint={hint}"));
        }
        let (_, mut placed) = timed(slot.fetch_with_request(internal(PLACE_PATH, &query)?)).await?;
        let placed: Value = placed.json().await?;
        let slot_leg: Vec<u64> = placed["samples"]
            .as_array()
            .map(|samples| samples.iter().filter_map(Value::as_u64).collect())
            .unwrap_or_default();
        let stub = circuits.id_from_string(&circuit)?.get_stub()?;
        let edge_leg = pings(&stub, params.rounds).await?;
        results.insert(
            name.into(),
            json!({
                "circuit_hint": hint,
                "circuit_colo": placed["colo"],
                "place_ms": placed["place_ms"],
                "edge_to_circuit_ms": rtt(&edge_leg),
                "slot_to_circuit_ms": rtt(&slot_leg),
                "path_p50_ms": add(percentile(&edge_leg, 50), percentile(&slot_leg, 50)),
            }),
        );
    }
    results.insert(
        "inline".into(),
        json!({
            "slot_colo": slot_colo,
            "edge_to_slot_ms": rtt(&inline),
            "path_p50_ms": percentile(&inline, 50),
        }),
    );
    let body = json!({
        "probe": "far-viewer",
        "edge_colo": edge_colo,
        "viewer_region": viewer,
        "daemon_region": params.daemon,
        "rounds": params.rounds,
        "slot_wake_ms": slot_wake_ms,
        "viewer_circuits_switch": env
            .var(crate::slot::VIEWER_CIRCUITS_VAR)
            .is_ok_and(|value| value.to_string() == "1"),
        "arms": results,
    });
    let mut response = Response::from_json(&body)?;
    response.headers_mut().set("cache-control", "no-store")?;
    Ok(response)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn params_default_and_bound() {
        let none: [(&str, &str); 0] = [];
        assert_eq!(parse_params(none), Ok(ProbeParams { daemon: "wnam", rounds: 5 }));
        assert_eq!(
            parse_params([("daemon", "weur"), ("n", "10"), ("other", "x")]),
            Ok(ProbeParams { daemon: "weur", rounds: 10 })
        );
        assert!(parse_params([("n", "0")]).is_err());
        assert!(parse_params([("n", "11")]).is_err());
        assert!(parse_params([("n", "-1")]).is_err());
        assert!(parse_params([("n", "4294967296")]).is_err());
        assert!(parse_params([("n", "")]).is_err());
        assert!(parse_params([("daemon", "mars")]).is_err());
        assert!(parse_params([("daemon", "WNAM")]).is_err());
    }

    #[test]
    fn percentile_is_nearest_rank() {
        assert_eq!(percentile(&[], 50), None);
        assert_eq!(percentile(&[7], 50), Some(7));
        assert_eq!(percentile(&[5, 1, 3, 2, 4], 50), Some(3));
        assert_eq!(percentile(&[1, 2, 3, 4, 5, 6, 7, 8, 9, 10], 90), Some(9));
        assert_eq!(percentile(&[1, 2, 3, 4], 50), Some(2));
        assert_eq!(percentile(&[1, 2, 3, 4], 100), Some(4));
        assert_eq!(percentile(&[4, 3], 0), Some(3));
    }

    #[test]
    fn trace_colo_reads_only_a_plain_code() {
        assert_eq!(trace_colo("fl=1\nh=x\ncolo=FRA\nhttp=http/2\n"), Some("FRA".into()));
        assert_eq!(trace_colo("fl=1\n"), None);
        assert_eq!(trace_colo("colo=\n"), None);
        assert_eq!(trace_colo("colo=<script>\n"), None);
    }

    #[test]
    fn path_sum_needs_both_legs() {
        assert_eq!(add(Some(2), Some(3)), Some(5));
        assert_eq!(add(None, Some(3)), None);
    }
}
