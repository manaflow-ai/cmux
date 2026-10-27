//! `perform_action` on the thread that drives a current_thread runtime: that
//! thread runs every task, so a verb must check its paths on a blocking
//! thread. cmux-blocking records a wrapped call made on it as a stall (and
//! cmux-threads panics on it in Debug).

use std::path::{Path, PathBuf};
use std::sync::Arc;

use serde_json::{Value, json};

use super::{
    ActionContext, MAX_BLOCKING_FILE_ACTIONS, perform_action, process_env_snapshot, scrubbed_env,
};

fn scratch(name: &str) -> PathBuf {
    let path =
        std::env::temp_dir().join(format!("chatmux-actions-test-{}-{name}", std::process::id()));
    let _ = std::fs::remove_dir_all(&path);
    std::fs::create_dir_all(path.join("src")).expect("scratch dir");
    std::fs::write(path.join("src/app.ts"), "export {}\n").expect("scratch file");
    std::fs::canonicalize(&path).expect("canonical scratch")
}

fn context(root: &Path) -> ActionContext {
    ActionContext {
        trust: "supervised".to_owned(),
        local_roots: Some(vec![root.display().to_string()]),
        home: root.to_owned(),
        env: scrubbed_env(&process_env_snapshot()),
        file_slots: Arc::new(tokio::sync::Semaphore::new(MAX_BLOCKING_FILE_ACTIONS)),
        process_cancellation: tokio_util::sync::CancellationToken::new(),
    }
}

fn request(verb: &str, args: Value, root: &Path) -> Value {
    json!({
        "version": 3,
        "actionId": "action_1",
        "verb": verb,
        "args": args,
        "allowedRoots": [root.display().to_string()],
    })
}

#[test]
fn find_and_exec_check_their_paths_off_the_runtime_driver() {
    let root = scratch("off-driver");
    let context = context(&root);
    let runtime = cmux_blocking::runtime::current_thread().build().expect("runtime");
    let stalled = cmux_blocking::counts().stalled;
    let requests = [
        request("find", json!({ "path": "src" }), &root),
        request("find", json!({ "path": "src/app.ts", "pattern": "*.ts" }), &root),
        request("exec", json!({ "command": "pwd", "cwd": "src" }), &root),
    ];
    let answers: Vec<Value> = requests
        .iter()
        .map(|frame| cmux_blocking::runtime::block_on(&runtime, perform_action(frame, &context)))
        .collect();
    assert_eq!(cmux_blocking::counts().stalled, stalled, "a verb blocked the driver: {answers:?}");
    for answer in &answers {
        assert_eq!(answer["ok"], true, "{answer}");
    }
    let output = |index: usize| answers[index]["result"]["output"].as_str().unwrap_or_default();
    assert!(output(0).contains("app.ts"), "{}", output(0));
    assert_eq!(output(1), format!("{}\n", root.join("src/app.ts").display()));
    assert!(output(2).trim_end().ends_with("src"), "{}", output(2));
    let _ = std::fs::remove_dir_all(&root);
}
