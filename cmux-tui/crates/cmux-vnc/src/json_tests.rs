//! The `vnc_*` ops end to end, with the known answers of
//! Packages/Shared/CmuxVNC/Tests/CmuxVNCTests/RFBProtocolTests.swift.

use super::*;

fn ask(operation: &str, request: Value) -> Value {
    respond(operation, request.to_string().as_bytes())
        .unwrap_or_else(|e| panic!("{operation}: {e}"))
}

fn hex(text: &str) -> Vec<u8> {
    (0..text.len()).step_by(2).map(|i| u8::from_str_radix(&text[i..i + 2], 16).unwrap()).collect()
}

fn b64(bytes: &[u8]) -> String {
    STANDARD.encode(bytes)
}

#[test]
fn only_vnc_ops_are_handled() {
    assert!(handles("vnc_keysym"));
    assert!(!handles("screen_keysym"));
    assert_eq!(respond("vnc_nope", b"{}"), Err(JsonError::UnknownOperation("vnc_nope".into())));
    assert!(matches!(respond("vnc_keysym", b"not json"), Err(JsonError::Invalid(_))));
}

#[test]
fn addresses_carry_credentials_and_a_label() {
    assert_eq!(
        ask("vnc_address_parse", json!({ "text": "vnc://me:p%40ss@[::1]:5901" })),
        json!({ "host": "::1", "port": 5901, "username": "me", "password": "p@ss", "label": "[::1]:5901" })
    );
    assert_eq!(
        ask("vnc_address_parse", json!({ "text": "mac.local:2" })),
        json!({ "host": "mac.local", "port": 5902, "username": null, "password": null, "label": "mac.local:5902" })
    );
    assert_eq!(ask("vnc_address_parse", json!({ "text": "host:x" })), Value::Null);
}

#[test]
fn keysyms_take_exactly_one_input() {
    assert_eq!(ask("vnc_keysym", json!({ "character": "€" })), json!({ "keysym": 0x0100_20AC }));
    assert_eq!(ask("vnc_keysym", json!({ "hidUsage": 0x07_0004 })), json!({ "keysym": 0x61 }));
    assert_eq!(ask("vnc_keysym", json!({ "hidUsage": 0x01 })), json!({ "keysym": null }));
    assert_eq!(ask("vnc_keysym", json!({ "function": 12 })), json!({ "keysym": 0xFFBE + 11 }));
    for request in [json!({}), json!({ "character": "a", "function": 1 })] {
        assert!(matches!(
            respond("vnc_keysym", request.to_string().as_bytes()),
            Err(JsonError::Invalid(_))
        ));
    }
}

#[test]
fn security_choices_and_refusals() {
    let choose = |offered: &[u8], user: bool, pass: bool| {
        ask(
            "vnc_security_choose",
            json!({ "offered": offered, "hasUsername": user, "hasPassword": pass }),
        )
    };
    assert_eq!(choose(&[2, 30], true, true), json!({ "type": 30 }));
    assert_eq!(choose(&[2], true, true), json!({ "refusal": "passwordRequired" }));
    assert_eq!(choose(&[30], false, false), json!({ "refusal": "credentialsRequired" }));
    assert_eq!(
        choose(&[5, 6], false, false),
        json!({ "refusal": "noSupportedSecurityType", "offered": [5, 6] })
    );
    assert_eq!(ask("vnc_security_server_chosen", json!({ "word": 2 })), json!({ "type": 2 }));
    assert_eq!(
        ask("vnc_security_server_chosen", json!({ "word": 258 })),
        json!({ "refusal": "noSupportedSecurityType", "offered": [2] })
    );
}

#[test]
fn versions_answer_with_a_banner() {
    assert_eq!(
        ask("vnc_version", json!({ "banner": b64(b"RFB 003.889\n") })),
        json!({ "serverMinor": 889, "minor": 8, "reply": b64(b"RFB 003.008\n") })
    );
    assert_eq!(ask("vnc_version", json!({ "banner": b64(b"HTTP/1.1 400") })), Value::Null);
}

#[test]
fn password_responses_match_swift_known_answers() {
    let challenge: Vec<u8> = (0..16).collect();
    for (password, expected) in [
        ("", "491e890de9ace932838a49792f2213f3"),
        ("v", "136289336fd73274f0b2f69202229f46"),
        ("password", "b866924125c8eebb9debc1db61c538e2"),
        ("password123", "b866924125c8eebb9debc1db61c538e2"),
        ("a🌍12345", "0e674da292a0e84a3c34f90b9dad0f9c"),
    ] {
        assert_eq!(
            ask(
                "vnc_password_response",
                json!({ "password": password, "challenge": b64(&challenge) })
            ),
            json!({ "response": b64(&hex(expected)) }),
            "{password:?}"
        );
    }
    assert!(matches!(
        respond(
            "vnc_password_response",
            json!({ "password": "", "challenge": b64(&[1]) }).to_string().as_bytes()
        ),
        Err(JsonError::Invalid(_))
    ));
}

