//! The console, dialog and cookie backup key rules (`page_events`).

use crate::ops::call;
use crate::page_events::*;
use serde_json::{Value, json};

fn kind(value: Value) -> PromptKind {
    serde_json::from_value(value).unwrap()
}

#[test]
fn console_messages_become_console_and_pageerror_events() {
    let event =
        console_event(&json!({"kind": "console", "type": "warning", "text": "a b"})).unwrap();
    assert_eq!(event.name, "console");
    assert_eq!(Value::Object(event.payload), json!({"type": "warning", "text": "a b"}));
    let error = console_event(&json!({"kind": "pageerror", "message": "boom"})).unwrap();
    assert_eq!(error.name, "pageerror");
    assert_eq!(Value::Object(error.payload), json!({"message": "boom", "stack": "boom"}));
    let stacked =
        console_event(&json!({"kind": "pageerror", "message": "m", "stack": "s"})).unwrap();
    assert_eq!(stacked.payload["stack"], "s");
}

#[test]
fn malformed_console_messages_are_dropped() {
    for body in [
        json!("text"),
        json!({}),
        json!({"kind": "other"}),
        json!({"kind": "console", "type": "log"}),
        json!({"kind": "console", "type": 1, "text": "x"}),
        json!({"kind": "pageerror", "stack": "s"}),
    ] {
        assert_eq!(console_event(&body), None, "{body}");
    }
}

#[test]
fn only_alert_confirm_and_prompt_are_described() {
    let alert = describe(&kind(json!({"kind": "alert", "message": "hi"}))).unwrap();
    assert_eq!(
        serde_json::to_value(alert).unwrap(),
        json!({"type": "alert", "message": "hi", "defaultValue": ""})
    );
    let prompt =
        describe(&kind(json!({"kind": "textInput", "message": "name?", "defaultText": "x"})))
            .unwrap();
    assert_eq!((prompt.kind, prompt.default_value.as_str()), ("prompt", "x"));
    assert_eq!(
        describe(&kind(json!({"kind": "confirm", "message": "ok?"}))).unwrap().kind,
        "confirm"
    );
    for person in [
        "permission",
        "credentials",
        "openExternalApp",
        "noAppForScheme",
        "savePassword",
        "verificationOffer",
        "beforeUnload",
    ] {
        assert_eq!(describe(&kind(json!({"kind": person}))), None, "{person}");
    }
}

#[test]
fn respond_answers_by_kind_and_accept() {
    let text_input = kind(json!({"kind": "textInput", "message": "m", "defaultText": "d"}));
    let confirm = kind(json!({"kind": "confirm", "message": "m"}));
    let typed = json!({"dialogId": "1", "accept": true, "promptText": "t"});
    assert_eq!(
        respond(&typed, Some((&text_input, false))),
        Ok(PromptAnswer::Text { text: "t".into() })
    );
    let accepted = json!({"dialogId": "1", "accept": true});
    assert_eq!(
        respond(&accepted, Some((&text_input, false))),
        Ok(PromptAnswer::Text { text: "d".into() })
    );
    let no_default = kind(json!({"kind": "textInput", "message": "m"}));
    assert_eq!(
        respond(&accepted, Some((&no_default, false))),
        Ok(PromptAnswer::Text { text: String::new() })
    );
    assert_eq!(respond(&accepted, Some((&confirm, false))), Ok(PromptAnswer::Accept));
    assert_eq!(
        respond(&json!({"dialogId": "1"}), Some((&text_input, false))),
        Ok(PromptAnswer::Cancel)
    );
}

#[test]
fn respond_refuses_a_gone_dialog_and_bad_params() {
    let alert = kind(json!({"kind": "alert", "message": "m"}));
    let gone = respond(&json!({"dialogId": "7"}), None).unwrap_err();
    assert_eq!((gone.code, gone.message.as_str()), ("not_found", "Dialog 7 is gone"));
    assert_eq!(
        respond(&json!({"dialogId": "7"}), Some((&alert, true))).unwrap_err().code,
        "not_found"
    );
    let missing = respond(&json!({}), Some((&alert, false))).unwrap_err();
    assert_eq!(
        (missing.code, missing.message.as_str()),
        ("invalid", "dialog.respond: dialogId: expected a string")
    );
    let bad =
        respond(&json!({"dialogId": "7", "accept": "yes"}), Some((&alert, false))).unwrap_err();
    assert_eq!(bad.message, "dialog.respond: accept: expected a boolean, got a string");
}

#[test]
fn keychain_statuses_decide_the_key() {
    assert_eq!(key_read(SEC_ITEM_NOT_FOUND, None), Ok(false));
    assert_eq!(key_read(SEC_SUCCESS, Some(32)), Ok(true));
    assert_eq!(
        key_read(SEC_SUCCESS, Some(16)),
        Err("the cookie backup key could not be read from the Keychain (status 0)".into())
    );
    assert!(key_read(-128, Some(32)).is_err());
    assert_eq!(key_add(SEC_SUCCESS), Ok(KeyAdd::UseFresh));
    assert_eq!(key_add(SEC_DUPLICATE_ITEM), Ok(KeyAdd::ReadExisting));
    assert_eq!(
        key_add(-34),
        Err("the cookie backup key could not be stored in the Keychain (status -34)".into())
    );
    assert!(key_file_usable(Some(32)));
    assert!(!key_file_usable(Some(31)));
    assert!(!key_file_usable(None));
}

#[test]
fn the_ops_answer_through_call() {
    let event = call(
        "browser_rules_automation_console_event",
        json!({"body": {"kind": "console", "type": "log", "text": "x"}}),
    )
    .unwrap();
    assert_eq!(event, json!({"name": "console", "payload": {"type": "log", "text": "x"}}));
    assert_eq!(
        call("browser_rules_automation_console_event", json!({"body": 3})).unwrap(),
        Value::Null
    );
    let opened = call(
        "browser_rules_automation_dialog_describe",
        json!({"prompt": {"kind": "confirm", "message": "m"}}),
    )
    .unwrap();
    assert_eq!(opened["type"], "confirm");
    let answer = call("browser_rules_automation_dialog_respond",
        json!({"params": {"dialogId": "1", "accept": true}, "held": {"kind": "alert", "message": "m"}, "resolved": false})).unwrap();
    assert_eq!(answer, json!({"answer": {"kind": "accept"}}));
    let gone =
        call("browser_rules_automation_dialog_respond", json!({"params": {"dialogId": "1"}}))
            .unwrap();
    assert_eq!(gone, json!({"error": {"code": "not_found", "message": "Dialog 1 is gone"}}));
    let read =
        call("browser_rules_automation_cookie_backup_key_read", json!({"status": -25300})).unwrap();
    assert_eq!(read, json!({"found": false}));
    let add =
        call("browser_rules_automation_cookie_backup_key_add", json!({"status": -25299})).unwrap();
    assert_eq!(add, json!({"step": "readExisting"}));
    assert_eq!(
        call("browser_rules_automation_cookie_backup_key_file", json!({"length": 32})).unwrap(),
        json!(true)
    );
}
