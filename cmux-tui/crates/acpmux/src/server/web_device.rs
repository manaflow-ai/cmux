//! A browser is its own enrolled device on the mesh hub (RFD 0005). Leo, 2026-11-17: "if we
//! literally had it... on the web... wouldn't that be interesting!?"
//!
//! A web connection (`Origin::Web`, the listener token proven at the upgrade) never borrows this
//! daemon's own hub identity: `mesh_read.rs` `may_read` refuses it, unchanged. To read and prompt
//! a chat the hub lists for the person's other machines, the browser enrolls as a device of its
//! own, through the same join a new machine makes, and presents that credential on its
//! connection:
//!
//! - `_acpmux/device_enroll {accessToken, publicKey}` mints a single-use join token with the
//!   person's access token (`cli/cloud_join/enroll.rs` `mint_join_token`) and redeems it as a
//!   `web` machine with the browser's public key, as `cli/cloud_join/recovery.rs` redeems a
//!   machine's. It writes nothing to disk, and answers `{credential, machineId, userId}` to that
//!   connection only. The hub records the device under the person who minted it.
//! - `_acpmux/device_hello {credential}` sets the connection's device client
//!   (`Conn::device_mesh`), once per connection. The connection is still served as Web: every
//!   `remote_guard.rs` rule (known folders, asking modes, no command-bearing params) holds.
//!
//! Then the hub stamps the device's reads and prompts with the device's identity and person, the
//! target daemon checks that person against its own `controlFrom` `sameUser`
//! (`mesh_relay.rs` `MeshControlHook::control`), and the hub's 401 (`machine.revoked`) cuts the
//! device off: the connection drops it and answers `device.revoked`, and no later call reaches the
//! hub (`mesh_read.rs` `read_hub`).
//!
//! Before it enrolls, a browser that holds no access token gets its own with the person's
//! ordinary email-code sign-in (`cmux-stack-auth` `BrowserSignIn`, its `BrowserSignIn.md`):
//!
//! - `_acpmux/browser_sign_in_start {email, publicKey}` -> `{expiresIn: 300}` emails a code for
//!   this daemon's owner, bound to the page origin that opened the socket (`Conn::page_origin`)
//!   and the browser's device key. One pending sign-in per connection; a new start replaces it.
//! - `_acpmux/browser_sign_in_complete {code}` -> `{accessToken, publicKey}` takes it (single
//!   use, even when it fails) and answers the browser's own access token if Stack's `/users/me`
//!   names the owner. The owner, the Stack project and the email-link callback come from this
//!   machine's join record and its deployment (`sign_in_config`), never from the request; a
//!   machine with no joined owner refuses with `signin.unconfigured`.
//!
//! Neither credential is logged, persisted or echoed: each lives in a `Zeroizing` in this
//! process's memory, and the device's only in its connection's client.

use std::sync::Arc;

use base64::Engine;
use serde_json::{Value, json};
use zeroize::Zeroizing;

use super::{Conn, ConnAuth, Origin};
use crate::hub::Hub;
use crate::mesh_http::HttpHub;
use crate::rpc::{RpcError, method};

