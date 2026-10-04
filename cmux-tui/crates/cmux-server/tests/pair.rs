//! `cmux server pair` (server.md 6.2 steps 1, 2, 5): the install identity
//! and its backend-compatible thumbprint and proof, then begin, wait,
//! refusal, expiry and timeout against a local fake of the API Worker.

mod common;
mod pair_fake;

use std::time::{Duration, Instant};

use base64::Engine;
use base64::engine::general_purpose::URL_SAFE_NO_PAD;
use cmux_server::cli::parse;
use cmux_server::error::ExitKind;
use cmux_server::host;
use cmux_server::pair::identity::{
    INSTALL_KEY_FILE, InstallIdentity, WG_KEY_FILE, begin_proof_message, jwk_thumbprint,
};
use cmux_server::pair::{
    ApiTarget, CREDENTIALS_FILE, HostInfo, PENDING_FILE, PairOutcome, PairRequest, Started,
    pairing_dir, run,
};
use cmux_server_core::layout::Layout;
use cmux_server_core::pairing::{PairingCode, fingerprint_words, qr_payload};
use common::layout_at;
use pair_fake::{CODE, FakeApi, SECRET, Script};
use ring::signature::{ECDSA_P256_SHA256_FIXED, UnparsedPublicKey};

/// A vector made with Node's crypto using the backend's own expressions:
/// `jwkThumbprint` (apps/api/src/domains/user.ts) and `beginProofMessage`
/// (apps/api/src/domains/pairing.ts), signed with `dsaEncoding:
/// "ieee-p1363"` (raw r||s), as `verifyInstallSignature` checks first.
/// A test key only; it protects nothing.
mod vector {
    pub const PKCS8_HEX: &str = "308187020100301306072a8648ce3d020106082a8648ce3d030107046d306b02010104209d2fcd9996a3f45975817d5d7a3df948c4e29f90597734f041f7fdbe27c771bfa14403420004ed92baa0b8593dbc0a264529bab177e27055772c41cc698902331d2627c07775570235993fc49c0c727498b35907207b3d3fccbfe5da214f4e7a324d3154681f";
    pub const X: &str = "7ZK6oLhZPbwKJkUpurF34nBVdyxBzGmJAjMdJifAd3U";
    pub const Y: &str = "VwI1mT_EnAxydJizWQcgez0_zL_l2iFPTnoyTTFUaB8";
    pub const THUMBPRINT: &str = "qEiara5x3oyilOowguIm887ryuHi9i5OflqbYstYZ-0";
    pub const WG: &str = "BwcHBwcHBwcHBwcHBwcHBwcHBwcHBwcHBwcHBwcHBwc=";
    pub const ISSUED_AT: u64 = 1_791_100_000_000;
    pub const SIGNATURE: &str =
        "AWaIhCX5W9uwSe1JPkKhRb_6cqp5u9ewqJw1lvn_JktBEpk9-p400YYkLoU3Ifn6_rC70ZT6ASanwzC1r8gU6w";
}

fn unhex(s: &str) -> Vec<u8> {
    (0..s.len()).step_by(2).map(|i| u8::from_str_radix(&s[i..i + 2], 16).unwrap()).collect()
}

fn point(x: &str, y: &str) -> Vec<u8> {
    let mut p = vec![4u8];
    p.extend(URL_SAFE_NO_PAD.decode(x).unwrap());
    p.extend(URL_SAFE_NO_PAD.decode(y).unwrap());
    p
}

fn info() -> HostInfo {
    HostInfo {
        name: "Studio".into(),
        platform: "linux".into(),
        os_version: "Ubuntu 24.04".into(),
        arch: "x86_64".into(),
        cmux_version: "0.1.0".into(),
    }
}

const ENV: &str = "test";

fn target(api: &FakeApi) -> ApiTarget {
    ApiTarget { base: api.base.clone(), environment: ENV.into(), allow_http: true }
}

fn layout(home: &tempfile::TempDir) -> Layout {
    layout_at(home.path(), host::platform())
}

