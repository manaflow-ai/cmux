//! The sandbox verdict `--smoke` applies to the host's child processes.

use cmux_remote_browser_host::sandbox_status::{
    Child, json, kinds_of, refused_browser_switch, verdict,
};

fn child(kind: &str, sandboxed: Option<bool>, denied: Option<bool>) -> Child {
    Child {
        kind: kind.to_string(),
        sub_kind: String::new(),
        sandboxed,
        outside_read_denied: denied,
    }
}

#[test]
fn reads_the_process_type_from_a_helper_command_line() {
    let command = "/A/cmux.app/Contents/Frameworks/cmux-remote-browser-host Helper (Renderer).app/\
                   Contents/MacOS/cmux-remote-browser-host Helper (Renderer) --type=renderer \
                   --lang=en-US --seatbelt-client=24";
    assert_eq!(kinds_of(command), ("renderer".to_string(), String::new()));
    let utility = "/x/Helper --type=utility --utility-sub-type=network.mojom.NetworkService --foo";
    assert_eq!(
        kinds_of(utility),
        ("utility".to_string(), "network.mojom.NetworkService".to_string())
    );
    assert_eq!(kinds_of("/x/crashpad_handler --monitor-self"), (String::new(), String::new()));
}

#[test]
fn sandboxed_renderer_and_gpu_pass() {
    let children = [
        child("renderer", Some(true), Some(true)),
        child("gpu-process", Some(true), Some(true)),
        // Other children are reported, not judged.
        child("utility", Some(false), Some(false)),
        child("", Some(false), Some(false)),
    ];
    assert_eq!(verdict(&children), Ok(()));
}

#[test]
fn an_unsandboxed_renderer_fails() {
    let children =
        [child("renderer", Some(false), Some(false)), child("gpu-process", Some(true), Some(true))];
    assert_eq!(verdict(&children), Err("sandbox: a renderer process is not sandboxed".to_string()));
}

#[test]
fn an_unsandboxed_gpu_process_fails() {
    let children =
        [child("renderer", Some(true), Some(true)), child("gpu-process", Some(false), Some(false))];
    assert_eq!(
        verdict(&children),
        Err("sandbox: a gpu-process process is not sandboxed".to_string())
    );
}

#[test]
fn a_renderer_that_may_read_outside_its_profile_fails() {
    let children =
        [child("renderer", Some(true), Some(false)), child("gpu-process", Some(true), Some(true))];
    assert_eq!(
        verdict(&children),
        Err("sandbox: a renderer process may read a file outside its profile".to_string())
    );
}

#[test]
fn no_answer_fails_closed() {
    let gpu = child("gpu-process", Some(true), Some(true));
    assert!(verdict(&[child("renderer", None, Some(true)), gpu.clone()]).is_err());
    assert!(verdict(&[child("renderer", Some(true), None), gpu]).is_err());
}

#[test]
fn no_renderer_fails() {
    assert_eq!(
        verdict(&[child("gpu-process", Some(true), Some(true))]),
        Err("sandbox: the host has no renderer process to check".to_string())
    );
    assert!(verdict(&[]).is_err());
}

#[test]
fn json_lists_every_child() {
    let children = [child("renderer", Some(true), Some(true)), child("utility", None, Some(false))];
    assert_eq!(
        json(&children),
        "[{\"type\":\"renderer\",\"sub_type\":\"\",\"sandboxed\":true,\"outside_read_denied\":true},\
         {\"type\":\"utility\",\"sub_type\":\"\",\"sandboxed\":null,\"outside_read_denied\":false}]"
    );
}

#[test]
fn no_gpu_process_fails() {
    assert_eq!(
        verdict(&[child("renderer", Some(true), Some(true))]),
        Err("sandbox: the host has no gpu-process process to check".to_string())
    );
}

#[test]
fn the_browser_process_refuses_switches_that_turn_the_sandbox_off_or_move_the_helpers() {
    let args = |extra: &str| {
        vec!["cmux-remote-browser-host".to_string(), "--serve".into(), extra.to_string()]
    };
    for bad in [
        "--no-sandbox",
        "--no-sandbox=1",
        "--browser-subprocess-path=/tmp/x",
        "--main-bundle-path=/tmp/x.app",
        "--renderer-cmd-prefix=/bin/sh",
        "--gpu-launcher=/bin/sh",
        "--utility-cmd-prefix=x",
        "--single-process",
        "--in-process-gpu",
        "--disable-gpu-sandbox",
    ] {
        assert!(refused_browser_switch(&args(bad)).is_some(), "{bad} was accepted");
    }
    assert_eq!(refused_browser_switch(&args("--listen")), None);
    assert_eq!(refused_browser_switch(&args("https://example.com/--no-sandbox")), None);
}