/// A connection's device on the hub.
pub(crate) enum Slot {
    /// None presented yet.
    Empty,
    /// The browser's own device client (`_acpmux/device_hello`).
    Device(Arc<HttpHub>),
    /// The hub refused its credential (401): dropped, and no other may be presented on this
    /// connection. The reason the browser is told (`HttpHub::refused`).
    Revoked(&'static str),
}

/// The longest credential or access token taken.
const MAX_TOKEN_BYTES: usize = 16 << 10;

/// The device methods; None for every other method.
pub(super) async fn dispatch(
    hub: &Arc<Hub>,
    conn: &Arc<Conn>,
    m: &str,
    params: &Value,
) -> Option<Result<Value, RpcError>> {
    match m {
        method::MUX_DEVICE_HELLO => Some(hello(hub, conn, params).await),
        method::MUX_DEVICE_ENROLL => Some(enroll(hub, conn, params).await),
        method::MUX_BROWSER_SIGN_IN_START => Some(sign_in_start(conn, params).await),
        method::MUX_BROWSER_SIGN_IN_COMPLETE => Some(sign_in_complete(conn, params).await),
        _ => None,
    }
}

/// Only a browser on the web listener, proven by the listener token alone: the unix socket and
/// the app's pane read with this daemon's identity and need no device; a paired machine, a
/// teammate through the carrier and a peer daemon have their own proofs.
fn web_only(conn: &Conn, m: &str) -> Result<(), RpcError> {
    if conn.origin != Origin::Web
        || !matches!(conn.auth, ConnAuth::ListenerToken | ConnAuth::BrowserApp)
    {
        return Err(RpcError::method_not_found(&format!("{m} (a web connection only)")));
    }
    Ok(())
}

/// The hub this daemon is on (config.json `meshRelay`): a device is enrolled at, and reads
/// through, the same hub whose address book this daemon lists.
async fn hub_origin(hub: &Hub) -> Result<String, RpcError> {
    let relay = hub.config.read().await.mesh_relay.clone();
    relay.and_then(|relay| relay.origin().ok()).ok_or_else(|| {
        RpcError::new(-32000, "this machine is on no mesh hub")
            .with_data(json!({"reason": "device.no_hub"}))
    })
}

/// A bearer token from `params[key]`: printable ASCII, at most 16 KiB. The refusal never
/// repeats it.
fn token_param(params: &Value, key: &str) -> Result<Zeroizing<String>, RpcError> {
    params
        .get(key)
        .and_then(Value::as_str)
        .map(str::trim)
        .filter(|t| !t.is_empty() && t.len() <= MAX_TOKEN_BYTES)
        .filter(|t| t.bytes().all(|b| b.is_ascii_graphic()))
        .map(|t| Zeroizing::new(t.to_owned()))
        .ok_or_else(|| RpcError::invalid_params(format!("{key} is required")))
}

/// The refusal a connection whose device the hub refused gets for every hub call: `reason` is
/// `device.revoked` (`machine.revoked`) or `device.unauthorized` (`mesh.unauthorized`).
pub(super) fn revoked(reason: &'static str) -> RpcError {
    let message = if reason == "device.unauthorized" {
        "the mesh hub does not know this device's credential: enroll it again"
    } else {
        "this device was revoked on the mesh hub: enroll it again"
    };
    RpcError::new(-32003, message).with_data(json!({"reason": reason}))
}

/// `_acpmux/device_hello {credential}` -> `{auth: "webDevice"}`.
async fn hello(hub: &Hub, conn: &Conn, params: &Value) -> Result<Value, RpcError> {
    web_only(conn, method::MUX_DEVICE_HELLO)?;
    let credential = token_param(params, "credential")?;
    let origin = hub_origin(hub).await?;
    let client = HttpHub::with_credential(origin, credential)
        .map_err(|_| RpcError::internal("the hub client could not be built"))?;
    if conn.auth == ConnAuth::BrowserApp {
        verify_owner(hub, &client).await?;
    }
    {
        let mut slot = conn.device_mesh.lock().unwrap_or_else(|e| e.into_inner());
        match *slot {
            Slot::Empty => *slot = Slot::Device(Arc::new(client)),
            Slot::Device(_) => {
                return Err(RpcError::invalid_params("this connection already presented a device")
                    .with_data(json!({"reason": "device.already_presented"})));
            }
            Slot::Revoked(reason) => return Err(revoked(reason)),
        }
    }
    Ok(json!({"auth": conn.proof().as_str()}))
}

/// `_acpmux/device_enroll {accessToken, publicKey}` -> `{credential, machineId, userId}`.
async fn enroll(hub: &Hub, conn: &Conn, params: &Value) -> Result<Value, RpcError> {
    web_only(conn, method::MUX_DEVICE_ENROLL)?;
    let access = token_param(params, "accessToken")?;
    // A WireGuard public key in standard base64, as every machine's join sends.
    let key = params
        .get("publicKey")
        .and_then(Value::as_str)
        .filter(|key| {
            base64::engine::general_purpose::STANDARD.decode(key).is_ok_and(|raw| raw.len() == 32)
        })
        .ok_or_else(|| {
            RpcError::invalid_params("publicKey must be a 32-byte key in standard base64")
        })?;
    let origin = hub_origin(hub).await?;
    let token = crate::cli::cloud_join::mint_join_token(&origin, &access, "web")
        .await
        .map_err(|_| refused("the hub refused to mint a join token for this device"))?;
    // cmux-platform's web redeem: `{token, platform: "web", hostname, wgPublicKey}`. The hub
    // mints the `cmm_` credential and names the device by `wgPublicKey` on the mesh (its
    // `from.daemonId`). The generated body always carries `capabilities` (`build.rs`): none here.
    let body: cmux_cloud_client::types::JoinRedeem = serde_json::from_value(json!({
        "token": token.as_str(),
        "platform": "web",
        "hostname": "web",
        "wgPublicKey": key,
        "capabilities": [],
    }))
    .map_err(|_| RpcError::internal("the join request is not the hub's shape"))?;
    let client = crate::cli::cloud_join::hub_client(&origin, None)
        .map_err(|_| RpcError::internal("the hub client could not be built"))?;
    let redeemed = match client.machine_redeem_redeem(&body).await {
        Ok(answer) => serde_json::to_value(answer.into_inner()).unwrap_or_default(),
        Err(_) => return Err(refused("the hub refused this device's join")),
    };
    let text = |key: &str| redeemed.get(key).and_then(Value::as_str).map(str::to_owned);
    let credential = Zeroizing::new(
        text("credential")
            .filter(|c| c.starts_with("cmm_"))
            .ok_or_else(|| refused("the hub minted no device credential"))?,
    );
    let machine = text("machineId").ok_or_else(|| refused("the hub named no machine"))?;
    Ok(json!({
        "credential": credential.as_str(),
        "machineId": machine,
        "userId": text("userId"),
    }))
}

fn refused(why: &str) -> RpcError {
    RpcError::new(-32000, why).with_data(json!({"reason": "device.enroll_refused"}))
}

/// Only the app socket uses this prelude. Fanout, list subscriptions, and normal
/// request workers do not exist until the hub confirms the browser's identity.
pub(super) async fn admit(
    hub: &Arc<Hub>,
    conn: &Arc<Conn>,
    inbound: &mut tokio::sync::mpsc::Receiver<String>,
) -> bool {
    use crate::rpc::Message;
    if conn.origin != Origin::Web {
        return false;
    }
    while let Some(line) = inbound.recv().await {
        let (id, m, params) = match Message::parse(&line) {
            Ok(Message::Request { id, method, params }) => (id, method, params.unwrap_or_default()),
            _ => return false,
        };
        let Some(answer) = dispatch(hub, conn, &m, &params).await else {
            conn.send(&Message::err(
                id,
                RpcError::new(-32001, "Sign in to connect this browser.")
                    .with_data(json!({"reason": "device.identity_required"})),
            ));
            return false;
        };
        let admitted = m == method::MUX_DEVICE_HELLO && answer.is_ok();
        let reply = match answer {
            Ok(result) => Message::ok(id, result),
            Err(error) => Message::err(id, error),
        };
        conn.send(&reply);
        if admitted {
            return true;
        }
    }
    false
}

async fn verify_owner(hub: &Hub, client: &HttpHub) -> Result<(), RpcError> {
    let origin = hub_origin(hub).await?;
    let (team, user) = crate::cli::cloud_join::browser_app_owner(&origin).ok_or_else(|| {
        owner_error("device.host_not_joined", "This daemon needs an active account join.")
    })?;
    let identity = client.browser_identity(&origin).await.map_err(|_| match client.refused() {
        Some(reason) => revoked(reason),
        None => owner_error("device.hub_unavailable", "The hub could not verify this browser."),
    })?;
    if !same_browser_owner(&identity, &team, &user) {
        return Err(owner_error(
            "device.wrong_owner",
            "Sign in with the account that owns this daemon.",
        ));
    }
    Ok(())
}

fn owner_error(reason: &str, message: &str) -> RpcError {
    RpcError::new(-32003, message).with_data(json!({ "reason": reason }))
}

fn same_browser_owner(identity: &Value, team: &str, user: &str) -> bool {
    !user.is_empty()
        && !team.is_empty()
        && identity.get("platform").and_then(Value::as_str) == Some("web")
        && identity.get("userId").and_then(Value::as_str) == Some(user)
        && identity.get("teamId").and_then(Value::as_str) == Some(team)
}

/// Whether a socket keeps the Origin of the page that opened it, which binds a browser
/// sign-in (`start_with`). Only a web socket admitted by the listener token or by the
/// `/app/ws` token (`ConnAuth::BrowserApp`, the production pane's) has a page origin.
pub(super) fn keeps_page_origin(origin: Origin, auth: ConnAuth) -> bool {
    origin == Origin::Web && matches!(auth, ConnAuth::ListenerToken | ConnAuth::BrowserApp)
}

/// How many renewals in a row may find the hub unavailable before the socket ends:
/// a blip keeps the tab, an outage past about two minutes still ends its access.
const UNAVAILABLE_RENEWALS: u32 = 3;

/// Whether a renewal ends the socket: a refusal or a different owner at once, an
/// unavailable hub only after `UNAVAILABLE_RENEWALS` in a row (`unavailable` counts them).
fn renewal_ends(result: &Result<(), RpcError>, unavailable: &mut u32) -> bool {
    let Err(error) = result else {
        *unavailable = 0;
        return false;
    };
    let reason = error.data.as_ref().and_then(|data| data.get("reason")).and_then(Value::as_str);
    if reason != Some("device.hub_unavailable") {
        return true;
    }
    *unavailable = unavailable.saturating_add(1);
    *unavailable >= UNAVAILABLE_RENEWALS
}

/// A quiet socket can still receive a live transcript. Renew its proof even
/// when the browser makes no requests. A refusal ends it; so does a hub that stays
/// unavailable (`renewal_ends`).
pub(super) async fn credential_ended(hub: &Hub, conn: &Conn) {
    if conn.auth != ConnAuth::BrowserApp {
        return std::future::pending().await;
    }
    let device = match &*conn.device_mesh.lock().unwrap_or_else(|e| e.into_inner()) {
        Slot::Device(device) => Arc::clone(device),
        _ => return,
    };
    let mut unavailable = 0;
    loop {
        tokio::time::sleep(std::time::Duration::from_secs(30)).await;
        if renewal_ends(&verify_owner(hub, &device).await, &mut unavailable) {
            return;
        }
    }
}

#[cfg(test)]
mod browser_owner_tests {
    use super::*;

