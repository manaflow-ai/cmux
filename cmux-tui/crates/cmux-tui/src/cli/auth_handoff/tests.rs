use serde_json::json;

use super::*;

const CODE: &str = "cmh_team_0123456789abcdefabcd.ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijk_-0123";

fn args(words: &[&str]) -> Vec<String> {
    words.iter().map(|word| (*word).to_owned()).collect()
}

#[test]
fn the_code_shape_is_exact() {
    assert_eq!(CODE.split_once('.').map(|(_, s)| s.len()), Some(43));
    assert!(is_code(CODE));
    assert!(!is_code(""));
    assert!(!is_code("cmh_team_0123456789abcdefabcd"));
    assert!(!is_code(&CODE.replace("cmh_", "cmj_")));
    assert!(!is_code(&format!("{CODE}x")));
    assert!(!is_code(&CODE.replace("team_0", "team_A")));
    assert!(!is_code(&CODE.replace("ABC", "A C")));
}

#[test]
fn verbs_and_the_device_flag_parse() {
    assert_eq!(parse(&args(&[])).unwrap(), Invocation::Help);
    assert_eq!(parse(&args(&["help"])).unwrap(), Invocation::Help);
    assert_eq!(parse(&args(&["redeem", "--help"])).unwrap(), Invocation::Help);
    assert_eq!(parse(&args(&["mint"])).unwrap(), Invocation::Mint { device: None });
    assert_eq!(
        parse(&args(&["mint", "--device", "air-blue"])).unwrap(),
        Invocation::Mint { device: Some("air-blue".to_owned()) }
    );
    assert_eq!(
        parse(&args(&["redeem", "--device=cosmic gray "])).unwrap(),
        Invocation::Redeem { device: Some("cosmic gray".to_owned()) }
    );
    assert_eq!(
        parse(&args(&["redeem", "--device="])).unwrap(),
        Invocation::Redeem { device: None }
    );
    assert!(parse(&args(&["mint", "--device"])).is_err());
    assert!(parse(&args(&["mint", &format!("--device={}", "x".repeat(65))])).is_err());
    assert!(parse(&args(&["mint", "--device=a\u{7}b"])).is_err());
    assert!(parse(&args(&["approve"])).unwrap_err().0.contains("approve"));
    assert!(parse(&args(&["mint", "extra"])).unwrap_err().0.contains("extra"));
}

/// The code is never taken from argv (visible in `ps`), and a refusal never echoes it.
#[test]
fn a_code_in_argv_is_refused_without_echoing_it() {
    for words in [
        vec!["redeem", CODE],
        vec!["redeem", "--code", CODE],
        vec!["redeem", &format!("--code={CODE}")],
        vec!["mint", CODE],
        vec![CODE],
        // A code given as the device name is still a code in argv, never sent as a label.
        vec!["redeem", "--device", CODE],
        vec!["mint", &format!("--device={CODE}")],
        vec!["redeem", "--device", " cmh_team_x "],
    ] {
        let Usage(message) = parse(&args(&words)).unwrap_err();
        assert!(!message.contains(CODE), "{words:?}: {message}");
        assert!(!message.contains("ABCDEFGHIJ"), "{words:?}: {message}");
    }
}

#[test]
fn stdin_takes_exactly_one_code_line() {
    assert_eq!(read_code(format!("{CODE}\n").as_bytes()).unwrap().as_str(), CODE);
    assert_eq!(read_code(format!("  {CODE}  \r\n\n").as_bytes()).unwrap().as_str(), CODE);
    assert_eq!(read_code(CODE.as_bytes()).unwrap().as_str(), CODE);
    assert!(read_code(&b""[..]).is_err());
    assert!(read_code(&b"\n\n"[..]).is_err());
    assert!(read_code(format!("{CODE}\n{CODE}\n").as_bytes()).is_err());
    assert!(read_code(&b"not a code\n"[..]).is_err());
    assert!(read_code(&[0xff, 0xfe][..]).is_err());
    // A flood is refused without reading it all.
    let long = format!("{CODE}{}", " ".repeat(5000));
    assert!(read_code(long.as_bytes()).is_err());
}

#[test]
fn a_bad_stdin_refusal_never_echoes_what_was_read() {
    let secretish = "cmh_team_0123456789abcdefabcd.tooShortButStillSecret";
    let Usage(message) = read_code(secretish.as_bytes()).unwrap_err();
    assert!(!message.contains("tooShort"), "{message}");
    let two = format!("{CODE}\n{CODE}\n");
    let Usage(message) = read_code(two.as_bytes()).unwrap_err();
    assert!(!message.contains(CODE), "{message}");
}

#[test]
fn the_app_requests_carry_the_code_only_on_redeem() {
    assert_eq!(mint_params(None), json!({}));
    assert_eq!(mint_params(Some("air-blue")), json!({ "device": "air-blue" }));
    assert_eq!(redeem_params(CODE, None), json!({ "code": CODE }));
    assert_eq!(redeem_params(CODE, Some("cmux16")), json!({ "code": CODE, "device": "cmux16" }));
}