fn pair(
    layout: &Layout,
    api: &ApiTarget,
    wait: bool,
    timeout: Option<Duration>,
) -> (cmux_server::Result<PairOutcome>, Vec<Started>) {
    let req = PairRequest { layout, api, info: info(), wait, timeout, now_ms: host::now_ms() };
    let mut shown = Vec::new();
    let out = run(&req, &mut |s: &Started| shown.push(s.clone()));
    (out, shown)
}

#[cfg(unix)]
fn mode(path: &std::path::Path) -> u32 {
    use std::os::unix::fs::PermissionsExt;
    std::fs::metadata(path).unwrap().permissions().mode() & 0o777
}

#[test]
fn thumbprint_matches_the_backend_vector() {
    assert_eq!(URL_SAFE_NO_PAD.encode(jwk_thumbprint(vector::X, vector::Y)), vector::THUMBPRINT);
    let id = InstallIdentity::from_parts(&unhex(vector::PKCS8_HEX), [7; 32]).unwrap();
    let jwk = id.public_jwk();
    assert_eq!(
        (jwk.kty, jwk.crv, jwk.x.as_str(), jwk.y.as_str()),
        ("EC", "P-256", vector::X, vector::Y)
    );
    assert_eq!(id.thumbprint_b64u(), vector::THUMBPRINT);
}

#[test]
fn begin_proof_matches_the_backend_message_and_signature_encoding() {
    let message =
        begin_proof_message("production", vector::THUMBPRINT, vector::WG, vector::ISSUED_AT);
    assert_eq!(
        message,
        format!(
            "cmux-pair-begin\nproduction\n{}\n{}\n{}",
            vector::THUMBPRINT,
            vector::WG,
            vector::ISSUED_AT
        )
    );
    // The backend's encoding (raw r||s, base64url) verifies with ring.
    let key = UnparsedPublicKey::new(&ECDSA_P256_SHA256_FIXED, point(vector::X, vector::Y));
    key.verify(message.as_bytes(), &URL_SAFE_NO_PAD.decode(vector::SIGNATURE).unwrap()).unwrap();
    // Ours is the same shape and verifies too.
    let id = InstallIdentity::from_parts(&unhex(vector::PKCS8_HEX), [7; 32]).unwrap();
    let sig = URL_SAFE_NO_PAD.decode(id.sign_b64u(message.as_bytes()).unwrap()).unwrap();
    assert_eq!(sig.len(), 64);
    key.verify(message.as_bytes(), &sig).unwrap();
    // The WireGuard key is standard base64 of 32 bytes (backend `WgPublicKey`).
    let wg = id.wg_public_key();
    assert_eq!(wg.len(), 44);
    assert!(wg.ends_with('=') && !wg.ends_with("=="));
}