    #[test]
    fn the_production_pane_socket_keeps_its_page_origin() {
        assert!(keeps_page_origin(Origin::Web, ConnAuth::BrowserApp));
        assert!(keeps_page_origin(Origin::Web, ConnAuth::ListenerToken));
    }

    #[test]
    fn an_unavailable_hub_ends_the_socket_only_when_it_stays_unavailable() {
        let unavailable = || Err(owner_error("device.hub_unavailable", "down"));
        let mut count = 0;
        assert!(!renewal_ends(&unavailable(), &mut count));
        assert!(!renewal_ends(&unavailable(), &mut count));
        assert!(!renewal_ends(&Ok(()), &mut count), "a success resets the count");
        assert!(!renewal_ends(&unavailable(), &mut count));
        assert!(!renewal_ends(&unavailable(), &mut count));
        assert!(renewal_ends(&unavailable(), &mut count));
        let mut fresh = 0;
        assert!(renewal_ends(&Err(owner_error("device.wrong_owner", "no")), &mut fresh));
    }

    #[test]
    fn requires_a_web_device_from_the_same_person_and_team() {
        let valid = json!({"platform": "web", "userId": "owner", "teamId": "team"});
        assert!(same_browser_owner(&valid, "team", "owner"));
        assert!(!same_browser_owner(&valid, "team", "other"));
        assert!(!same_browser_owner(&valid, "other", "owner"));
        for field in ["platform", "teamId", "userId"] {
            let mut missing = valid.clone();
            missing.as_object_mut().unwrap().remove(field);
            assert!(!same_browser_owner(&missing, "team", "owner"));
        }
        let mut machine = valid;
        machine["platform"] = json!("linux");
        assert!(!same_browser_owner(&machine, "team", "owner"));
    }
}

/// The longest page Origin a socket keeps (`Conn::page_origin`).
pub(super) const MAX_ORIGIN_BYTES: usize = 512;
/// The longest email, emailed code and device key a sign-in takes; `BrowserSignIn` checks each.
const MAX_EMAIL_BYTES: usize = 320;
const MAX_CODE_BYTES: usize = 64;
const MAX_KEY_BYTES: usize = 64;
/// What `browser_sign_in_start` answers: `BrowserSignIn`'s lifetime, in seconds.
const SIGN_IN_EXPIRES_IN: u64 = 300;

/// The daemon's trusted half of a browser sign-in: its owner and its deployment's Stack project.
#[derive(Clone, Debug, PartialEq, Eq)]
pub(super) struct SignInConfig {
    pub owner_user_id: String,
    pub stack: cmux_stack_auth::StackConfig,
    /// The deployment's email-link callback, as the app's own email sign-in sends it
    /// (`CloudAuth.swift`: `authWebOrigin` + `/auth/callback`).
    pub callback_url: String,
}

/// The sign-in configuration of this machine's join `record` (`machine_record.rs`): its owner is
/// the person the hub named for its credential (`userId`), and its Stack project is the one of
/// the cmux deployment whose platform it joined (`cmux-cloud-environment`). None of it comes from
/// a request. The refusal names what is missing.
pub(super) fn sign_in_config(
    record: Option<&crate::machine_record::MachineCredential>,
) -> Result<SignInConfig, RpcError> {
    use cmux_cloud_environment as env;
    let record = record.filter(|r| !r.revoked).ok_or_else(|| unconfigured("machineJoin"))?;
    let owner_user_id = record
        .user_id
        .as_deref()
        .and_then(crate::machine_record::safe_id)
        .ok_or_else(|| unconfigured("ownerUserId"))?;
    let platform = record.hub_origin.trim().trim_end_matches('/');
    let deployment = [
        env::PRODUCTION_DEPLOYMENT,
        env::STAGING_DEPLOYMENT,
        env::DEVELOPMENT_DEPLOYMENT,
        env::LOCAL_DEPLOYMENT,
    ]
    .into_iter()
    .find(|d| d.platform_origin == platform)
    .ok_or_else(|| unconfigured("stackDeployment"))?;
    Ok(SignInConfig {
        owner_user_id,
        stack: cmux_stack_auth::StackConfig::new(
            env::STACK_ORIGIN,
            deployment.stack_project_id,
            deployment.stack_client_key,
        ),
        callback_url: format!("{}/auth/callback", deployment.auth_web_origin.trim_end_matches('/')),
    })
}

/// `missing` is the trusted input this daemon lacks: `machineJoin` (not joined here, copied from
/// another box, or revoked), `ownerUserId` (the join named no person) or `stackDeployment` (its
/// platform is no known cmux deployment).
fn unconfigured(missing: &str) -> RpcError {
    RpcError::new(-32000, "this machine has no owner to sign a browser in for: join it first")
        .with_data(json!({"reason": "signin.unconfigured", "missing": missing}))
}

/// A `BrowserSignIn` refusal: only its fixed reason, never Stack's body or a token.
fn sign_in_refused(error: cmux_stack_auth::BrowserSignInError) -> RpcError {
    use cmux_stack_auth::BrowserSignInError as E;
    let code = match error {
        E::InvalidOrigin | E::InvalidPublicKey | E::InvalidInput => -32602,
        E::RateLimited => -32004,
        _ => -32000,
    };
    RpcError::new(code, error.code()).with_data(json!({"reason": error.code()}))
}

/// A short string param, at most `max` bytes; the refusal never repeats it.
fn short_param<'a>(params: &'a Value, key: &str, max: usize) -> Result<&'a str, RpcError> {
    params
        .get(key)
        .and_then(Value::as_str)
        .filter(|v| !v.is_empty() && v.len() <= max)
        .ok_or_else(|| RpcError::invalid_params(format!("{key} is required")))
}

