//! An in-process device hub for the client's tests: the HTTP API and the
//! User DO socket, verifying every device signature against the hub's own
//! canonical string (built here, not with the client's helper).

#![allow(dead_code)]

use std::collections::{HashMap, HashSet};
use std::net::SocketAddr;
use std::sync::{Arc, Mutex};
use std::time::{SystemTime, UNIX_EPOCH};

use axum::Router;
use axum::body::Bytes;
use axum::extract::State;
use axum::extract::ws::{Message, WebSocket, WebSocketUpgrade};
use axum::http::{HeaderMap, Method, StatusCode, Uri};
use axum::response::{IntoResponse, Response};
use axum::routing::get;
use base64::Engine as _;
use cmux_device_hub_client::canonical::canonical_sha256;
use cmux_device_hub_client::signing::{low_s, verify};
use serde_json::{Value, json};
use sha2::{Digest, Sha256};
use tokio::sync::{mpsc, watch};

pub const STACK_TOKEN: &str = "stack-token";
pub const SESSION: &str = "sess-1";

/// One request the hub admitted.
#[derive(Debug, Clone)]
pub struct Logged {
    pub method: String,
    pub path: String,
    /// The string the hub verified the signature over.
    pub canonical: String,
    pub device_id: String,
}

#[derive(Default)]
struct Data {
    devices: HashMap<String, Value>,
    approvals: HashMap<String, Value>,
    sockets: HashMap<String, mpsc::UnboundedSender<Option<String>>>,
    replay: HashSet<(String, String, Vec<u8>)>,
    log: Vec<Logged>,
    pings: Vec<String>,
    refused: Vec<String>,
}

pub struct Hub {
    data: Mutex<Data>,
    connections: watch::Sender<usize>,
    created: Mutex<Option<mpsc::UnboundedReceiver<String>>>,
    created_tx: mpsc::UnboundedSender<String>,
}

#[derive(Clone)]
pub struct MockHub {
    pub hub: Arc<Hub>,
    pub addr: SocketAddr,
}

fn now_ms() -> i64 {
    SystemTime::now().duration_since(UNIX_EPOCH).unwrap().as_millis() as i64
}

fn error(status: StatusCode, code: &str) -> Response {
    (status, axum::Json(json!({"error": {"code": code, "message": code}}))).into_response()
}

fn ok(value: Value) -> Response {
    (StatusCode::OK, axum::Json(value)).into_response()
}

impl MockHub {
    pub async fn start() -> MockHub {
        let (connections, _) = watch::channel(0usize);
        let (created_tx, created) = mpsc::unbounded_channel();
        let hub = Arc::new(Hub {
            data: Mutex::new(Data::default()),
            connections,
            created: Mutex::new(Some(created)),
            created_tx,
        });
        let app = Router::new()
            .route("/v1/user/ws", get(socket))
            .fallback(api)
            .with_state(Arc::clone(&hub));
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let addr = listener.local_addr().unwrap();
        tokio::spawn(async move {
            axum::serve(listener, app).await.unwrap();
        });
        MockHub { hub, addr }
    }

    pub fn base_url(&self) -> url::Url {
        url::Url::parse(&format!("http://{}", self.addr)).unwrap()
    }

    /// Adds a device the way registration would, without a request.
    pub fn add_device(&self, id: &str, platform: &str, signing_key: &str) {
        self.hub.data.lock().unwrap().devices.insert(
            id.to_owned(),
            json!({"id": id, "name": format!("{platform} device"), "platform": platform, "signingKey": signing_key,
                   "agreementKey": signing_key, "approvalKey": null, "createdAt": now_ms(), "lastSeenAt": now_ms(),
                   "macScreenShared": false, "online": false, "assurance": "hardware"}),
        );
    }

    /// A Mac or iPhone with an approval key (the hub's `approvalKey`).
    pub fn add_approver(&self, id: &str, platform: &str, signing_key: &str, approval_key: &str) {
        self.add_device(id, platform, signing_key);
        if let Some(device) = self.hub.data.lock().unwrap().devices.get_mut(id) {
            device["approvalKey"] = json!(approval_key);
        }
    }

