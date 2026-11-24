use super::*;

fn admission(n: u8) -> GrantAdmission {
    GrantAdmission {
        device_id: grant_device_id("user", &[n; 32]),
        authority: ServiceAuthority::from_services([Service::MuxControl]),
    }
}

const S: SessionId = SessionId([9; 16]);

/// #37211 review F3: a key re-admitted or resumed while in use kept its
/// old place and was forgotten first, so its grant-free resume failed.
#[test]
fn a_key_in_use_is_the_newest_and_is_forgotten_last() {
    let admitted = AdmittedGrants::with_capacity(2);
    admitted.remember([1; 32], S, admission(1));
    admitted.remember([2; 32], S, admission(2));
    // Key 1 re-admits: key 2 is now the oldest.
    admitted.remember([1; 32], S, admission(1));
    admitted.remember([3; 32], S, admission(3));
    assert_eq!(admitted.get(&[2; 32], S), None);
    assert_eq!(admitted.get(&[1; 32], S), Some(admission(1)));
    // A resume of key 3 makes key 1 the oldest.
    assert_eq!(admitted.get(&[3; 32], S), Some(admission(3)));
    admitted.remember([4; 32], S, admission(4));
    assert_eq!(admitted.get(&[1; 32], S), None);
    assert_eq!(admitted.get(&[3; 32], S), Some(admission(3)));
    assert_eq!(admitted.get(&[4; 32], S), Some(admission(4)));
    let guard = admitted.inner.lock().unwrap();
    assert_eq!(guard.order.len(), guard.by_key.len());
}

/// #38420 review F1: a second session of one Noise key with a fresh
/// grant replaced the first session's admission, so the first one's
/// resume came back with another grant and was refused as a changed
/// authority. Each session resumes with its own.
#[test]
fn each_session_of_one_key_resumes_with_its_own_grant() {
    let admitted = AdmittedGrants::default();
    let (a, b) = (SessionId([1; 16]), SessionId([2; 16]));
    admitted.remember([1; 32], a, admission(1));
    admitted.remember([1; 32], b, admission(2));
    assert_eq!(admitted.get(&[1; 32], a), Some(admission(1)));
    assert_eq!(admitted.get(&[1; 32], b), Some(admission(2)));
    assert_eq!(admitted.get(&[1; 32], SessionId([3; 16])), None);
}

mod file_verifier {
    use base64::Engine as _;
    use base64::engine::general_purpose::URL_SAFE_NO_PAD;
    use ring::signature::{Ed25519KeyPair, KeyPair as _};
    use serde_json::json;

    use super::*;

    const MACHINE: &str = "vm_00000000000000000001";
    const TEAM: &str = "team_00000000000000000001";
    const ISSUER: &str = "cmux:cloud:development";

    /// A generated signing key; no key material is checked in.
    fn signer() -> Ed25519KeyPair {
        let rng = ring::rand::SystemRandom::new();
        let pkcs8 = Ed25519KeyPair::generate_pkcs8(&rng).unwrap();
        Ed25519KeyPair::from_pkcs8(pkcs8.as_ref()).unwrap()
    }

    fn config(kid: &str, key: &Ed25519KeyPair, machine: &str) -> String {
        json!({
            "issuer": ISSUER,
            "machine": machine,
            "team": TEAM,
            "keyset": {
                "version": "0123456789abcdef",
                "keys": {kid: {
                    "kty": "OKP", "crv": "Ed25519", "alg": "EdDSA", "kid": kid,
                    "x": URL_SAFE_NO_PAD.encode(key.public_key().as_ref()),
                }},
            },
        })
        .to_string()
    }

    fn grant(kid: &str, key: &Ed25519KeyPair, noise_key: &[u8; 32], jti: u8) -> String {
        grant_for(kid, key, noise_key, jti, &["mux-control"])
    }

    fn grant_for(
        kid: &str,
        key: &Ed25519KeyPair,
        noise_key: &[u8; 32],
        jti: u8,
        svc: &[&str],
    ) -> String {
        let now =
            std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_secs();
        let header =
            json!({"alg": "EdDSA", "kid": kid, "typ": cmux_link::carrier_grant::GRANT_TYP});
        let claims = json!({
            "iss": ISSUER, "aud": MACHINE, "team": TEAM, "sub": "user_1",
            "svc": svc,
            "nk": cmux_link::carrier_grant::noise_key_digest(noise_key),
            "jti": URL_SAFE_NO_PAD.encode([jti; 16]),
            "iat": now - 5, "exp": now + 60,
        });
        let message = format!(
            "{}.{}",
            URL_SAFE_NO_PAD.encode(header.to_string()),
            URL_SAFE_NO_PAD.encode(claims.to_string())
        );
        let signature = key.sign(message.as_bytes());
        format!("{message}.{}", URL_SAFE_NO_PAD.encode(signature.as_ref()))
    }

    /// Writes `file` the way the host does: a temp file, then a rename.
    fn put(file: &Path, text: &str) {
        let tmp = file.with_extension("tmp");
        std::fs::write(&tmp, text).unwrap();
        std::fs::rename(&tmp, file).unwrap();
    }

    fn present<'a>(token: &'a str, noise_key: &'a [u8; 32]) -> GrantPresentation<'a> {
        GrantPresentation { token, noise_key, link_group: [1; 32] }
    }