fn stack_client(config: &SignInConfig) -> Result<cmux_stack_auth::StackClient, RpcError> {
    cmux_stack_auth::StackClient::new(config.stack.clone())
        .map_err(|_| RpcError::internal("the sign-in client could not be built"))
}

/// `_acpmux/browser_sign_in_start {email, publicKey}` -> `{expiresIn: 300}`.
async fn sign_in_start(conn: &Conn, params: &Value) -> Result<Value, RpcError> {
    web_only(conn, method::MUX_BROWSER_SIGN_IN_START)?;
    let config =
        sign_in_config(crate::machine_record::machine_credential().ok().flatten().as_ref());
    start_with(&conn.browser_sign_in, conn.page_origin.as_deref(), config, params).await
}

/// `_acpmux/browser_sign_in_complete {code}` -> `{accessToken, publicKey}`.
async fn sign_in_complete(conn: &Conn, params: &Value) -> Result<Value, RpcError> {
    web_only(conn, method::MUX_BROWSER_SIGN_IN_COMPLETE)?;
    let config =
        sign_in_config(crate::machine_record::machine_credential().ok().flatten().as_ref());
    complete_with(&conn.browser_sign_in, conn.page_origin.as_deref(), config, params).await
}

type Pending = std::sync::Mutex<Option<cmux_stack_auth::BrowserSignIn>>;

