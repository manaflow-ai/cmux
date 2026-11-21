//! The coordinator in process, the way both apps run it: through the C ABI
//! the macOS app calls (src/ffi.rs) and the JSON wire the iOS UniFFI object
//! shares (src/wire.rs), with a shell that runs every effect against the
//! real `cmux-stack-auth` client and a fake Stack on a local port
//! (cmux-stack-auth's own test fake). This is the shape the Swift
//! `AuthCoordinator` takes as a thin client: feed events, run effects.

#[path = "../../cmux-stack-auth/tests/fake/mod.rs"]
mod fake;

use std::time::Duration;

use cmux_auth_coordinator::ffi::*;
use cmux_stack_auth::{Session, StackClient, StackConfig, StackError};
use fake::{Log, Reply, Seen, ok, serve, status, token};
use serde_json::{Value, json};

/// The coordinator behind its C handle.
struct Handle(*mut CmuxAuthCoordinator);

impl Drop for Handle {
    fn drop(&mut self) {
        // SAFETY: from `cmux_auth_coordinator_new`, freed once.
        unsafe { cmux_auth_coordinator_free(self.0) };
    }
}

fn read_bytes(out: CmuxAuthCoordinatorBytes) -> Value {
    if out.ptr.is_null() {
        return Value::Null;
    }
    // SAFETY: a reply buffer of `len` bytes from the library.
    let bytes = unsafe { std::slice::from_raw_parts(out.ptr, out.len) };
    let value = serde_json::from_slice(bytes).expect("JSON reply");
    // SAFETY: freed once.
    unsafe { cmux_auth_coordinator_bytes_free(out) };
    value
}

impl Handle {
    fn new(config: &Value) -> Result<Self, i32> {
        let bytes = serde_json::to_vec(config).unwrap();
        let mut handle = std::ptr::null_mut();
        // SAFETY: valid pointers for the call.
        let code = unsafe { cmux_auth_coordinator_new(bytes.as_ptr(), bytes.len(), &mut handle) };
        if code == CMUX_AUTH_COORDINATOR_OK { Ok(Self(handle)) } else { Err(code) }
    }

    fn feed_raw(&self, bytes: &[u8]) -> i32 {
        // SAFETY: a live handle; valid pointers for the call.
        unsafe { cmux_auth_coordinator_feed(self.0, bytes.as_ptr(), bytes.len()) }
    }

    fn feed(&self, event: Value) {
        let code = self.feed_raw(&serde_json::to_vec(&event).unwrap());
        assert_eq!(code, CMUX_AUTH_COORDINATOR_OK, "fed {event}");
    }

    fn take_effects(&self) -> Vec<Value> {
        let mut out = CmuxAuthCoordinatorBytes { ptr: std::ptr::null_mut(), len: 0 };
        // SAFETY: a live handle; `out` is writable.
        let code = unsafe { cmux_auth_coordinator_take_effects(self.0, &mut out) };
        assert_eq!(code, CMUX_AUTH_COORDINATOR_OK);
        match read_bytes(out) {
            Value::Array(items) => items,
            other => panic!("effects are not an array: {other}"),
        }
    }

    fn snapshot(&self) -> Value {
        let mut out = CmuxAuthCoordinatorBytes { ptr: std::ptr::null_mut(), len: 0 };
        // SAFETY: a live handle; `out` is writable.
        let code = unsafe { cmux_auth_coordinator_snapshot(self.0, &mut out) };
        assert_eq!(code, CMUX_AUTH_COORDINATOR_OK);
        read_bytes(out)
    }
}

/// What the Swift shell does around the reducer: the token store, the
/// password it was handed, and the I/O each effect names.
struct Shell {
    coordinator: Handle,
    stack: StackClient,
    tokens: Option<Session>,
    /// The credentials of the sign-in in flight; the reducer never sees them.
    credentials: Option<(String, String)>,
    teardown: Option<Session>,
    /// Every effect run, in order.
    ran: Vec<Value>,
    rt: tokio::runtime::Runtime,
}

/// The display-safe reading of a client error (Swift `AuthError+DisplaySafe`).
fn failure(error: &StackError) -> Value {
    match error {
        StackError::RateLimited(_) => json!({"rateLimited": {"retryAfter": null}}),
        StackError::Network(_) => json!("networkError"),
        StackError::TimedOut => json!("timedOut"),
        StackError::NotSignedIn | StackError::Http { status: 401, .. } => json!("unauthorized"),
        _ => json!("other"),
    }
}

