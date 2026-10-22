//! Lines an agent process writes on stdout (ACP JSON-RPC, Claude stream-json,
//! Codex app-server JSON-RPC) through acpmux's parse and translators, one
//! session per input so state carries across lines.
#![no_main]

use acpmux::rpc::Message;
use libfuzzer_sys::fuzz_target;
use serde_json::Value;

fuzz_target!(|data: &[u8]| {
    let Ok(runtime) = tokio::runtime::Builder::new_current_thread().enable_time().build() else {
        return;
    };
    let claude = acpmux::claude_stdio::Translator::new("fuzz".into(), "default", "default", "high");
    let codex = acpmux::codex_app_server::translator();
    let _ = codex.start();
    runtime.block_on(async {
        for line in data.split(|byte| *byte == b'\n') {
            let Ok(text) = std::str::from_utf8(line) else { continue };
            if let Ok(message) = Message::parse(text) {
                let _ = message.to_value();
                let _ = message.bounded_line();
                let _ = claude.outbound(&message).await;
                let _ = codex.from_client(&message.to_value());
            }
            let Ok(value) = serde_json::from_str::<Value>(text) else { continue };
            let _ = claude.inbound(&value).await;
            let _ = claude.take_stdin_replies().await;
            let outs = codex.from_server(&value);
            let split = acpmux::codex_app_server::split(outs);
            for message in split.hub {
                let _ = acpmux::codex_app_server::into_value(message);
            }
            let _ = acpmux::codex_app_server::tap_kind(&value);
        }
        let _ = claude.end_background_shells().await;
        let _ = claude.fail_pending("fuzz end").await;
        let _ = codex.server_closed("fuzz end");
    });
});
