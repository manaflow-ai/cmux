//! The vmHost exec (moved from the app's CloudVmHostTests; the app keeps the store's and the
//! Settings page's).

use super::*;

#[test]
fn the_command_runs_the_machines_own_vm_host_as_its_work_user() {
    let read = command(None);
    assert!(read.ends_with(r#"as_u env HOME="$h" "$b" acp --json host vm-host"#));
    assert!(command(Some(true)).ends_with("host vm-host on"));
    assert!(command(Some(false)).ends_with("host vm-host off"));
    assert!(read.contains(r#"b="$h/.cmux/bin/cmux-tui""#));
    assert!(
        read.contains("u=cmux; id -u \"$u\" >/dev/null 2>&1 || u=root"),
        "an image from before the work user runs it as root"
    );
    assert!(read.starts_with("set -eu; root() {"));
}

#[test]
fn it_reads_acpmuxs_pretty_json_and_its_error_envelope() {
    let on = "{\n  \"vmHost\": true,\n  \"cmuxVm\": true,\n  \"configured\": null\n}\n";
    assert_eq!(parse(0, on), Some(State { on: true, cmux_vm: true }));
    assert_eq!(parse(0, "note\n{\"vmHost\": false}"), Some(State { on: false, cmux_vm: false }));
    assert_eq!(parse(1, on), None);
    assert_eq!(parse(0, "{\"cmuxVm\": true}"), None);
    let refused = "{\n  \"error\": {\n    \"code\": \"rpc\",\n    \"message\": \"vmHost stays off here: it is only for a VM cmux created\"\n  }\n}";
    assert_eq!(parse(1, ""), None);
    assert_eq!(failure(1, "", refused), "vmHost stays off here: it is only for a VM cmux created");
    let old = "error: unrecognized subcommand 'vm-host'\n\nUsage: acpmux host <COMMAND>";
    assert_eq!(
        failure(2, "", old),
        "error: unrecognized subcommand 'vm-host'",
        "an older cmux-tui says why"
    );
    assert_eq!(failure(82, "out only\n", ""), "out only");
    assert_eq!(failure(5, "", ""), "exit 5");
    assert_eq!(failure(1, "", &"x".repeat(400)).len(), 300);
}

#[test]
fn a_failed_read_is_tried_again_only_after_a_minute() {
    assert!(stale(false, None), "never read");
    assert!(!stale(true, None), "known");
    assert!(!stale(false, Some(59_000)));
    assert!(stale(false, Some(60_000)));
}