fn result<T>(value: Result<T, StackError>, ok: impl FnOnce(T) -> Value) -> Value {
    match value {
        Ok(value) => json!({"Ok": ok(value)}),
        Err(error) => json!({"Err": failure(&error)}),
    }
}

fn user_json(user: cmux_stack_auth::CurrentUser) -> Value {
    json!({
        "id": user.id,
        "primaryEmail": user.primary_email,
        "displayName": user.display_name,
        "profileImageUrl": user.profile_image_url,
        "demonstrationContentEnabled": user.demonstration_content_enabled,
    })
}

/// The one key of an effect object, and its payload; a unit effect is its name.
fn split(effect: &Value) -> (&str, &Value) {
    match effect {
        Value::String(name) => (name, &Value::Null),
        Value::Object(map) if map.len() == 1 => {
            let (name, payload) = map.iter().next().unwrap();
            (name, payload)
        }
        other => panic!("not an effect: {other}"),
    }
}

impl Shell {
    fn new(origin: &str, tokens: Option<Session>, cached_user: Option<Value>) -> Self {
        let mut config = StackConfig::new(origin, "proj-1", "pck_key");
        config.transport_retry_base = Duration::ZERO;
        let persisted = json!({"cachedUser": cached_user, "hasTokens": tokens.is_some()});
        Self {
            coordinator: Handle::new(&json!({"persisted": persisted, "jitterSeed": 7})).unwrap(),
            stack: StackClient::new(config).unwrap(),
            tokens,
            credentials: None,
            teardown: None,
            ran: Vec::new(),
            rt: tokio::runtime::Builder::new_current_thread().enable_all().build().unwrap(),
        }
    }

    /// Feeds `event`, then runs effects until the queue is empty.
    fn send(&mut self, event: Value) {
        self.coordinator.feed(event);
        self.drain();
    }

    fn drain(&mut self) {
        loop {
            let effects = self.coordinator.take_effects();
            if effects.is_empty() {
                return;
            }
            for effect in effects {
                self.run(&effect);
                self.ran.push(effect);
            }
        }
    }

    fn ran(&self, name: &str) -> bool {
        self.ran.iter().any(|effect| split(effect).0 == name)
    }

    fn run(&mut self, effect: &Value) {
        let (name, payload) = split(effect);
        let payload = payload.clone();
        match name {
            "probeStoredTokens" => self.coordinator.feed(json!({"tokensProbed": {
                "ticket": payload,
                "probe": {"Ok": self.tokens.is_some()},
                "storageWasAvailable": true,
                "readFailed": false,
            }})),
            "validateCachedSession" => {
                let mut tokens = self.tokens.clone().unwrap_or_default();
                let answer = self.rt.block_on(self.stack.current_user(&mut tokens));
                self.tokens = Some(tokens);
                self.coordinator.feed(json!({"cachedSessionValidated": {
                    "ticket": payload,
                    "result": result(answer, |user| user.map_or(Value::Null, user_json)),
                }}));
            }
            "readSurvivingRefreshToken" => {
                let has_refresh =
                    self.tokens.as_ref().is_some_and(|tokens| tokens.refresh_token.is_some());
                self.coordinator.feed(json!({"survivingRefreshTokenRead": {
                    "ticket": payload["ticket"],
                    "afterError": payload["afterError"],
                    "result": {"Ok": has_refresh},
                    "readFailed": false,
                }}));
            }
            "clearStaleSession" => {
                self.tokens = None;
                self.coordinator.feed(json!({"staleSessionCleared": {
                    "ticket": payload["ticket"],
                    "reason": payload["reason"],
                }}));
            }
            "quiesceTokenWork" => self.coordinator.feed(
                json!({"tokenWorkQuiesced": {"flow": payload["flow"], "result": {"Ok": null}}}),
            ),
            "checkOnline" => {
                self.coordinator.feed(json!({"onlineChecked": {"flow": payload, "online": true}}));
            }
            "runExchange" => {
                assert_eq!(payload["phase"], json!("password_sign_in"));
                assert_eq!(payload["budget"], json!("network"));
                let (email, password) = self.credentials.take().expect("credentials");
                let answer = self.rt.block_on(self.stack.sign_in_with_password(&email, &password));
                let answer = answer.map(|tokens| self.tokens = Some(tokens));
                self.coordinator.feed(json!({"exchangeFinished": {
                    "flow": payload["flow"],
                    "result": result(answer, |()| Value::Null),
                }}));
            }
            "fetchUser" => {
                let mut tokens = self.tokens.clone().unwrap_or_default();
                let answer = self.rt.block_on(self.stack.current_user(&mut tokens));
                self.tokens = Some(tokens);
                self.coordinator.feed(json!({"signInUserFetched": {
                    "flow": payload,
                    "result": result(answer, |user| user.map_or(Value::Null, user_json)),
                }}));
            }
            "refreshTeams" => {
                let mut tokens = self.tokens.clone().unwrap_or_default();
                let answer = self.rt.block_on(async {
                    let teams = self.stack.list_teams(&mut tokens).await?;
                    let selected = self.stack.selected_team_id(&mut tokens).await?;
                    Ok((teams, selected))
                });
                self.tokens = Some(tokens);
                self.coordinator.feed(json!({"teamsRefreshed": {
                    "ticket": payload,
                    "result": result(answer, |(teams, selected)| json!({
                        "teams": teams.into_iter().map(|team| json!({
                            "id": team.id,
                            "displayName": team.display_name,
                            "plan": team.plan,
                        })).collect::<Vec<_>>(),
                        "serverSelectedTeamId": selected,
                    })),
                }}));
            }
            "runPostSignInHook" => {
                self.coordinator.feed(json!({"postSignInHookFinished": {"ticket": payload}}));
            }
            "captureTeardownCredentialsAndClearLocalSession" => {
                self.teardown = self.tokens.take();
                self.coordinator.feed(json!({"signOutLocalCleared": {
                    "signOutEpoch": payload["signOutEpoch"],
                }}));
            }
            "serverTeardown" => {
                if let Some(captured) = self.teardown.take() {
                    self.rt.block_on(self.stack.revoke_session(&captured)).unwrap();
                }
            }
            "clearLocalSession" => self.tokens = None,
            // Publications, caches and bookkeeping the Swift shell applies with no answer.
            _ => {}
        }
    }
}