#[test]
fn begin_then_wait_stores_the_result_with_private_modes() {
    let fake = FakeApi::start(ENV, Script::Paired);
    let home = tempfile::tempdir().unwrap();
    let layout = layout(&home);
    let api = target(&fake);
    let (out, shown) = pair(&layout, &api, true, Some(Duration::from_secs(20)));
    let PairOutcome::Paired(p) = out.unwrap() else { panic!("expected Paired") };
    assert_eq!((p.host.as_str(), p.team.as_str()), ("host_1", "team_1"));
    // The code was shown before the wait, with the key's words and QR.
    let dir = pairing_dir(&layout);
    let id = InstallIdentity::load_or_create(&dir).unwrap();
    let code = PairingCode::normalize(CODE).unwrap();
    assert_eq!(shown.len(), 1);
    assert_eq!(shown[0].code, "7KQ4-M2XD");
    assert_eq!(shown[0].words, fingerprint_words(&id.thumbprint()).map(str::to_owned));
    assert_eq!(shown[0].qr_payload, qr_payload(&code, &id.thumbprint()));
    // Begin carried the backend's body shape and a valid proof.
    let begins = fake.begins.lock().unwrap().clone();
    assert_eq!(begins.len(), 1);
    let body = &begins[0];
    assert_eq!(body["info"]["name"], "Studio");
    assert_eq!(body["info"]["arch"], "x86_64");
    assert_eq!(body["wg_public_key"].as_str().unwrap(), id.wg_public_key());
    assert!(pair_fake::proof_ok(body, ENV));
    assert!(!pair_fake::proof_ok(body, "production"), "the proof binds the environment");
    // Wait presented both subprotocols and the code.
    let waits = fake.waits.lock().unwrap().clone();
    assert_eq!(waits.len(), 1);
    assert_eq!(waits[0].uri, format!("/v1/pair/wait?code={CODE}"));
    let protocols: Vec<&str> = waits[0].protocols.split(',').map(str::trim).collect();
    assert_eq!(protocols, ["cmux.pair.v1", &format!("collect.{SECRET}")]);
    // Credentials hold the pushed result.
    let creds: serde_json::Value =
        serde_json::from_slice(&std::fs::read(dir.join(CREDENTIALS_FILE)).unwrap()).unwrap();
    for (k, v) in
        [("host", "host_1"), ("team", "team_1"), ("user", "user_1"), ("install", "inst_1")]
    {
        assert_eq!(creds[k], v, "{k}");
    }
    assert!(creds.get("t").is_none());
    assert!(!dir.join(PENDING_FILE).exists(), "a finished pairing leaves no pending code");
    #[cfg(unix)]
    {
        assert_eq!(mode(&dir), 0o700);
        for f in [INSTALL_KEY_FILE, WG_KEY_FILE, CREDENTIALS_FILE] {
            assert_eq!(mode(&dir.join(f)), 0o600, "{f}");
        }
    }
    // A paired server does not begin again.
    let (again, shown) = pair(&layout, &api, true, None);
    assert!(matches!(again.unwrap(), PairOutcome::AlreadyPaired(p) if p.host == "host_1"));
    assert!(shown.is_empty());
    assert_eq!(fake.begin_count(), 1);
}

#[test]
fn pair_without_wait_shows_the_code_and_a_second_run_reuses_it() {
    let fake = FakeApi::start(ENV, Script::Paired);
    let home = tempfile::tempdir().unwrap();
    let layout = layout(&home);
    let api = target(&fake);
    let (first, _) = pair(&layout, &api, false, None);
    let PairOutcome::Pending(first) = first.unwrap() else { panic!("expected Pending") };
    assert!(!first.resumed);
    let dir = pairing_dir(&layout);
    #[cfg(unix)]
    assert_eq!(mode(&dir.join(PENDING_FILE)), 0o600);
    let (second, _) = pair(&layout, &api, false, None);
    let PairOutcome::Pending(second) = second.unwrap() else { panic!("expected Pending") };
    assert!(second.resumed);
    assert_eq!((second.code.as_str(), &second.words), (first.code.as_str(), &first.words));
    assert_eq!(fake.begin_count(), 1, "the unexpired code is reused, the key is not remade");
    // `pair --wait` later collects the same code.
    let (done, _) = pair(&layout, &api, true, Some(Duration::from_secs(20)));
    assert!(matches!(done.unwrap(), PairOutcome::Paired(_)));
    assert_eq!(fake.begin_count(), 1);
}

#[test]
fn refusal_exits_4_and_spends_the_code() {
    for script in [Script::Refused, Script::CloseRefused] {
        let fake = FakeApi::start(ENV, script);
        let home = tempfile::tempdir().unwrap();
        let layout = layout(&home);
        let (out, shown) = pair(&layout, &target(&fake), true, Some(Duration::from_secs(20)));
        let err = out.unwrap_err();
        assert_eq!(err.kind, ExitKind::Rejected, "{script:?}: {err}");
        assert_eq!(err.kind.code(), 4);
        assert_eq!(shown.len(), 1);
        let dir = pairing_dir(&layout);
        assert!(!dir.join(PENDING_FILE).exists());
        assert!(!dir.join(CREDENTIALS_FILE).exists());
    }
}

#[test]
fn expiry_exits_5() {
    let fake = FakeApi::start(ENV, Script::Expired);
    let home = tempfile::tempdir().unwrap();
    let layout = layout(&home);
    let err = pair(&layout, &target(&fake), true, Some(Duration::from_secs(20))).0.unwrap_err();
    assert_eq!(err.kind, ExitKind::Unreachable, "{err}");
    assert!(!pairing_dir(&layout).join(PENDING_FILE).exists());
}

