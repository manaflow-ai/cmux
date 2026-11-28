//! Parity with Packages/Shared/CmuxVNC/Tests/CmuxVNCTests/RFBProtocolTests.swift
//! (VNCEndpointTests, VNCKeysymTests, securityChoice and the 3.3 cases).

use super::*;

fn host_port(raw: &str) -> (String, u16) {
    let address = parse_address(raw).unwrap_or_else(|| panic!("{raw} parses"));
    (address.host, address.port)
}

#[test]
fn addresses_parse_as_swift_did() {
    for (raw, host, port) in [
        ("host", "host", 5900),
        ("host:1", "host", 5901),
        ("host:5905", "host", 5905),
        ("host::42", "host", 42),
        ("[::1]:5901", "::1", 5901),
        ("vnc://me:pw@mac.local:5900", "mac.local", 5900),
        ("VNC://box:2/path?x", "box", 5902),
        ("  [fe80::1]  ", "fe80::1", 5900),
        ("host:0", "host", 5900),
    ] {
        assert_eq!(host_port(raw), (host.to_owned(), port), "{raw}");
    }
}

#[test]
fn credentials_come_from_the_url_decoded() {
    let address = parse_address("vnc://me:p%40ss@mac.local").unwrap();
    assert_eq!(address.username.as_deref(), Some("me"));
    assert_eq!(address.password.as_deref(), Some("p@ss"));
    let user_only = parse_address("me@mac.local").unwrap();
    assert_eq!((user_only.username.as_deref(), user_only.password), (Some("me"), None));
    // An empty or undecodable part is no credential at all.
    let empty = parse_address(":@mac.local").unwrap();
    assert_eq!((empty.username, empty.password), (None, None));
    assert_eq!(parse_address("me:%zz@mac.local").unwrap().password, None);
    assert_eq!(parse_address("me:%@mac.local").unwrap().password, None);
}

#[test]
fn rejects_what_swift_rejected() {
    for raw in
        ["", "  ", "host:notaport", "host:70000", "::5", "[]:1", "[::1]:x", ":5", "me@", "vnc://"]
    {
        assert_eq!(parse_address(raw), None, "{raw:?}");
    }
    // Multi-byte text where the scheme would be never splits a character.
    assert_eq!(host_port("abcd€x"), ("abcd€x".into(), 5900));
}

#[test]
fn labels_bracket_v6() {
    assert_eq!(label("::1", 5901), "[::1]:5901");
    assert_eq!(label("mac.local", 5900), "mac.local:5900");
}

#[test]
fn hid_letters_digits_and_specials() {
    assert_eq!(hid_keysym(0x07_0004), Some(0x61));
    assert_eq!(hid_keysym(0x1E), Some(0x31));
    assert_eq!(hid_keysym(0x27), Some(0x30));
    assert_eq!(hid_keysym(0x28), Some(0xFF0D));
    assert_eq!(hid_keysym(0x3A), Some(function_keysym(1)));
    assert_eq!(hid_keysym(0x45), Some(function_keysym(12)));
    assert_eq!(hid_keysym(0x68), Some(function_keysym(13)));
    assert_eq!(hid_keysym(0xE3), Some(0xFFEB));
    assert_eq!(hid_keysym(0xE2), Some(0xFFE9));
    assert_eq!(hid_keysym(0x59), Some(0xFFB1));
    assert_eq!(hid_keysym(0x0C_00E9), None);
    assert_eq!(hid_keysym(0x01), None);
}

#[test]
fn characters_and_function_keys() {
    assert_eq!(character_keysym("a"), 0x61);
    assert_eq!(character_keysym("é"), 0xE9);
    assert_eq!(character_keysym("€"), 0x0100_20AC);
    assert_eq!(character_keysym("\n"), 0xFF0D);
    assert_eq!(character_keysym("\r\n"), 0xFF0D);
    assert_eq!(character_keysym("\t"), 0xFF09);
    assert_eq!(character_keysym(""), 0x3F);
    assert_eq!(function_keysym(0), 0xFFBE);
    assert_eq!(function_keysym(24), 0xFFBE + 23);
    assert_eq!(function_keysym(99), 0xFFBE + 23);
}

#[test]
fn security_choice() {
    assert_eq!(choose_security(&[2, 30], true, true), Ok(30));
    assert_eq!(choose_security(&[2, 30], false, true), Ok(2));
    assert_eq!(choose_security(&[30], false, false), Err(Refusal::CredentialsRequired));
    assert_eq!(choose_security(&[2], false, false), Err(Refusal::PasswordRequired));
    assert_eq!(choose_security(&[2, 1], false, false), Ok(1));
    assert_eq!(choose_security(&[5], false, false), Err(Refusal::NoSupportedSecurityType(vec![5])));
}

#[test]
fn an_account_password_never_goes_out_as_a_vnc_password() {
    assert_eq!(choose_security(&[2], true, true), Err(Refusal::PasswordRequired));
    assert_eq!(choose_security(&[2, 30], true, true), Ok(30));
}

#[test]
fn protocol_33_compares_the_whole_word() {
    assert_eq!(server_chosen_security(1, false), Ok(1));
    assert_eq!(server_chosen_security(2, false), Ok(2));
    assert_eq!(server_chosen_security(2, true), Err(Refusal::CredentialsRequired));
    assert_eq!(server_chosen_security(258, false), Err(Refusal::NoSupportedSecurityType(vec![2])));
}

#[test]
fn versions() {
    assert_eq!(server_minor(b"RFB 003.008\n"), Some(8));
    assert_eq!(server_minor(b"RFB 003.889\n"), Some(889));
    assert_eq!(server_minor(b"RFB 003.003\n"), Some(3));
    assert_eq!(server_minor(b"RFB 004.000\n"), None);
    assert_eq!(server_minor(b"HTTP/1.1 400"), None);
    assert_eq!(client_minor(889), 8);
    assert_eq!(client_minor(7), 7);
    assert_eq!(client_minor(5), 3);
}