fn user_answer() -> Value {
    json!({
        "id": "u1",
        "primary_email": "u1@example.com",
        "display_name": "U One",
        "selected_team": {"id": "t2"},
    })
}

fn teams_answer() -> Value {
    json!({"items": [
        {"id": "t1", "display_name": "Acme", "client_read_only_metadata": {"cmuxPlan": "pro"}},
        {"id": "t2", "display_name": "Beta"},
    ]})
}

/// A fake Stack that signs in, answers the user and the teams, and revokes.
fn stack() -> (String, Log) {
    let access = token(600, 900, "access");
    serve(move |seen: &Seen| match (seen.method.as_str(), seen.target.as_str()) {
        ("POST", "/api/v1/auth/password/sign-in") => {
            ok(json!({"access_token": access, "refresh_token": "refresh-1"}))
        }
        ("GET", "/api/v1/users/me") => ok(user_answer()),
        ("GET", "/api/v1/teams?user_id=me") => ok(teams_answer()),
        ("DELETE", "/api/v1/auth/sessions/current") => ok(json!({})),
        _ => status(404, json!({})),
    })
}

fn targets(log: &Log) -> Vec<String> {
    log.lock().unwrap().iter().map(|seen| format!("{} {}", seen.method, seen.target)).collect()
}

#[test]
fn a_password_sign_in_runs_end_to_end_against_stack() {
    assert_eq!(cmux_auth_coordinator_abi_version(), CMUX_AUTH_COORDINATOR_ABI_VERSION);
    let (origin, log) = stack();
    let mut shell = Shell::new(&origin, None, None);
    shell.drain();
    assert_eq!(shell.coordinator.snapshot()["isAuthenticated"], json!(false));

    shell.credentials = Some(("u1@example.com".into(), "pw".into()));
    shell.send(json!({"signInRequested": {"kind": "password", "setsLoading": true}}));

    assert!(shell.ran("signInSucceeded"), "ran {:?}", shell.ran);
    assert!(!shell.ran("signInFailed"));
    let snapshot = shell.coordinator.snapshot();
    assert_eq!(snapshot["isAuthenticated"], json!(true));
    assert_eq!(snapshot["isLoading"], json!(false));
    assert_eq!(snapshot["currentUser"]["id"], json!("u1"));
    assert_eq!(snapshot["currentUser"]["primaryEmail"], json!("u1@example.com"));
    assert_eq!(snapshot["availableTeams"][0]["plan"], json!("pro"));
    // The server's cross-device selection wins over the first team.
    assert_eq!(snapshot["resolvedTeamId"], json!("t2"));
    assert_eq!(snapshot["teamScope"]["teamId"], json!("t2"));
    assert_eq!(snapshot["teamScope"]["session"]["accountId"], json!("u1"));
    assert_eq!(snapshot["sessionGeneration"], json!(1));
    assert!(shell.tokens.is_some());

    let seen = targets(&log);
    assert_eq!(seen[0], "POST /api/v1/auth/password/sign-in");
    assert!(seen.contains(&"GET /api/v1/users/me".to_owned()));
    assert!(seen.contains(&"GET /api/v1/teams?user_id=me".to_owned()));
    let wire = serde_json::to_string(&shell.ran).unwrap();
    assert!(!wire.contains("refresh-1") && !wire.contains("\"pw\""), "no secret on the wire");
}