    pub fn device(&self, id: &str) -> Option<Value> {
        self.hub.data.lock().unwrap().devices.get(id).cloned()
    }

    pub fn log(&self) -> Vec<Logged> {
        self.hub.data.lock().unwrap().log.clone()
    }

    pub fn refused(&self) -> Vec<String> {
        self.hub.data.lock().unwrap().refused.clone()
    }

    pub fn pings(&self) -> Vec<String> {
        self.hub.data.lock().unwrap().pings.clone()
    }

    pub fn approval(&self, id: &str) -> Option<Value> {
        self.hub.data.lock().unwrap().approvals.get(id).cloned()
    }

    pub fn count(&self, method: &str, path: &str) -> usize {
        self.log().iter().filter(|entry| entry.method == method && entry.path == path).count()
    }

    /// Waits until the hub has accepted `count` User DO sockets in all.
    pub async fn wait_connections(&self, count: usize) {
        let mut rx = self.hub.connections.subscribe();
        let _ = rx.wait_for(|seen| *seen >= count).await;
    }

    /// The id of the next approval a device creates.
    pub async fn next_approval(&self) -> String {
        let mut rx = self.hub.created.lock().unwrap().take().expect("one waiter at a time");
        let id = rx.recv().await.expect("an approval");
        *self.hub.created.lock().unwrap() = Some(rx);
        id
    }

    /// Sends a text frame to `device`'s socket.
    pub fn push(&self, device: &str, message: Value) {
        let data = self.hub.data.lock().unwrap();
        let sender = data.sockets.get(device).expect("the device is connected");
        sender.send(Some(message.to_string())).expect("the socket is open");
    }

    /// Closes `device`'s socket from the server side.
    pub fn drop_socket(&self, device: &str) {
        if let Some(sender) = self.hub.data.lock().unwrap().sockets.remove(device) {
            let _ = sender.send(None);
        }
    }

    /// Records a decision without pushing it (the push was lost).
    pub fn decide_silently(&self, id: &str, decision: &str, decider: &str, sig: &str) {
        let mut data = self.hub.data.lock().unwrap();
        let approval = data.approvals.get_mut(id).expect("the approval");
        approval["state"] = json!("decided");
        approval["decision"] = json!(decision);
        approval["deciderId"] = json!(decider);
        approval["sig"] = json!(sig);
        approval["decidedAt"] = json!(now_ms());
    }
}

/// Checks the account session and the device signature as the hub does.
/// The refusal is the response itself (an axum handler returns it as is).
/// `key` overrides the registered key (registration is signed with the key it registers).
#[allow(clippy::result_large_err)]
fn admit(
    hub: &Hub,
    method: &Method,
    uri: &Uri,
    headers: &HeaderMap,
    body: &[u8],
    key: Option<&str>,
) -> Result<String, Response> {
    let header =
        |name: &str| headers.get(name).and_then(|value| value.to_str().ok()).map(str::to_owned);
    let refuse = |why: &str, response: Response| {
        hub.data.lock().unwrap().refused.push(format!("{method} {}: {why}", uri.path()));
        Err(response)
    };
    if header("authorization").as_deref() != Some(&format!("Bearer {SESSION}")) {
        return refuse("bearer", error(StatusCode::UNAUTHORIZED, "unauthorized"));
    }
    let (Some(id), Some(ts), Some(sig)) =
        (header("x-device-id"), header("x-device-ts"), header("x-device-sig"))
    else {
        return refuse("headers", error(StatusCode::UNAUTHORIZED, "bad_signature"));
    };
    let Ok(ts_value) = ts.parse::<i64>() else {
        return refuse("ts", error(StatusCode::UNAUTHORIZED, "stale_timestamp"));
    };
    if (ts_value - now_ms() / 1000).abs() > 60 {
        return refuse("stale", error(StatusCode::UNAUTHORIZED, "stale_timestamp"));
    }
    let key = match key {
        Some(key) => key.to_owned(),
        None => match hub.data.lock().unwrap().devices.get(&id) {
            Some(device) => device["signingKey"].as_str().unwrap().to_owned(),
            None => {
                return refuse("unknown device", error(StatusCode::UNAUTHORIZED, "bad_signature"));
            }
        },
    };
    let body_hash = if body.is_empty() { String::new() } else { hex::encode(Sha256::digest(body)) };
    let target = uri
        .path_and_query()
        .map(|value| value.as_str().to_owned())
        .unwrap_or_else(|| uri.path().to_owned());
    let canonical = format!("{}\n{}\n{}\n{}", method.as_str(), target, ts, body_hash);
    let engine = base64::engine::general_purpose::STANDARD;
    let (Ok(key_bytes), Ok(sig_bytes)) = (engine.decode(&key), engine.decode(&sig)) else {
        return refuse("base64", error(StatusCode::UNAUTHORIZED, "bad_signature"));
    };
    if !verify(&key_bytes, canonical.as_bytes(), &sig_bytes) {
        return refuse("signature", error(StatusCode::UNAUTHORIZED, "bad_signature"));
    }
    let replay_key = (id.clone(), ts, low_s(&sig_bytes).unwrap().to_vec());
    let mut data = hub.data.lock().unwrap();
    if !data.replay.insert(replay_key) {
        drop(data);
        return refuse("replay", error(StatusCode::UNAUTHORIZED, "replay"));
    }
    data.log.push(Logged {
        method: method.as_str().to_owned(),
        path: uri.path().to_owned(),
        canonical,
        device_id: id.clone(),
    });
    Ok(id)
}