/// The start, given the connection's pending slot, its page origin and the daemon's config.
/// The prior attempt is dropped first, so a failed start leaves none.
pub(super) async fn start_with(
    pending: &Pending,
    page_origin: Option<&str>,
    config: Result<SignInConfig, RpcError>,
    params: &Value,
) -> Result<Value, RpcError> {
    drop(pending.lock().unwrap_or_else(|e| e.into_inner()).take());
    let email = short_param(params, "email", MAX_EMAIL_BYTES)?;
    let key = short_param(params, "publicKey", MAX_KEY_BYTES)?;
    let config = config?;
    let origin = page_origin
        .ok_or(cmux_stack_auth::BrowserSignInError::InvalidOrigin)
        .map_err(sign_in_refused)?;
    let stack = stack_client(&config)?;
    let attempt = cmux_stack_auth::BrowserSignIn::start(
        &stack,
        origin,
        &config.owner_user_id,
        key,
        email,
        &config.callback_url,
    )
    .await
    .map_err(sign_in_refused)?;
    // A start that finished after a newer one replaces it too: the last answer wins.
    *pending.lock().unwrap_or_else(|e| e.into_inner()) = Some(attempt);
    Ok(json!({"expiresIn": SIGN_IN_EXPIRES_IN}))
}

/// The completion: takes the pending attempt before it awaits, so it is used once.
pub(super) async fn complete_with(
    pending: &Pending,
    page_origin: Option<&str>,
    config: Result<SignInConfig, RpcError>,
    params: &Value,
) -> Result<Value, RpcError> {
    let attempt = pending.lock().unwrap_or_else(|e| e.into_inner()).take().ok_or_else(|| {
        RpcError::invalid_params("no sign-in is pending on this connection: start one")
            .with_data(json!({"reason": "browser.sign_in.not_started"}))
    })?;
    let code = short_param(params, "code", MAX_CODE_BYTES)?;
    let config = config?;
    let origin = page_origin
        .ok_or(cmux_stack_auth::BrowserSignInError::InvalidOrigin)
        .map_err(sign_in_refused)?;
    let stack = stack_client(&config)?;
    let enrollment = attempt.complete(&stack, origin, code).await.map_err(sign_in_refused)?;
    let access = Zeroizing::new(enrollment.access_token);
    Ok(json!({"accessToken": access.as_str(), "publicKey": enrollment.public_key}))
}

#[cfg(test)]
#[path = "web_device_tests.rs"]
mod tests;