#[test]
fn a_launch_restore_with_stored_tokens_validates_and_loads_teams() {
    let (origin, log) = stack();
    let stored = Session::new(Some(&token(600, 900, "stored")), Some("refresh-1"));
    let cached = json!({"id": "u1", "primaryEmail": "u1@example.com"});
    let mut shell = Shell::new(&origin, Some(stored), Some(cached));
    shell.drain();
    // A cached user with stored tokens reads as signed in at once.
    let primed = shell.coordinator.snapshot();
    assert_eq!(primed["isAuthenticated"], json!(true));
    assert_eq!(primed["isRestoringSession"], json!(true));

    shell.send(json!({"restore": "launch"}));

    assert!(shell.ran("restoreFinished"), "ran {:?}", shell.ran);
    let snapshot = shell.coordinator.snapshot();
    assert_eq!(snapshot["isAuthenticated"], json!(true));
    assert_eq!(snapshot["isRestoringSession"], json!(false));
    assert_eq!(snapshot["currentUser"]["displayName"], json!("U One"));
    assert_eq!(snapshot["teamScope"]["teamId"], json!("t2"));
    assert!(targets(&log).contains(&"GET /api/v1/users/me".to_owned()));
}

#[test]
fn a_restore_the_server_no_longer_knows_signs_out() {
    // The access token is rejected and no refresh works: the session is gone.
    let (origin, _log) = serve(|seen: &Seen| match seen.target.as_str() {
        "/api/v1/auth/oauth/token" => status(401, json!({"error": "invalid_grant"})),
        _ => status(401, json!({})),
    });
    let stored = Session::new(Some(&token(-10, 900, "expired")), Some("refresh-1"));
    let mut shell = Shell::new(&origin, Some(stored), Some(json!({"id": "u1"})));
    shell.drain();
    shell.send(json!({"restore": "launch"}));

    assert!(shell.ran("restoreFinished"), "ran {:?}", shell.ran);
    let snapshot = shell.coordinator.snapshot();
    assert_eq!(snapshot["isAuthenticated"], json!(false));
    assert_eq!(snapshot["isRestoringSession"], json!(false));
    assert!(snapshot["teamScope"].is_null());
}

#[test]
fn sign_out_clears_the_store_and_revokes_the_server_session() {
    let (origin, log) = stack();
    let mut shell = Shell::new(&origin, None, None);
    shell.drain();
    shell.credentials = Some(("u1@example.com".into(), "pw".into()));
    shell.send(json!({"signInRequested": {"kind": "password", "setsLoading": true}}));
    assert_eq!(shell.coordinator.snapshot()["isAuthenticated"], json!(true));

    shell.send(json!("signOutRequested"));

    let snapshot = shell.coordinator.snapshot();
    assert_eq!(snapshot["isAuthenticated"], json!(false));
    assert!(snapshot["currentUser"].is_null());
    assert_eq!(snapshot["signOutRevision"], json!(1));
    assert!(snapshot["sessionIdentity"].is_null());
    assert!(shell.tokens.is_none());
    assert!(shell.ran("serverTeardown"));
    assert_eq!(
        targets(&log).last().map(String::as_str),
        Some("DELETE /api/v1/auth/sessions/current")
    );
}