async fn api(
    State(hub): State<Arc<Hub>>,
    method: Method,
    uri: Uri,
    headers: HeaderMap,
    body: Bytes,
) -> Response {
    let segments: Vec<String> =
        uri.path().trim_start_matches('/').split('/').map(str::to_owned).collect();
    let segments: Vec<&str> = segments.iter().map(String::as_str).collect();
    let body_json: Value = serde_json::from_slice(&body).unwrap_or(Value::Null);

    if method == Method::POST && segments == ["v1", "auth", "stack"] {
        if body_json["token"] != STACK_TOKEN {
            return error(StatusCode::UNAUTHORIZED, "unauthorized");
        }
        return ok(
            json!({"session": SESSION, "userId": "proj:user", "expiresAt": now_ms() + 3_600_000}),
        );
    }

    let registering = method == Method::POST && segments == ["v1", "devices"];
    let key = if registering { body_json["signingKey"].as_str() } else { None };
    if registering && key.is_none() {
        return error(StatusCode::BAD_REQUEST, "bad_request");
    }
    let device = match admit(&hub, &method, &uri, &headers, &body, key) {
        Ok(device) => device,
        Err(response) => return response,
    };
    let mut data = hub.data.lock().unwrap();
    match (method.as_str(), segments.as_slice()) {
        ("POST", ["v1", "devices"]) => {
            if body_json["id"] != json!(device) {
                return error(StatusCode::BAD_REQUEST, "bad_request");
            }
            let mut record = body_json.clone();
            record["createdAt"] = json!(now_ms());
            record["lastSeenAt"] = json!(now_ms());
            record["macScreenShared"] = json!(false);
            record["online"] = json!(false);
            data.devices.insert(device, record.clone());
            ok(json!({"device": record}))
        }
        ("GET", ["v1", "devices"]) => {
            let mut devices: Vec<Value> = data.devices.values().cloned().collect();
            devices.sort_by(|a, b| a["id"].as_str().cmp(&b["id"].as_str()));
            ok(json!({"devices": devices}))
        }
        ("GET", ["v1", "me"]) => ok(
            json!({"userId": "proj:user", "plan": "free", "device": data.devices.get(&device).cloned()}),
        ),
        ("POST", ["v1", "approvals"]) => {
            let mut request = body_json["request"].clone();
            let Some(digest) = request.as_object_mut().and_then(|map| map.remove("digest")) else {
                return error(StatusCode::BAD_REQUEST, "bad_request");
            };
            if canonical_sha256(&request).ok().as_deref() != digest.as_str() {
                return error(StatusCode::BAD_REQUEST, "digest_mismatch");
            }
            let nonce = request["nonce"].clone();
            if let Some(existing) = data.approvals.values().find(|approval| {
                approval["deviceId"] == json!(device) && approval["request"]["nonce"] == nonce
            }) {
                if existing["request"]["digest"] != digest {
                    return error(StatusCode::CONFLICT, "approval_exists");
                }
                return ok(json!({"approval": existing}));
            }
            let id = uuid::Uuid::new_v4().to_string();
            let approval = json!({
                "id": id, "deviceId": device, "deviceName": "box", "request": body_json["request"],
                "allowAlways": body_json["allowAlways"].as_bool().unwrap_or(false), "state": "pending",
                "decision": null, "deciderId": null, "sig": null, "createdAt": now_ms(),
                "answerableUntil": request["answerable_until_ms"], "decidedAt": null,
            });
            data.approvals.insert(id.clone(), approval.clone());
            let _ = hub.created_tx.send(id);
            ok(json!({"approval": approval}))
        }
        ("GET", ["v1", "approvals"]) => {
            let pending: Vec<Value> = data
                .approvals
                .values()
                .filter(|approval| {
                    approval["state"] == "pending" && approval["deviceId"] != json!(device)
                })
                .cloned()
                .collect();
            ok(json!({"approvals": pending}))
        }
        ("GET", ["v1", "approvals", id]) => match data.approvals.get(*id) {
            Some(approval) => ok(json!({"approval": approval})),
            None => error(StatusCode::NOT_FOUND, "not_found"),
        },
        ("DELETE", ["v1", "approvals", id]) => {
            let Some(approval) = data.approvals.get_mut(*id) else {
                return error(StatusCode::NOT_FOUND, "not_found");
            };
            if approval["deviceId"] != json!(device) {
                return error(StatusCode::FORBIDDEN, "not_asker");
            }
            if approval["state"] == "pending" {
                approval["state"] = json!("cancelled");
            }
            ok(json!({"approval": approval}))
        }
        ("POST", ["v1", "approvals", id, "decision"]) => {
            let platform =
                data.devices.get(&device).map(|d| d["platform"].clone()).unwrap_or(Value::Null);
            let Some(approval) = data.approvals.get_mut(*id) else {
                return error(StatusCode::NOT_FOUND, "not_found");
            };
            if approval["deviceId"] == json!(device) {
                return error(StatusCode::FORBIDDEN, "self_approval");
            }
            if platform != "macos" && platform != "ios" {
                return error(StatusCode::FORBIDDEN, "not_approver");
            }
            if approval["state"] != "pending" {
                return error(StatusCode::CONFLICT, "approval_not_pending");
            }
            approval["state"] = json!("decided");
            approval["decision"] = body_json["decision"].clone();
            approval["deciderId"] = json!(device);
            approval["sig"] = body_json["sig"].clone();
            ok(json!({"approval": approval}))
        }
        _ => error(StatusCode::NOT_FOUND, "not_found"),
    }
}

