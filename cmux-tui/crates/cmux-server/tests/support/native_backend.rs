//! Backend boundary fixture verifies the daemon's actual signatures and pins.
use super::*;

pub(super) fn post(
    api: &Api,
    origin: &str,
    path: &str,
    body: &Value,
    bearer: Option<&str>,
) -> Result<Value> {
    assert_eq!(origin, API);
    assert_eq!(pairing::status(&api.path).unwrap()["state"], "network_pending");
    assert!(EnrolledIdentity::load(&api.path).is_err());
    assert!(!private_record(&api.path).to_string().contains(CODE));
    let mut state = api.state.lock().unwrap();
    state.backend_calls.push((path.into(), body.clone()));
    let user = "user_00000000000000000001";
    let install = "inst_00000000000000000001";
    let host = "host_00000000000000000001";
    let team = "team_00000000000000000001";
    let nonce = "a".repeat(64);
    match path {
        "/v1/auth/challenge" => {
            assert!(bearer.is_none());
            assert_eq!(body, &json!({"user":user,"install":install}));
            let mut answer = json!({"install":install,"nonce":nonce,"expires_at":state.now+60_000,
                "message_prefix":format!("cmux-auth-v1\ntest\n{install}\n")});
            match state.backend_fault {
                Some("prefix") => answer["message_prefix"] = "another-purpose\n".into(),
                Some("challenge_install") => answer["install"] = "another-install".into(),
                Some("nonce") => answer["nonce"] = "arbitrary\nmessage".into(),
                Some("challenge_expired") => answer["expires_at"] = state.now.into(),
                _ => {}
            }
            Ok(answer)
        }
        "/v1/auth/token" => {
            assert!(bearer.is_none());
            assert_eq!(body.as_object().unwrap().len(), 4);
            assert_eq!(body["user"], user);
            assert_eq!(body["install"], install);
            assert_eq!(body["nonce"], nonce);
            assert!(verify(
                &state.begin["public_jwk"],
                format!("cmux-auth-v1\ntest\n{install}\n{nonce}").as_bytes(),
                body["signature"].as_str().unwrap()
            ));
            let mut answer = json!({"access_token":"fixture-daemon-access","token_type":"Bearer",
                "expires_at":state.now+300_000,"user":user,"team":team,"install":install,"grant":"grant_fixture"});
            match state.backend_fault {
                Some("token_team") => answer["team"] = "another-team".into(),
                Some("token_user") => answer["user"] = "another-user".into(),
                Some("token_install") => answer["install"] = "another-install".into(),
                Some("token_expired") => answer["expires_at"] = state.now.into(),
                _ => {}
            }
            Ok(answer)
        }
        "/v1/ops" => {
            assert_eq!(bearer, Some("fixture-daemon-access"));
            assert_eq!(body["op"], "server.network.confirm");
            assert_eq!(body["idempotency_key"], format!("server-network:{host}:{DEVICE}"));
            let params = &body["params"];
            assert_eq!(params.as_object().unwrap().len(), 4);
            assert_eq!(params["host"], host);
            assert_eq!(params["mesh"], MESH);
            assert_eq!(params["device"], DEVICE);
            let proof = &params["proof"];
            assert_eq!(proof.as_object().unwrap().len(), 3);
            assert_eq!(proof["signedAt"], state.now);
            assert!(state.calls.iter().all(|(_, prior)| prior["nonce"] != proof["nonce"]));
            let previous = &state.backend_calls[..state.backend_calls.len() - 1];
            assert!(
                previous
                    .iter()
                    .filter(|(p, _)| p == "/v1/ops")
                    .all(|(_, prior)| prior["params"]["proof"]["nonce"] != proof["nonce"])
            );
            let point = point(&state.begin["public_jwk"]);
            let message = format!(
                "cmux-mesh-v1\noverlay-server-policy\n{DEVICE}\n\n{point}\n\n{}\n{}",
                state.now,
                proof["nonce"].as_str().unwrap()
            );
            let signature = URL_SAFE_NO_PAD
                .encode(STANDARD.decode(proof["signature"].as_str().unwrap()).unwrap());
            assert!(verify(&state.begin["public_jwk"], message.as_bytes(), &signature));
            if matches!(state.fault, Fault::Backend) {
                return Err(Error::unreachable("fixture.backend_unavailable"));
            }
            if state.backend_fault == Some("refused") {
                return Ok(
                    json!({"ok":false,"error":{"code":"auth.forbidden","retryable":false,"message":"private fixture error"}}),
                );
            }
            if state.backend_fault == Some("retryable") {
                return Ok(
                    json!({"ok":false,"error":{"code":"owner.unreachable","retryable":true}}),
                );
            }
            let now = state.now;
            let at = *state.confirmed_at.get_or_insert(now);
            if state.lose_backend_reply {
                state.lose_backend_reply = false;
                return Err(Error::unreachable("fixture.lost_backend_reply"));
            }
            let mut answer = json!({"ok":true,"op":"server.network.confirm","idempotency_key":body["idempotency_key"],
                "value":{"host":host,"network":{"state":"confirmed","tenant":"native_team","mesh":MESH,"device":DEVICE,"confirmed_at":at}},
                "accountCredential":"fixture-must-not-persist"});
            if let Some(pointer) = state.backend_fault.filter(|s| s.starts_with('/')) {
                *answer.pointer_mut(pointer).unwrap() = json!("another-identity");
            }
            Ok(answer)
        }
        _ => panic!("unexpected backend path"),
    }
}