    /// A grant signed by a kid neither the keyset nor the file holds is
    /// reported to the host once per interval, with its kid.
    #[test]
    fn an_unknown_kid_is_reported_once_per_interval() {
        let dir = tempfile::tempdir().unwrap();
        let file = dir.path().join("carrier-grant.json");
        let (held, other) = (signer(), signer());
        put(&file, &config("k1", &held, MACHINE));
        let seen = std::sync::Arc::new(Mutex::new(Vec::<String>::new()));
        let sink = std::sync::Arc::clone(&seen);
        let verifier = FileGrantVerifier::load(&file)
            .unwrap()
            .with_unknown_kid_hook(Box::new(move |kid| sink.lock().unwrap().push(kid.to_owned())));
        let noise_key = [5_u8; 32];
        for jti in [10, 11] {
            let token = grant("k9", &other, &noise_key, jti);
            assert!(verifier.verify(present(&token, &noise_key)).is_err());
        }
        let known = grant("k1", &held, &noise_key, 12);
        assert!(verifier.verify(present(&known, &noise_key)).is_ok());
        assert_eq!(*seen.lock().unwrap(), ["k9"]);
    }

    /// A grant refused only for naming unknown services keeps its jti:
    /// the same jti in a grant this daemon serves is still admitted.
    #[test]
    fn a_grant_of_unknown_services_spends_no_jti() {
        let dir = tempfile::tempdir().unwrap();
        let file = dir.path().join("carrier-grant.json");
        let key = signer();
        put(&file, &config("k1", &key, MACHINE));
        let verifier = FileGrantVerifier::load(&file).unwrap();
        let noise_key = [4_u8; 32];
        let unknown = grant_for("k1", &key, &noise_key, 7, &["not-a-service"]);
        let refused = verifier.verify(present(&unknown, &noise_key)).unwrap_err();
        assert_eq!(refused, "carrier grant refused: no service this daemon serves");
        let known = grant_for("k1", &key, &noise_key, 7, &["mux-control"]);
        let admitted = verifier.verify(GrantPresentation {
            token: &known,
            noise_key: &noise_key,
            link_group: [2; 32],
        });
        assert!(admitted.is_ok(), "{admitted:?}");
    }

    /// Only a grant whose `svc` names `acpmux` holds the acpmux
    /// service, and the session's authority keeps the grant it was
    /// admitted with (the acpmux bridge's only source of the person).
    #[test]
    fn acpmux_comes_only_from_svc_and_the_authority_keeps_the_grant() {
        let dir = tempfile::tempdir().unwrap();
        let file = dir.path().join("carrier-grant.json");
        let key = signer();
        put(&file, &config("k1", &key, MACHINE));
        let verifier = FileGrantVerifier::load(&file).unwrap();
        let noise_key = [6_u8; 32];
        let without = grant_for("k1", &key, &noise_key, 20, &["mux-control"]);
        let admitted = verifier.verify(present(&without, &noise_key)).unwrap();
        assert!(!admitted.authority.allows(Service::Acpmux));
        let with = grant_for("k1", &key, &noise_key, 21, &["acpmux"]);
        let admitted = verifier.verify(present(&with, &noise_key)).unwrap();
        assert!(admitted.authority.allows(Service::Acpmux));
        let grant = admitted.authority.grant().expect("the admitting grant");
        assert_eq!((grant.subject.as_str(), grant.team.as_str()), ("user_1", TEAM));
        assert_eq!(grant.services, ["acpmux"]);
    }

    #[test]
    fn the_config_has_exactly_its_four_fields() {
        let key = signer();
        let parsed = GrantConfig::parse(&config("k1", &key, MACHINE)).unwrap();
        assert_eq!((parsed.issuer.as_str(), parsed.machine.as_str()), (ISSUER, MACHINE));
        assert_eq!(parsed.keys.kids(), ["k1"]);
        let mut extra: Value = serde_json::from_str(&config("k1", &key, MACHINE)).unwrap();
        extra["slot"] = json!("x");
        for bad in ["", "[]", "{}", &extra.to_string()] {
            assert!(GrantConfig::parse(bad).is_err(), "{bad}");
        }
    }

    /// A rotated keyset reaches the daemon through its config file: an
    /// unknown kid re-reads it once, and only a file for the same
    /// machine, team and issuer is taken.
    #[test]
    fn an_unknown_kid_reloads_the_keyset_from_the_file() {
        let dir = tempfile::tempdir().unwrap();
        let file = dir.path().join("carrier-grant.json");
        let (old, new) = (signer(), signer());
        put(&file, &config("k1", &old, MACHINE));
        let verifier = FileGrantVerifier::load(&file).unwrap();
        let noise_key = [3_u8; 32];
        verifier.verify(present(&grant("k1", &old, &noise_key, 1), &noise_key)).unwrap();

        // A file for another machine is never taken.
        put(&file, &config("k2", &new, "vm_00000000000000000002"));
        let rotated = grant("k2", &new, &noise_key, 2);
        assert!(verifier.verify(present(&rotated, &noise_key)).is_err());

        // The same machine's rotation is taken at its next grant.
        put(&file, &config("k2", &new, MACHINE));
        let admission = verifier.verify(present(&rotated, &noise_key)).unwrap();
        assert!(is_grant_device_id(&admission.device_id));
    }

    /// #37361 review F2: a grant refused before the rotated config is
    /// written starts no throttle; the grant right after the write is
    /// admitted.
    #[test]
    fn a_rotation_written_after_a_refusal_is_read_at_the_next_grant() {
        let dir = tempfile::tempdir().unwrap();
        let file = dir.path().join("carrier-grant.json");
        let (old, new) = (signer(), signer());
        put(&file, &config("k1", &old, MACHINE));
        let verifier = FileGrantVerifier::load(&file).unwrap();
        let noise_key = [6_u8; 32];
        let early = grant("k2", &new, &noise_key, 20);
        assert!(verifier.verify(present(&early, &noise_key)).is_err());
        put(&file, &config("k2", &new, MACHINE));
        let next = grant("k2", &new, &noise_key, 21);
        assert!(verifier.verify(present(&next, &noise_key)).is_ok());
    }
}