#[test]
fn the_c_abi_refuses_bad_input_and_changes_nothing() {
    assert_eq!(Handle::new(&json!({"launch": 3})).err(), Some(CMUX_AUTH_COORDINATOR_ERR_INVALID));
    let mut handle = std::ptr::null_mut();
    // SAFETY: a null config with a nonzero length is refused before any read.
    let code = unsafe { cmux_auth_coordinator_new(std::ptr::null(), 4, &mut handle) };
    assert_eq!(code, CMUX_AUTH_COORDINATOR_ERR_NULL);
    assert!(handle.is_null());
    // SAFETY: a null `out` is refused before any write.
    let code = unsafe { cmux_auth_coordinator_new(std::ptr::null(), 0, std::ptr::null_mut()) };
    assert_eq!(code, CMUX_AUTH_COORDINATOR_ERR_NULL);

    let coordinator = Handle::new(&json!({})).unwrap();
    coordinator.take_effects();
    let before = coordinator.snapshot();
    assert_eq!(
        coordinator.feed_raw(b"{\"restore\": \"sideways\"}"),
        CMUX_AUTH_COORDINATOR_ERR_INVALID
    );
    assert_eq!(coordinator.feed_raw(b"not json"), CMUX_AUTH_COORDINATOR_ERR_INVALID);
    assert_eq!(coordinator.feed_raw(&[]), CMUX_AUTH_COORDINATOR_ERR_INVALID);
    assert_eq!(coordinator.snapshot(), before);
    assert!(coordinator.take_effects().is_empty());
    // SAFETY: null handles are refused.
    unsafe {
        assert_eq!(
            cmux_auth_coordinator_feed(std::ptr::null_mut(), std::ptr::null(), 0),
            CMUX_AUTH_COORDINATOR_ERR_NULL
        );
        cmux_auth_coordinator_free(std::ptr::null_mut());
        cmux_auth_coordinator_bytes_free(CmuxAuthCoordinatorBytes {
            ptr: std::ptr::null_mut(),
            len: 0,
        });
    }
}

#[test]
fn every_effect_and_the_snapshot_have_the_documented_shape() {
    let coordinator =
        Handle::new(&json!({"launch": {"debugBuild": true, "mockDataEnabled": true}})).unwrap();
    // Mock-data mode primes the fixed UI-test user.
    assert_eq!(coordinator.snapshot()["currentUser"]["id"], json!("uitest_user"));
    for effect in coordinator.take_effects() {
        split(&effect);
    }
    let snapshot = coordinator.snapshot();
    for key in [
        "isAuthenticated",
        "currentUser",
        "isRestoringSession",
        "isLoading",
        "availableTeams",
        "selectedTeamId",
        "resolvedTeamId",
        "sessionGeneration",
        "signOutRevision",
        "lastSignOutReason",
        "hasPendingCode",
        "teamScopeGeneration",
        "hasPendingTeamScopeRecovery",
        "needsTeamScopeRecovery",
        "sessionTokenTransitionIsActive",
        "sessionIdentity",
        "publishedSessionIdentity",
        "teamScope",
        "cachedTeamIdentity",
        "tokenStoreWriteHighWater",
        "hasActiveSignInFlows",
    ] {
        assert!(snapshot.get(key).is_some(), "snapshot lacks {key}: {snapshot}");
    }
}

#[test]
fn a_stalled_stack_is_not_the_reducers_to_wait_on() {
    // The reducer holds no timer: the shell answers a call the fake never
    // finishes with the failure its deadline produced.
    let (origin, _log) = serve(|_| Reply::Stall);
    let mut shell = Shell::new(&origin, None, None);
    shell.drain();
    shell.coordinator.feed(json!({"signInRequested": {"kind": "password", "setsLoading": true}}));
    let fx = shell.coordinator.take_effects();
    let flow = fx
        .iter()
        .find_map(|effect| effect.get("quiesceTokenWork"))
        .expect("sign-in quiesces token work first")["flow"]
        .clone();
    shell.coordinator.feed(json!({"tokenWorkQuiesced": {"flow": flow, "result": {"Ok": null}}}));
    shell.coordinator.feed(json!({"onlineChecked": {"flow": flow, "online": true}}));
    shell.coordinator.take_effects();
    shell
        .coordinator
        .feed(json!({"exchangeFinished": {"flow": flow, "result": {"Err": "timedOut"}}}));
    let fx = shell.coordinator.take_effects();
    assert!(
        fx.iter().any(|effect| effect
            .get("signInFailed")
            .is_some_and(|f| f["failure"] == json!("timedOut"))),
        "{fx:?}"
    );
    assert_eq!(shell.coordinator.snapshot()["isLoading"], json!(false));
}
