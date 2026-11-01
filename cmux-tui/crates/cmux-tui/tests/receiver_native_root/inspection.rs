//! An unrelated work-user process must not inspect either private recipient.
use super::{Agent, Daemon, WORK_UID, drive_until, frame, hosted_root, policy_reader};
use std::fs::File;
use std::io;
use std::os::unix::process::CommandExt as _;
use std::process::Command;
use std::time::{Duration, Instant};

use cmux_link::root_bootstrap::{Capability, Host, StopReceipt};
use serde_json::{Value, json};

const PROBE: &str = "CMUX_RECEIVER_INSPECTION_TARGETS";
const RESULT: &str = "RECEIVER_INSPECTION_RESULT ";

fn inspect(pid: u32) -> Value {
    // Inspect permissions only. Never read environment or private memory.
    let descriptor = std::fs::read_link(format!("/proc/{pid}/fd/0"));
    let maps = File::open(format!("/proc/{pid}/maps"));
    json!({
        "fd_readable":descriptor.is_ok(),
        "maps_openable":maps.is_ok(),
        "fd_denied":descriptor.is_err_and(|error| error.kind()==io::ErrorKind::PermissionDenied),
        "maps_denied":maps.is_err_and(|error| error.kind()==io::ErrorKind::PermissionDenied),
    })
}

#[test]
#[ignore = "private re-exec observer; not a standalone test"]
fn receiver_process_inspection_probe() {
    let Some(targets) = std::env::var_os(PROBE) else { return };
    // SAFETY: geteuid reads the kernel credential without side effects.
    assert_eq!(unsafe { libc::geteuid() }, WORK_UID);
    let status = std::fs::read_to_string("/proc/self/status").unwrap();
    let effective = status.lines().find_map(|line| line.strip_prefix("CapEff:\t")).unwrap();
    assert_eq!(
        u64::from_str_radix(effective, 16).unwrap() & (1 << 19),
        0,
        "the observer must not have CAP_SYS_PTRACE"
    );
    let targets: [u32; 3] = serde_json::from_str(targets.to_str().unwrap()).unwrap();
    println!(
        "{RESULT}{}",
        json!({
            "ordinary":inspect(targets[0]),
            "native_daemon":inspect(targets[1]),
            "receiver":inspect(targets[2]),
        })
    );
}

#[test]
#[ignore = "requires hosted Linux root; scripts/ci/verify-link-root-boundary.py"]
fn receiver_root_privileged_native_chain_blocks_same_user_process_inspection() {
    hosted_root();
    let ordinary_host = Host::new().unwrap();
    let ordinary = Daemon::with_capability(&ordinary_host, Capability::LifetimeOnly);
    let host = Host::new_native().unwrap();
    let agent = Agent::start();
    let daemon = Daemon::start(&host);
    let ticket = host.new_ticket().unwrap();
    assert!(host.offer(&ticket));
    let request = host.prepare_native(&ticket).unwrap();
    assert!(host.publish_native(request, frame()));
    drive_until(&host, |sent| sent);
    let (reader, pid) = policy_reader(&agent.listener, &daemon.child);
    // The receiving child already holds its original private bootstrap while
    // its public policy read remains pending. The daemon retains the frame too.
    let output = Command::new(std::env::current_exe().unwrap())
        .args([
            "--ignored",
            "--exact",
            "inspection::receiver_process_inspection_probe",
            "--nocapture",
        ])
        .env_clear()
        .env(
            PROBE,
            serde_json::to_string(&[ordinary.child.id(), daemon.child.id(), pid as u32]).unwrap(),
        )
        .gid(WORK_UID)
        .uid(WORK_UID)
        .output()
        .unwrap();
    // Cleanup precedes the expected baseline failure: leave no live receiver
    // behind when the external inspection oracle detects missing protection.
    assert_eq!(
        host.quiesce(Instant::now() + Duration::from_secs(8)).unwrap(),
        StopReceipt::Acknowledged
    );
    drop(reader);
    assert!(daemon.child.try_wait().unwrap().is_none());
    assert!(!std::path::Path::new(&format!("/proc/{pid}/stat")).exists());
    assert!(
        output.status.success(),
        "observer setup failed: {}",
        String::from_utf8_lossy(&output.stderr)
    );
    let stdout = String::from_utf8(output.stdout).unwrap();
    let report: Value = stdout
        .lines()
        .find_map(|line| {
            line.split_once(RESULT).map(|(_, value)| serde_json::from_str(value).unwrap())
        })
        .expect("work-user inspection report");
    assert_eq!(
        report["ordinary"]["fd_readable"], true,
        "the environment did not allow ordinary same-user inspection: {report}"
    );
    assert_eq!(
        report["ordinary"]["maps_openable"], true,
        "the environment hid ordinary same-user maps: {report}"
    );
    let denied =
        |name: &str| report[name]["fd_denied"] == true && report[name]["maps_denied"] == true;
    assert!(
        denied("native_daemon") && denied("receiver"),
        "private bootstrap recipients remained inspectable: {report}"
    );
    println!("ROOT_BOUNDARY_EXECUTED native_private_process_inspection");
}
