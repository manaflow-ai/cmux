use serde_json::json;

use super::*;

#[test]
fn app_words_print_as_vm_words() {
    assert_eq!(
        respell("run `cmux vm list-machines` for your VMs"),
        "run `cmux vm ls` for your VMs"
    );
    assert_eq!(
        respell("cmux cloud file-read --target machine:vm-1 --path /tmp/s"),
        "cmux vm file-read --target vm:vm-1 --path /tmp/s"
    );
    assert_eq!(
        respell("cmux cloud start-chat --target machine:vm-1 --login none --from-folder /w"),
        "cmux cloud start-chat --target vm:vm-1 --login none --from-folder /w"
    );
    assert_eq!(respell("[--target machine:MACHINE_ID]"), "[--target vm:VM_ID]");
    assert_eq!(respell("cmux cloud list-machines --json"), "cmux vm ls --json");
    // Prose about a machine stays prose.
    assert_eq!(respell("new Cloud machine: no capacity"), "new Cloud machine: no capacity");
    assert_eq!(respell("cloud.machine:read"), "cloud.machine:read");
}

#[test]
fn a_listing_keeps_its_keys_and_prints_vm_targets() {
    let listed = json!({"result": {"machines": [{"machine_id": "vm-1", "target": "machine:vm-1"}],
            "next": "cmux cloud exec --target machine:vm-1 --command 'uname -a'"}});
    let printed = respell_value(&listed);
    assert_eq!(printed["result"]["machines"][0]["target"], "vm:vm-1");
    assert_eq!(printed["result"]["machines"][0]["machine_id"], "vm-1");
    assert_eq!(printed["result"]["next"], "cmux vm exec --target vm:vm-1 --command 'uname -a'");
    let error = json!({"code": "chat_target.unknown_vm", "message": "run `cmux vm list-machines`",
            "details": {"list": "cmux cloud list-machines --json"}});
    let printed = respell_value(&error);
    assert_eq!(printed["message"], "run `cmux vm ls`");
    assert_eq!(printed["details"]["list"], "cmux vm ls --json");
}

/// A VM's output and a chat's reply are data: a file that says `--target machine:x` reads
/// back byte for byte.
#[test]
fn only_an_errors_own_message_is_respelled() {
    let answer = json!({"message": "run `cmux vm list-machines`",
            "items": [{"message": "--target machine:MACHINE_ID"}],
            "details": {"again": "cmux cloud start-chat --target machine:vm-a --login none"}});
    let printed = respell_value(&answer);
    assert_eq!(printed["message"], "run `cmux vm ls`");
    assert_eq!(printed["items"][0]["message"], "--target machine:MACHINE_ID");
    assert_eq!(printed["details"]["again"], "cmux cloud start-chat --target vm:vm-a --login none");
}

#[test]
fn data_the_vm_or_the_agent_wrote_prints_unchanged() {
    let data = "cmux cloud list-machines --json; --target machine:MACHINE_ID";
    for key in ["stdout", "stderr", "content", "reply", "reason", "command", "title"] {
        let answer = json!({"result": {key: data}, "follow_up": {"send": "cmux cloud exec --target machine:vm-a"}});
        let printed = respell_value(&answer);
        assert_eq!(printed["result"][key], data, "{key}");
        assert_eq!(printed["follow_up"]["send"], "cmux vm exec --target vm:vm-a");
    }
}

#[test]
fn vm_targets_reach_the_app_as_machine_targets() {
    assert_eq!(app_target(json!("vm:vm-1")), json!("machine:vm-1"));
    assert_eq!(app_target(json!("machine:vm-1")), json!("machine:vm-1"));
    assert_eq!(app_target(json!("dev")), json!("dev"));
    assert_eq!(bare_id("vm:vm-1"), "vm-1");
    assert_eq!(bare_id("machine:vm-1"), "vm-1");
    assert_eq!(bare_id("dev"), "dev");
}
