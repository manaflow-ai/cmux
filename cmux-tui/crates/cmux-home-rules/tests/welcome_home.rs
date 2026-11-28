//! Chat colours (`HomeChatColorStore`, `HomeColor(hex:)`), the attachment cache's rules and the
//! bundled Chief tools.

use cmux_home_rules::call;
use cmux_home_rules::welcome::attachments::{
    CacheFile, NameRequest, Variant, file_name, thumbnail_source, trim,
};
use cmux_home_rules::welcome::colors::{canonical_hex, load};
use cmux_home_rules::welcome::tools::{
    MemoryDirection, memory_tool_args, memory_tool_failure, usage_tool_candidates,
};
use serde_json::{Value, json};
use std::collections::HashMap;

#[test]
fn hex_text_is_canonical() {
    assert_eq!(canonical_hex("#34c759").as_deref(), Some("#34C759"));
    assert_eq!(canonical_hex(" 34C759 ").as_deref(), Some("#34C759"));
    assert_eq!(canonical_hex("#fff").as_deref(), Some("#FFFFFF"));
    assert_eq!(canonical_hex("#11223380").as_deref(), Some("#11223380"));
    assert_eq!(canonical_hex("#112233FF").as_deref(), Some("#112233"));
    assert_eq!(canonical_hex("#12345"), None);
    assert_eq!(canonical_hex("navy"), None);
}

#[test]
fn applying_names_then_resets_a_chats_colours() {
    let out = call(
        "welcome.chatColorsApply",
        &json!({"conversation": "chat", "values": {"received": "#1C2A4A", "receivedText": "#FFFFFF"}}),
    )
    .unwrap();
    assert_eq!(out["applied"], true);
    assert_eq!(out["changed"], true);
    assert_eq!(out["chats"]["chat"], json!({"received": "#1C2A4A", "receivedText": "#FFFFFF"}));
    assert_eq!(out["write"]["key"], "cmux.home.chatColors");
    let summary =
        call("welcome.chatColorsSummary", &json!({"colors": out["chats"]["chat"]})).unwrap();
    assert_eq!(summary["summary"], "received=#1C2A4A receivedText=#FFFFFF");
    let reset = call(
        "welcome.chatColorsApply",
        &json!({"chats": out["chats"], "conversation": "chat", "reset": true}),
    )
    .unwrap();
    assert_eq!(reset["chats"], json!({}));
    let refused = call(
        "welcome.chatColorsApply",
        &json!({"conversation": "chat", "values": {"sent": "navy"}}),
    )
    .unwrap();
    assert_eq!(refused["refusal"], json!({"role": "sent", "value": "navy"}));
    let nothing =
        call("welcome.chatColorsApply", &json!({"conversation": "chat", "values": {"sent": "  "}}))
            .unwrap();
    assert_eq!(nothing["applied"], false);
    assert_eq!(nothing["refusal"], Value::Null);
}

#[test]
fn setting_the_same_colours_writes_nothing_and_a_bad_store_loads_empty() {
    let chats = json!({"chat": {"sent": "#34C759"}});
    let out = call(
        "welcome.chatColorsSet",
        &json!({"chats": chats, "conversation": "chat", "colors": {"sent": "#34c759"}}),
    )
    .unwrap();
    assert_eq!(out["changed"], false);
    assert_eq!(out["write"], Value::Null);
    assert!(
        load(Some(r##"{"a": {"sent": "#000"}, "b": {"sent": "navy"}}"##)).is_empty(),
        "all or nothing"
    );
    assert_eq!(load(Some(r##"{"a": {"sent": "#000"}}"##))["a"].sent.as_deref(), Some("#000000"));
}

#[test]
fn cache_file_names_per_variant() {
    let req = |variant, extension: Option<&str>| NameRequest {
        hash: "abc".into(),
        variant: Some(variant),
        extension: extension.map(str::to_string),
        has_poster: false,
        has_preview: true,
        max_pixel: 320,
    };
    assert_eq!(file_name(&req(Variant::Original, Some("png"))).unwrap(), "abc-original.png");
    assert_eq!(file_name(&req(Variant::Original, None)).unwrap(), "abc-original");
    assert_eq!(file_name(&req(Variant::Poster, Some("jpg"))), Err("no_poster"));
    assert_eq!(file_name(&req(Variant::Preview, Some("mp4"))).unwrap(), "abc-preview.mp4");
    assert_eq!(file_name(&req(Variant::Thumbnail, None)).unwrap(), "abc-thumb-320.jpg");
    assert_eq!(thumbnail_source("image/png", false), Ok("original"));
    assert_eq!(thumbnail_source("video/mp4", true), Ok("poster"));
    assert_eq!(thumbnail_source("video/mp4", false), Err("no_thumbnail"));
}

#[test]
fn trim_drops_the_least_recently_used_but_never_the_kept_file() {
    let file = |path: &str, used: f64, size: i64| CacheFile {
        path: path.into(),
        used: Some(used),
        size,
        regular: true,
        hidden: false,
    };
    let files = vec![
        file("/c/new", 30.0, 40),
        file("/c/old", 10.0, 40),
        file("/c/mid", 20.0, 40),
        file("/c/kept", 5.0, 40),
    ];
    assert_eq!(trim(&files, 100, "/c/kept"), ["/c/old", "/c/mid"]);
    assert!(trim(&files, 160, "").is_empty(), "under the limit nothing goes");
    let out = call(
        "welcome.attachmentTrim",
        &json!({"files": [{"path": "/c/.DS_Store", "size": 999, "hidden": true}], "limit": 0}),
    )
    .unwrap();
    assert_eq!(out["remove"], json!([]), "hidden files do not count");
}

#[test]
fn the_usage_tool_prefers_the_explicit_then_an_optchat_host_then_the_bundle() {
    let mut env = HashMap::new();
    env.insert("CMUX_NEXT_MUX_HOST".to_string(), "/opt/mux/node-mux".to_string());
    assert_eq!(usage_tool_candidates(&env, Some("/App/bin")), ["/App/bin/optchat-chief"]);
    env.insert("CMUX_NEXT_MUX_HOST".to_string(), "/opt/optchat-chief".to_string());
    env.insert("CMUX_OPTCHAT_CHIEF".to_string(), "/x/chief".to_string());
    assert_eq!(
        usage_tool_candidates(&env, Some("/App/bin/")),
        ["/x/chief", "/opt/optchat-chief", "/App/bin/optchat-chief"]
    );
    let args =
        call("welcome.usageToolArgs", &json!({"arguments": ["usage"], "muxHome": "/m"})).unwrap();
    assert_eq!(args["arguments"], json!(["usage", "--mux-home", "/m", "--chiefs", "--json"]));
}

#[test]
fn memory_tool_arguments_and_failure_text() {
    assert_eq!(
        memory_tool_args(MemoryDirection::Export, "/m", "/d"),
        ["memory", "export", "--text", "/d", "--mux-home", "/m"]
    );
    assert_eq!(
        memory_tool_args(MemoryDirection::Import, "/m", "/d"),
        ["memory", "import", "--mux-home", "/m", "/d"]
    );
    let args: Vec<String> =
        ["memory", "import", "--mux-home"].iter().map(|s| (*s).to_string()).collect();
    assert_eq!(memory_tool_failure(&args, "boom"), "optchat-chief memory import: boom");
}
