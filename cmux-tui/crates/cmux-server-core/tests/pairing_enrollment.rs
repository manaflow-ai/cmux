use cmux_server_core::pairing::enrollment::*;
use serde_json::{Value, json};

const NOW: u64 = 1_790_978_474_000;
const THUMB: &str = "cn-I_WNMClehiVp51i_0VpOENW1upEerA8sEam5hn-s";
const SECRET: &str =
    "AAAAAAAAAAAAAAAAAAAAAA.aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";

fn jwk() -> Value {
    json!({"kty":"EC","crv":"P-256",
        "x":"MKBCTNIcKUSDii11ySs3526iDZ8AiTo7Tu6KPAqv7D4",
        "y":"4Etl6SRW2YiLUrN5vfvVHuhp7x8PxltmWWlbbM4IFyM","kid":"ignored"})
}

fn reply() -> Value {
    json!({"code":"7KQ4M2XD","expires_at":NOW+600_000,"thumbprint":THUMB,"collect_secret":SECRET})
}

#[test]
fn server_pairing_shared_thumbprint_matches_the_rfc_vector_and_approval_words() {
    assert_eq!(jwk_thumbprint(&jwk()).unwrap(), THUMB);
    assert_eq!(
        fingerprint_words("11qYAYKxCrfVS_7TyWQHOg7hcvPapiMlrwIaaPcHURo").unwrap(),
        ["capable", "various", "jewel", "dress"]
    );
    for changed in [json!({"kty":"EC","crv":"P-256","x":"x","y":"y"}), json!({"kty":"RSA"})] {
        assert!(jwk_thumbprint(&changed).is_err());
    }
}

#[test]
fn server_pairing_shared_request_signs_the_api_environment_and_wireguard_key() {
    let info = json!({"name":"Server","platform":"macos","os_version":"26","arch":"aarch64","cmux_version":"1.0.0"});
    let result=begin_request(&jwk(),"AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=",info.clone(),"staging",NOW,|bytes| {
        assert_eq!(std::str::from_utf8(bytes).unwrap(),format!("cmux-pair-begin\nstaging\n{THUMB}\nAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=\n{NOW}"));
        Ok("fixture-signature".into())
    }).unwrap();
    assert_eq!(result["info"], info);
    assert_eq!(result["signature"], "fixture-signature");
    let mut invalid = info;
    invalid["name"] = json!("a".repeat(81));
    assert!(
        begin_request(
            &jwk(),
            "AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA=",
            invalid,
            "staging",
            NOW,
            |_| panic!("signed invalid metadata")
        )
        .is_err()
    );
}

#[test]
fn server_pairing_begin_validates_the_collect_secret_thumbprint_and_bounded_lifetime() {
    let begun = Begun::parse(&reply(), THUMB, NOW).unwrap();
    assert_eq!(begun.code.display(), "7KQ4-M2XD");
    assert_eq!(begun.collect_secret(), SECRET);
    assert!(!format!("{begun:?}{}", begun.public_progress()).contains(SECRET));
    for (field, value) in [
        ("code", json!("wrong")),
        ("thumbprint", json!("wrong")),
        ("collect_secret", json!("secret, injected.protocol")),
        ("expires_at", json!(NOW)),
        ("expires_at", json!(NOW + MAX_WAIT_MS + MAX_CLOCK_SKEW_MS + 1)),
    ] {
        let mut response = reply();
        response[field] = value;
        assert!(Begun::parse(&response, THUMB, NOW).is_err(), "accepted invalid {field}");
    }
    let mut skew = reply();
    skew["expires_at"] = json!(NOW + MAX_WAIT_MS + MAX_CLOCK_SKEW_MS);
    assert!(
        Begun::parse(&skew, THUMB, NOW).is_ok(),
        "backend clock skew is permitted, waits remain bounded"
    );
}

#[test]
fn server_pairing_pending_and_refusal_are_never_successful_enrollment() {
    assert_eq!(
        read_frame(&json!({"t":"pending","expires_at":NOW+1000}).to_string()).unwrap(),
        None
    );
    assert_eq!(read_frame(r#"{"t":"refused"}"#).unwrap(), Some(Waited::Refused));
    for text in [
        r#"{"t":"paired","install":"inst_00000000000000000001"}"#,
        r#"{"t":"paired","install":"inst_00000000000000000001","host":"../../wrong","user":"u","team":"t"}"#,
        r#"{"t":"unexpected"}"#,
    ] {
        assert!(read_frame(text).is_err());
    }
    assert!(read_frame(&"x".repeat(MAX_FRAME_BYTES + 1)).is_err());
    assert!(matches!(
        read_frame(
            r#"{"t":"paired","install":"inst_00000000000000000001","host":"host_00000000000000000001","user":"user_00000000000000000001","team":"team_00000000000000000001"}"#
        )
        .unwrap(),
        Some(Waited::Paired(_))
    ));
}