#[test]
fn outputs_follow_the_contract() {
    let minted = json!({
        "code": CODE, "expires_at": 1_763_100_000_000_i64, "user": "user_1", "email": "a@b.c", "device": "air-blue",
    });
    assert_eq!(
        mint_output(&minted).unwrap(),
        json!({ "code": CODE, "expiresAt": 1_763_100_000_000_i64, "user": "user_1", "email": "a@b.c", "device": "air-blue" })
    );
    assert_eq!(mint_output(&json!({ "code": "x", "expires_at": 1 })), None);
    assert_eq!(mint_output(&json!({ "code": CODE })), None);
    let redeemed = json!({
        "signed_in": true, "already_signed_in": false, "user": "user_1", "email": "a@b.c", "device": "cosmic-gray",
    });
    assert_eq!(
        redeem_output(&redeemed).unwrap(),
        json!({ "signedIn": true, "alreadySignedIn": false, "user": { "id": "user_1", "email": "a@b.c" }, "device": { "name": "cosmic-gray" } })
    );
    assert_eq!(redeem_output(&json!({ "signed_in": false })), None);
    // A redeem answer never prints a token, even if an app sent one.
    let leaky =
        json!({ "signed_in": true, "user": "u", "refresh_token": "rt", "access_token": "at" });
    let printed = redeem_output(&leaky).unwrap().to_string();
    assert!(!printed.contains("rt\"") && !printed.contains("\"at\""), "{printed}");
}

#[test]
fn refusals_exit_with_the_contract_codes() {
    assert_eq!(exit_code(&json!({ "code": "invalid_params" })), 2);
    assert_eq!(exit_code(&json!({ "code": "handoff_invalid" })), 3);
    assert_eq!(exit_code(&json!({ "code": "not_signed_in" })), 3);
    assert_eq!(exit_code(&json!({ "code": "sso_required" })), 3);
    assert_eq!(exit_code(&json!({ "code": "rate_limited" })), 3);
    assert_eq!(exit_code(&json!({ "code": "other_user" })), 5);
    assert_eq!(exit_code(&json!({ "code": "unavailable" })), 4);
    assert_eq!(exit_code(&json!({ "code": "method_not_found" })), 4);
}

/// credential_env_tests rules: this command reads no environment variable at all, so a code can
/// never come from (or be left in) the environment, and it adds no credential env name.
#[test]
fn the_command_reads_no_environment() {
    let source = include_str!("../auth_handoff.rs");
    for needle in ["env::var", "env::vars", "var_os", "getenv", "env!(", "set_var"] {
        assert!(
            !source.contains(needle),
            "auth_handoff.rs must not touch the environment ({needle})"
        );
    }
}

#[test]
fn usage_is_localized_and_names_stdin() {
    for locale in ["en_US.UTF-8", "ja_JP.UTF-8"] {
        let messages = &crate::localization::catalog_for_locale(locale).auth_handoff;
        assert!(messages.usage.contains("cmux auth handoff mint"), "{locale}");
        assert!(messages.usage.contains("| ssh air-blue cmux auth handoff redeem"), "{locale}");
        assert!(messages.usage.ends_with('\n'), "{locale}");
        assert!(messages.unknown_verb.contains("{verb}"), "{locale}");
        assert!(messages.signed_in.contains("{user}"), "{locale}");
    }
}

#[test]
fn known_refusals_get_the_clis_own_words_and_keep_their_code() {
    let error = json!({ "code": "other_user", "message": "app words" });
    let shown = localized_error(&error);
    assert_eq!(shown["code"], "other_user");
    assert_ne!(shown["message"], "app words");
    assert!(shown["message"].as_str().unwrap().starts_with("cmux: "));
    let unknown = json!({ "code": "feature.disabled", "message": "Cloud is off" });
    assert_eq!(localized_error(&unknown), unknown);
}

#[test]
fn a_mint_cmux_api_could_not_reach_is_asked_again() {
    let patience = || {
        Patience::new("a test", Duration::from_secs(5))
            .quiet()
            .spaced(Duration::from_millis(1), Duration::from_millis(2))
    };
    let mut asks = 0;
    let answer = retry_unavailable(patience(), || {
        asks += 1;
        Ok(if asks < 3 {
            Ok(Err(json!({"code": "unavailable"})))
        } else {
            Ok(Ok(json!({"ok": 1})))
        })
    });
    assert_eq!(answer, Ok(Ok(Ok(json!({"ok": 1})))));
    assert_eq!(asks, 3);

    let mut asks = 0;
    let answer = retry_unavailable(patience(), || {
        asks += 1;
        Ok(Ok(Err(json!({"code": "handoff_invalid"}))))
    });
    assert_eq!(answer, Ok(Ok(Err(json!({"code": "handoff_invalid"})))));
    assert_eq!(asks, 1);

    let answer = retry_unavailable(Patience::new("a test", Duration::ZERO).quiet(), || {
        Ok(Ok(Err(json!({"code": "unavailable"}))))
    });
    assert_eq!(answer, Ok(Ok(Err(json!({"code": "unavailable"})))));
}