#[test]
fn timeout_exits_5_without_polling_and_keeps_the_code() {
    let fake = FakeApi::start(ENV, Script::Hold);
    let home = tempfile::tempdir().unwrap();
    let layout = layout(&home);
    let started = Instant::now();
    let err = pair(&layout, &target(&fake), true, Some(Duration::from_secs(1))).0.unwrap_err();
    assert_eq!(err.kind, ExitKind::Unreachable, "{err}");
    assert_eq!(err.kind.code(), 5);
    assert!(started.elapsed() < Duration::from_secs(10));
    // One socket for the whole wait (no reconnect loop).
    assert_eq!(fake.waits.lock().unwrap().len(), 1);
    assert!(pairing_dir(&layout).join(PENDING_FILE).exists(), "a timeout keeps the code");
}

#[cfg(unix)]
#[test]
fn a_key_file_readable_by_others_is_refused() {
    use std::os::unix::fs::PermissionsExt;
    let fake = FakeApi::start(ENV, Script::Paired);
    let home = tempfile::tempdir().unwrap();
    let layout = layout(&home);
    let api = target(&fake);
    pair(&layout, &api, false, None).0.unwrap();
    let key = pairing_dir(&layout).join(INSTALL_KEY_FILE);
    std::fs::set_permissions(&key, std::fs::Permissions::from_mode(0o644)).unwrap();
    let err = pair(&layout, &api, false, None).0.unwrap_err();
    assert_eq!(err.kind, ExitKind::Rejected, "{err}");
}

#[test]
fn a_proof_for_another_environment_is_refused_with_exit_7() {
    // The proof binds the Worker's ENVIRONMENT: a server that signs for
    // `test` against a `production` Worker gets 403, which is exit 7.
    let fake = FakeApi::start("production", Script::Paired);
    let home = tempfile::tempdir().unwrap();
    let err = pair(&layout(&home), &target(&fake), false, None).0.unwrap_err();
    assert_eq!(err.kind, ExitKind::Verification, "{err}");
    assert_eq!(*fake.refused_proofs.lock().unwrap(), 1);
}

#[test]
fn json_code_object_has_the_cli_shape() {
    let s = Started {
        code: "7KQ4-M2XD".into(),
        expires_at: 5,
        words: ["a", "b", "c", "d"].map(String::from),
        qr_payload: "https://cmux.com/pair?c=7KQ4M2XD#fp=0".into(),
        resumed: true,
    };
    let v = serde_json::to_value(&s).unwrap();
    let mut keys: Vec<&str> = v.as_object().unwrap().keys().map(String::as_str).collect();
    keys.sort_unstable();
    assert_eq!(keys, ["code", "expires_at", "qr_payload", "words"]);
}

#[test]
fn pair_verb_parses() {
    let a = parse(&["pair", "--wait", "--timeout", "30", "--json"].map(String::from)).unwrap();
    assert_eq!(a.verb, ["pair"]);
    assert!(a.has("wait") && a.json);
    assert_eq!(a.number("timeout").unwrap(), Some(30));
    assert_eq!(parse(&["pair", "--timeout"].map(String::from)).unwrap_err().kind, ExitKind::Usage);
    assert_eq!(parse(&["pair", "--wait=yes"].map(String::from)).unwrap_err().kind, ExitKind::Usage);
}

#[test]
fn api_target_urls() {
    let prod = ApiTarget::production();
    assert_eq!(prod.url("/v1/pair/begin").unwrap(), "https://cloud-api.cmux.dev/v1/pair/begin");
    assert_eq!(
        prod.ws_url("/v1/pair/wait?code=X").unwrap(),
        "wss://cloud-api.cmux.dev/v1/pair/wait?code=X"
    );
    let plain =
        ApiTarget { base: "http://127.0.0.1:9".into(), environment: ENV.into(), allow_http: false };
    assert_eq!(plain.url("/x").unwrap_err().kind, ExitKind::Rejected, "http needs allow_http");
    let bad = ApiTarget { base: "https://cmux.dev@evil.example".into(), ..ApiTarget::production() };
    assert_eq!(bad.url("/x").unwrap_err().kind, ExitKind::Rejected);
}