async fn socket(
    State(hub): State<Arc<Hub>>,
    method: Method,
    uri: Uri,
    headers: HeaderMap,
    upgrade: WebSocketUpgrade,
) -> Response {
    let device = match admit(&hub, &method, &uri, &headers, &[], None) {
        Ok(device) => device,
        Err(response) => return response,
    };
    upgrade.on_upgrade(move |socket| serve(hub, device, socket))
}

async fn serve(hub: Arc<Hub>, device: String, mut socket: WebSocket) {
    let (tx, mut rx) = mpsc::unbounded_channel::<Option<String>>();
    hub.data.lock().unwrap().sockets.insert(device.clone(), tx);
    hub.connections.send_modify(|count| *count += 1);
    loop {
        tokio::select! {
            outgoing = rx.recv() => match outgoing {
                Some(Some(text)) => {
                    if socket.send(Message::Text(text.into())).await.is_err() {
                        break;
                    }
                }
                _ => {
                    let _ = socket.send(Message::Close(None)).await;
                    break;
                }
            },
            incoming = socket.recv() => match incoming {
                Some(Ok(Message::Text(text))) => {
                    hub.data.lock().unwrap().pings.push(text.as_str().to_owned());
                    if text.as_str() == r#"{"type":"ping"}"# {
                        let _ = socket.send(Message::Text(r#"{"type":"pong"}"#.into())).await;
                    }
                }
                Some(Ok(_)) => {}
                _ => break,
            },
        }
    }
}
