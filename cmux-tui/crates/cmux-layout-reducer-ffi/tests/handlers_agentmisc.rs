//! `handlers_agentmisc_*` through the C ABI: each op answers in the camelCase the app decodes,
//! and an unknown op or a malformed request is refused.

use cmux_layout_reducer_ffi::{ERR_INVALID, OK, cmux_layout_reducer_json};
use serde_json::{Value, json};
use std::ffi::CString;

fn call(op: &str, request: &[u8]) -> (i32, Option<Value>) {
    let op = CString::new(op).expect("op");
    let mut output = vec![0u8; 4096];
    let mut len = 0usize;
    let code = unsafe {
        cmux_layout_reducer_json(
            request.as_ptr(),
            request.len(),
            op.as_ptr(),
            output.as_mut_ptr(),
            output.len(),
            &mut len,
        )
    };
    let body =
        (code == OK).then(|| serde_json::from_slice(&output[..len]).expect("answer is JSON"));
    (code, body)
}

#[test]
fn live_web_start_answers_the_argv() {
    let (code, body) = call(
        "handlers_agentmisc_live_web",
        br#"{"action":"start","path":"/src/cmux","cliKnown":true,"liveAllowed":true}"#,
    );
    assert_eq!(code, OK);
    assert_eq!(
        body,
        Some(json!({"argv": ["live", "start", "--worktree", "/src/cmux"], "timeoutSeconds": 300,
                    "toastSeconds": 300, "toast": "liveWeb.starting", "done": "liveWeb.started"}))
    );
}

#[test]
fn live_swift_refuses_a_nightly() {
    let (code, body) = call(
        "handlers_agentmisc_live_swift",
        br#"{"on":true,"cliKnown":true,"bundleId":"com.cmuxterm.app.nightly"}"#,
    );
    assert_eq!(code, OK);
    assert_eq!(
        body,
        Some(json!({"refusal": "liveSwift.notTagged", "timeoutSeconds": 0, "toastSeconds": 0}))
    );
}

#[test]
fn the_other_ops_answer_in_camel_case() {
    let (_, body) = call(
        "handlers_agentmisc_history_entry",
        br#"{"hasList":true,"entry":"-1","current":1,"count":2,"back":1}"#,
    );
    assert_eq!(body, Some(json!({"offset": -1})));
    let (_, body) = call(
        "handlers_agentmisc_comment_target",
        br#"{"threadsOn":true,"kind":"pty","session":"s","linkThreads":true,"cwd":"/r","title":"a/b"}"#,
    );
    assert_eq!(body, Some(json!({"root": "/r", "source": "a\u{2215}b"})));
    let (_, body) =
        call("handlers_agentmisc_chief_toggle", br#"{"open":"1","defaultConversation":"home"}"#);
    assert_eq!(body, Some(json!({"tryClose": false, "conversation": "home"})));
    let (_, body) = call(
        "handlers_agentmisc_chief_endpoint",
        br#"{"host":"127.0.0.1","hasPid":true,"pidRunning":false}"#,
    );
    assert_eq!(body, Some(json!({"usable": false})));
    let (_, body) = call(
        "handlers_agentmisc_search_text",
        br#"{"title":"T","displayTitle":"zsh","kind":"pty","workspaceName":"W"}"#,
    );
    assert_eq!(body, Some(json!({"text": "zsh W"})));
}

#[test]
fn an_unknown_op_or_a_bad_request_is_refused() {
    assert_eq!(call("handlers_agentmisc_nope", b"{}").0, ERR_INVALID);
    assert_eq!(call("handlers_agentmisc_live_web", b"not json").0, ERR_INVALID);
}
