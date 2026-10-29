//! The `access-request*` frames decode through the one `cmd`-tagged
//! `Command` enum that spec/sdk-schema.json types: each schema'd
//! command is served, an unknown or command-bearing param and a non-string
//! value are a bad request, and a null optional param is absent.

use std::time::Instant;

use serde_json::{Map, Value, json};

use super::{AccessRequests, Command, Refusal, serve};

fn frame(value: Value) -> Map<String, Value> {
    match value {
        Value::Object(object) => object,
        other => panic!("not an object: {other}"),
    }
}

fn run(requests: &AccessRequests, value: Value) -> Result<Value, &'static str> {
    Command::parse(frame(value))
        .and_then(|command| serve(requests, command, Instant::now()))
        .map_err(Refusal::code)
}

fn request_id(requests: &AccessRequests, value: Value) -> String {
    let made = run(requests, value).expect("made");
    made["request_id"].as_str().expect("request_id").to_owned()
}

#[test]
fn every_schema_command_is_decoded_by_its_cmd() {
    let requests = AccessRequests::default();
    let id = request_id(&requests, json!({"cmd":"access-request","kind":"file","path":"/a"}));
    assert_eq!(id.len(), 32);
    assert_eq!(
        run(&requests, json!({"cmd":"access-request-status","request_id":id})),
        Ok(json!({"state":"pending"}))
    );
    let listed = run(&requests, json!({"cmd":"access-request-list"})).expect("list");
    assert_eq!(listed["requests"][0]["request_id"], json!(id));
    assert_eq!(listed["requests"][0]["kind"], json!("file"));
    assert_eq!(
        run(
            &requests,
            json!({"cmd":"access-request-answer","request_id":id,"outcome":"delivered","path":"/b"})
        ),
        Ok(json!({}))
    );
    assert_eq!(
        run(&requests, json!({"cmd":"access-request-status","request_id":id})),
        Ok(json!({"state":"delivered","path":"/b"}))
    );
}

#[test]
fn an_unknown_command_or_unknown_param_is_a_bad_request() {
    let requests = AccessRequests::default();
    for value in [
        json!({"cmd":"access-request-nope"}),
        json!({"cmd":"access-request-list","extra":1}),
        json!({"cmd":"access-request","kind":"file","path":"/a","extra":1}),
        json!({"cmd":"access-request","kind":"file","path":"/a","command":"rm -rf /"}),
        json!({"cmd":"access-request-list","initial_command":"x"}),
    ] {
        assert_eq!(run(&requests, value.clone()), Err("access_request.bad_request"), "{value}");
    }
}

#[test]
fn a_non_string_value_is_a_bad_request_and_a_null_optional_is_absent() {
    let requests = AccessRequests::default();
    for value in [
        json!({"cmd":"access-request","kind":"file","path":7}),
        json!({"cmd":"access-request","kind":null,"path":"/a"}),
        json!({"cmd":"access-request-status","request_id":null}),
        json!({"cmd":"access-request","kind":"secret","name":"TOKEN","path":"/a"}),
        json!({"cmd":"access-request","kind":"file","path":"relative"}),
    ] {
        assert_eq!(run(&requests, value.clone()), Err("access_request.bad_request"), "{value}");
    }
    let id = request_id(
        &requests,
        json!({"cmd":"access-request","kind":"secret","name":"TOKEN","path":null,"session":null}),
    );
    let denied = json!({"cmd":"access-request-answer","request_id":id,"outcome":"denied",
                        "path":null,"value":null,"reason":null});
    assert_eq!(run(&requests, denied), Ok(json!({})));
    assert_eq!(
        run(&requests, json!({"cmd":"access-request-status","request_id":id})),
        Ok(json!({"state":"denied","reason":null}))
    );
}

#[test]
fn a_secret_is_answered_to_the_first_status_read_only() {
    let requests = AccessRequests::default();
    let id = request_id(&requests, json!({"cmd":"access-request","kind":"secret","name":"TOKEN"}));
    let file_answer =
        json!({"cmd":"access-request-answer","request_id":id,"outcome":"delivered","path":"/b"});
    assert_eq!(run(&requests, file_answer), Err("access_request.bad_request"));
    let answer =
        json!({"cmd":"access-request-answer","request_id":id,"outcome":"delivered","value":"s3"});
    assert_eq!(run(&requests, answer.clone()), Ok(json!({})));
    assert_eq!(run(&requests, answer), Err("access_request.answered"));
    let status = json!({"cmd":"access-request-status","request_id":id});
    assert_eq!(run(&requests, status.clone()), Ok(json!({"state":"delivered","value":"s3"})));
    assert_eq!(run(&requests, status), Ok(json!({"state":"delivered","taken":true})));
}

/// The frame is decoded before its `request_id` is looked up (a message is
/// validated before dispatch, as Mojo's generated validators do): a frame
/// that does not decode is a bad request even for an id nobody filed, and
/// only a well-formed frame learns that its id is unknown.
#[test]
fn a_malformed_answer_is_a_bad_request_before_its_id_is_looked_up() {
    let requests = AccessRequests::default();
    let unknown = "0".repeat(32);
    for value in [
        json!({"cmd":"access-request-answer","request_id":unknown}),
        json!({"cmd":"access-request-answer","request_id":unknown,"outcome":"denied","value":7}),
        json!({"cmd":"access-request-answer","request_id":unknown,"outcome":"denied","extra":1}),
    ] {
        assert_eq!(run(&requests, value.clone()), Err("access_request.bad_request"), "{value}");
    }
    let well_formed =
        json!({"cmd":"access-request-answer","request_id":unknown,"outcome":"denied"});
    assert_eq!(run(&requests, well_formed), Err("access_request.unknown_request"));
    assert_eq!(
        run(&requests, json!({"cmd":"access-request-status","request_id":unknown})),
        Err("access_request.unknown_request")
    );
}