#[test]
fn apple_dh_matches_swift_known_answer() {
    let padding: Vec<u8> = (0..128).collect();
    let request = |private_key: Option<&[u8]>, padding: Option<&[u8]>| {
        let mut r = json!({
            "generator": 5, "prime": b64(&[23]), "serverPublicKey": b64(&[8]),
            "username": "bob", "password": "pw",
        });
        if let Some(k) = private_key {
            r["privateKey"] = json!(b64(k));
        }
        if let Some(p) = padding {
            r["padding"] = json!(b64(p));
        }
        r
    };
    let expected = hex(concat!(
        "bc22f01689cef4ad73569b9f5640440293e7a58bbe8574e58747d333418a74a5",
        "00e6cbcdfb86078ff9ff67b5704c80893de99f7e8759b80386835a0a70765ced",
        "ec92af137626c99b58af257891c1495b4453bd9c231f0f3abb3978118c933432",
        "35b95f663073a68504b7cf88713f659aa7ad77245a8274055f4db7c627ebf3a0",
    ));
    assert_eq!(
        ask("vnc_apple_dh", request(Some(&[6]), Some(&padding))),
        json!({ "encryptedCredentials": b64(&expected), "clientPublicKey": b64(&[8]) })
    );
    // A session's own key and padding are random but the shape holds.
    let random = ask("vnc_apple_dh", request(None, None));
    assert_eq!(
        STANDARD.decode(random["encryptedCredentials"].as_str().unwrap()).unwrap().len(),
        128
    );
    assert_eq!(STANDARD.decode(random["clientPublicKey"].as_str().unwrap()).unwrap().len(), 1);
    // A server key of the wrong length is no answer.
    let mut bad = request(Some(&[6]), Some(&padding));
    bad["serverPublicKey"] = json!(b64(&[0, 8]));
    assert_eq!(ask("vnc_apple_dh", bad), Value::Null);
}

#[test]
fn the_demo_server_round_trips_its_connection() {
    let config = json!({"width": 64, "height": 2, "name": "d"});
    let challenge = STANDARD.encode([0u8; 16]);
    let first = ask(
        "vnc_demo_receive",
        json!({"input": STANDARD.encode(b"RFB 003.008\n\x01\x01"), "config": config, "challenge": challenge}),
    );
    assert_eq!(first["consumed"], 14);
    assert_eq!(first["failure"], Value::Null);
    assert_eq!(first["connection"]["phase"], "normal");
    let mut input = vec![2u8, 0, 0, 2];
    input.extend(16i32.to_be_bytes());
    input.extend((-239i32).to_be_bytes());
    input.extend([3, 0, 0, 0, 0, 0, 0, 64, 0, 2, 4, 1, 0, 0, 0, 0, 0, 0x61]);
    let second = ask(
        "vnc_demo_receive",
        json!({"connection": first["connection"], "input": STANDARD.encode(&input), "config": config, "challenge": challenge}),
    );
    assert_eq!(second["flush"], true);
    assert_eq!(
        second["events"],
        json!([{"type": "fullUpdate"}, {"type": "key", "keysym": 0x61, "down": true, "shift": false}])
    );
    let flushed = ask(
        "vnc_demo_flush",
        json!({"connection": second["connection"], "damagePending": true, "damageCount": 1}),
    );
    assert_eq!(flushed["send"], true);
    let head = STANDARD.decode(flushed["head"].as_str().unwrap()).unwrap();
    assert_eq!(&head[..4], [0, 0, 0, 2], "the cursor and one rectangle");
    assert_eq!(flushed["connection"]["cursorSent"], true);
    let pixels: Vec<u8> = [0x30u8, 0x20, 0x10, 0].repeat(128);
    let rect = ask(
        "vnc_demo_rect",
        json!({"connection": flushed["connection"], "x": 0, "y": 0, "width": 64, "height": 2, "pixels": STANDARD.encode(&pixels)}),
    );
    assert_eq!(rect["zrle"], true);
    assert_eq!(STANDARD.decode(rect["payload"].as_str().unwrap()).unwrap(), [1, 0x30, 0x20, 0x10]);
    let bad = ask(
        "vnc_demo_receive",
        json!({"connection": first["connection"], "input": STANDARD.encode([9u8]), "config": config, "challenge": challenge}),
    );
    let failure = STANDARD.decode(bad["failure"].as_str().unwrap()).unwrap();
    assert_eq!(&failure[..4], [0, 0, 0, 1]);
}
