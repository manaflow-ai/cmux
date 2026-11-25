//! A real pod on this machine: `CMUX_POOL_POD_LIVE=1 cargo test -p cmux-pool-pod --test live_host -- --ignored`.
//! Needs a systemd user manager and bwrap; makes only `cmux_pod_live_*` units and one temp pods dir.

use cmux_pool_pod::{LABEL_LANE, LocalRunner, PoolHost, PoolPodProvider, SystemdPodRuntime};
use cmux_tui_machine_protocol::{CreateMachineSpec, ExecRequest, MachineProvider};

fn show(unit: &str, prop: &str) -> String {
    let out = std::process::Command::new("systemctl")
        .args(["--user", "show", "-p", prop, "--value", unit])
        .output()
        .unwrap();
    String::from_utf8_lossy(&out.stdout).trim().to_owned()
}

/// Stops the test's slice even when an assertion fails first.
struct StopOnDrop(&'static str);

impl Drop for StopOnDrop {
    fn drop(&mut self) {
        let _ = std::process::Command::new("systemctl").args(["--user", "thaw", self.0]).output();
        let _ = std::process::Command::new("systemctl").args(["--user", "stop", self.0]).output();
    }
}

#[tokio::test]
#[ignore = "touches this machine's systemd user manager"]
async fn pod_lifecycle_on_this_host() {
    if std::env::var("CMUX_POOL_POD_LIVE").as_deref() != Ok("1") {
        return;
    }
    let dir = std::env::temp_dir().join(format!("cmux-pool-pod-live-{}", std::process::id()));
    let host = "this-host".to_owned();
    let runtime = SystemdPodRuntime::new(LocalRunner { host: host.clone() }, dir.to_string_lossy());
    let pool = PoolPodProvider::new("live", vec![PoolHost { name: host, max_pods: 2 }], runtime);
    let m = pool
        .create(CreateMachineSpec {
            name: "live".into(),
            image: None,
            labels: [(LABEL_LANE.to_owned(), "live-test".to_owned())].into(),
        })
        .await
        .unwrap();
    let slice = "cmux_pod_live_1.slice";
    let _cleanup = StopOnDrop(slice);
    assert_eq!(show(slice, "MemoryMax"), (4096u64 << 20).to_string());

    pool.write_file(&m, "in.txt", b"hello pod").await.unwrap();
    // A second pod's file must be invisible from the first.
    let other = pool
        .create(CreateMachineSpec { name: "other".into(), image: None, labels: Default::default() })
        .await
        .unwrap();
    let _cleanup_other = StopOnDrop("cmux_pod_other_2.slice");
    pool.write_file(&other, "secret.txt", b"other pod").await.unwrap();
    let peek = pool
        .exec(
            &m,
            ExecRequest {
                program: "sh".into(),
                args: vec![
                    "-c".into(),
                    "ls \"$CMUX_POD_ROOT/..\"; cat \"$CMUX_POD_ROOT/../other-2/secret.txt\"".into(),
                ],
                ..Default::default()
            },
        )
        .await
        .unwrap();
    assert_ne!(peek.exit_code, 0);
    assert_eq!(String::from_utf8_lossy(&peek.stdout).trim(), "live-1");
    pool.delete(&other).await.unwrap();
    let out = pool
        .exec(&m, ExecRequest {
            program: "sh".into(),
            args: vec!["-c".into(), "cat in.txt; echo; pwd; echo $$; cat /proc/self/cgroup; touch /home/x 2>/dev/null && echo WROTE-OUTSIDE || echo ro-outside".into()],
            ..Default::default()
        })
        .await
        .unwrap();
    let text = String::from_utf8_lossy(&out.stdout).into_owned();
    assert_eq!(out.exit_code, 0, "{text} {}", String::from_utf8_lossy(&out.stderr));
    let lines: Vec<&str> = text.lines().collect();
    assert_eq!(lines[0], "hello pod");
    assert_eq!(lines[1], dir.join("live-1").to_string_lossy());
    assert!(text.contains("ro-outside"), "{text}");
    // Its own pid namespace: the shell is a low pid, not the host's.
    assert!(lines[2].parse::<u32>().is_ok_and(|pid| pid < 10), "{text}");
    assert!(text.contains(slice), "{text}");

    pool.pause(&m).await.unwrap();
    assert_eq!(show(slice, "FreezerState"), "frozen");
    assert_eq!(pool.read_file(&m, "in.txt").await.unwrap(), b"hello pod");
    pool.resume(&m).await.unwrap();
    assert_eq!(show(slice, "FreezerState"), "running");

    pool.delete(&m).await.unwrap();
    assert_ne!(show(slice, "ActiveState"), "active");
    assert!(!dir.join("live-1").exists());
    let meter = pool.drain_meter().unwrap();
    // live-1: before pause and after resume; other-2: its whole life.
    assert_eq!(meter.iter().filter(|i| i.lane.as_deref() == Some("live-test")).count(), 2);
    assert_eq!(meter.len(), 3);
    let _ = std::fs::remove_dir(&dir);
}

#[test]
#[ignore = "touches this machine's systemd user manager"]
fn slot_lifecycle_on_this_host() {
    use cmux_pool_pod::slots::{PauseMode, PodSlots, ProcessRunner, Slot, SlotSize, SlotState};
    if std::env::var("CMUX_POOL_POD_LIVE").as_deref() != Ok("1") {
        return;
    }
    let dir = std::env::temp_dir().join(format!("cmux-pool-slot-live-{}", std::process::id()));
    // The init proves it runs in the pod: it writes its boot count under $HOME, then waits.
    let init = "echo boot >> \"$HOME/boots\"; echo \"$CMUX_POD_ROOT\" > \"$HOME/root\"; exec sleep infinity";
    let pods = PodSlots::new(ProcessRunner, dir.to_string_lossy()).with_init(
        "sh",
        vec!["-c".into(), init.into()],
        vec![],
    );
    let slot = Slot::parse("live-slot").unwrap();
    let slice = "cmux_pod_live_slot.slice";
    let _cleanup = StopOnDrop(slice);
    let root = dir.join("live-slot");
    let wait_boots = |n: usize| {
        for _ in 0..50 {
            let boots = std::fs::read_to_string(root.join("boots")).unwrap_or_default();
            if boots.lines().count() == n {
                return;
            }
            std::thread::sleep(std::time::Duration::from_millis(100));
        }
        panic!("init did not boot {n} times");
    };

    let size = SlotSize { vcpus: 1, memory_mib: 768 };
    assert_eq!(pods.create(&slot, size).unwrap(), SlotState::Running);
    wait_boots(1);
    assert_eq!(std::fs::read_to_string(root.join("root")).unwrap().trim(), root.to_string_lossy());
    assert_eq!(show(slice, "MemoryMax"), (768u64 << 20).to_string());
    assert_eq!(pods.create(&slot, size).unwrap(), SlotState::Running);

    assert_eq!(pods.pause(&slot, PauseMode::Memory).unwrap(), SlotState::Paused);
    assert_eq!(show(slice, "FreezerState"), "frozen");
    assert_eq!(pods.list().unwrap(), vec![(slot.clone(), SlotState::Paused)]);
    assert_eq!(pods.resume(&slot).unwrap(), SlotState::Running);
    assert_eq!(show(slice, "FreezerState"), "running");

    // Disk pause from frozen: no processes left, the root stays, resume boots again at its size.
    pods.pause(&slot, PauseMode::Memory).unwrap();
    assert_eq!(pods.pause(&slot, PauseMode::Disk).unwrap(), SlotState::Stopped);
    assert_ne!(show(slice, "ActiveState"), "active");
    assert!(root.join("boots").exists());
    assert_eq!(pods.list().unwrap(), vec![(slot.clone(), SlotState::Stopped)]);
    assert_eq!(pods.resume(&slot).unwrap(), SlotState::Running);
    wait_boots(2);
    assert_eq!(show(slice, "MemoryMax"), (768u64 << 20).to_string());

    pods.destroy(&slot).unwrap();
    pods.destroy(&slot).unwrap();
    assert_ne!(show(slice, "ActiveState"), "active");
    assert!(!root.exists());
    assert_eq!(pods.list().unwrap(), vec![]);
    let _ = std::fs::remove_dir_all(&dir);
}
