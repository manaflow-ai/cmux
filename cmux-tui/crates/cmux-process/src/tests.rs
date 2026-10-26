//! The spawn features beyond std's shape: a working directory pinned by
//! descriptor, inherited descriptors whose numbers collide, an open-file
//! limit, and the bounded wait without a pidfd.

use std::fs::File;
use std::io::Read;
use std::os::fd::{AsRawFd, OwnedFd};
use std::path::PathBuf;

use crate::fd::dup_above;
use crate::{Command, Stdio};

/// A new directory of its own under the temp directory, its path resolved
/// (macOS `/var` is `/private/var`), as `pwd -P` prints it.
fn new_directory(name: &str) -> PathBuf {
    let nanos =
        std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap().as_nanos();
    let path = std::env::temp_dir()
        .canonicalize()
        .unwrap()
        .join(format!("cmux-process-{name}-{}-{nanos}", std::process::id()));
    std::fs::create_dir(&path).unwrap();
    path
}

fn read_all(mut reader: impl Read) -> String {
    let mut text = String::new();
    reader.read_to_string(&mut text).unwrap();
    text
}

/// The child runs in the directory open at the descriptor, not at the path
/// the directory had when it was opened.
#[test]
fn current_dir_fd_follows_the_directory_through_a_rename() {
    let before = new_directory("cwd-before");
    let directory = File::open(&before).unwrap();
    let after =
        before.with_file_name(format!("{}-renamed", before.file_name().unwrap().to_string_lossy()));
    std::fs::rename(&before, &after).unwrap();

    let output = Command::new("/bin/sh")
        .args(["-c", "pwd -P"])
        .current_dir_fd(std::os::fd::AsFd::as_fd(&directory))
        .unwrap()
        .output()
        .unwrap();

    assert!(output.status.success(), "{output:?}");
    assert_eq!(String::from_utf8_lossy(&output.stdout).trim(), after.to_str().unwrap());
    std::fs::remove_dir(&after).unwrap();
}

/// The directory's descriptor number is also an inherited descriptor's
/// target, next to piped stdio: the child changes directory before that
/// number is replaced (macOS: the fchdir action runs before the dup2 ones;
/// Linux: fchdir runs first in the child setup).
#[test]
fn current_dir_fd_whose_number_is_an_inherited_target() {
    let directory_path = new_directory("cwd-target");
    let directory = dup_above(&OwnedFd::from(File::open(&directory_path).unwrap()), 500).unwrap();
    let number = directory.as_raw_fd();
    let (reader, writer) = std::io::pipe().unwrap();

    let mut command = Command::new("/bin/sh");
    command.args(["-c", &format!("pwd -P; printf x >/dev/fd/{number}")]).stdout(Stdio::piped());
    command.cwd_fd = Some(directory);
    command.inherit.push((OwnedFd::from(writer), number));
    let output = command.output().unwrap();
    drop(command);

    assert!(output.status.success(), "{output:?}");
    assert_eq!(String::from_utf8_lossy(&output.stdout).trim(), directory_path.to_str().unwrap());
    assert_eq!(read_all(reader), "x");
    std::fs::remove_dir(&directory_path).unwrap();
}

/// The second inherited descriptor's number is the first one's target. A
/// plain `dup2` per pair in order would replace it before it is passed on,
/// and the child would get the first descriptor at both numbers.
#[test]
fn an_inherited_source_numbered_as_an_earlier_target_still_reaches_the_child() {
    let (reader_a, writer_a) = std::io::pipe().unwrap();
    let (reader_b, writer_b) = std::io::pipe().unwrap();
    let a = dup_above(&OwnedFd::from(writer_a), 400).unwrap();
    let b = dup_above(&OwnedFd::from(writer_b), 400).unwrap();
    let first = b.as_raw_fd();
    let second = first + 1;

    let mut command = Command::new("/bin/sh");
    command.args(["-c", &format!("printf a >/dev/fd/{first}; printf b >/dev/fd/{second}")]);
    command.inherit.push((a, first));
    command.inherit.push((b, second));
    let status = command.status().unwrap();
    drop(command);

    assert!(status.success(), "{status:?}");
    assert_eq!(read_all(reader_a), "a");
    assert_eq!(read_all(reader_b), "b");
}

/// The child sees the soft open-file limit it was given (Linux: setrlimit
/// before the exec; macOS: the `ulimit` launcher).
#[test]
fn open_file_limit_sets_the_childs_soft_limit() {
    let output =
        Command::new("/bin/sh").args(["-c", "ulimit -S -n"]).open_file_limit(97).output().unwrap();
    assert!(output.status.success(), "{output:?}");
    assert_eq!(String::from_utf8_lossy(&output.stdout).trim(), "97");
}

/// A missing program still fails the spawn when the macOS launcher runs it.
#[test]
fn open_file_limit_keeps_a_missing_program_a_spawn_error() {
    let result =
        Command::new("/definitely/missing/cmux-process-program").open_file_limit(97).spawn();
    assert!(result.is_err(), "a missing program was started");
}

/// Where `pidfd_open` is denied (seccomp; ENOSYS before Linux 5.3) the
/// bounded wait still waits for the exit instead of failing.
#[cfg(target_os = "linux")]
#[test]
fn wait_timeout_without_pidfd_open_waits_for_the_exit() {
    use std::os::unix::process::ExitStatusExt;
    use std::time::{Duration, Instant};

    use crate::child_setup::tests::{deny, rerun};

    const CHILD: &str = "CMUX_PROCESS_NO_PIDFD_CHILD";
    if std::env::var_os(CHILD).is_none() {
        return rerun("tests::wait_timeout_without_pidfd_open_waits_for_the_exit", CHILD);
    }
    deny(&[libc::SYS_pidfd_open]);

    let mut child = Command::new("/bin/sleep").arg("30").spawn().unwrap();
    let started = Instant::now();
    assert!(child.wait_timeout(Duration::from_millis(100)).unwrap().is_none());
    assert!(started.elapsed() >= Duration::from_millis(100));
    assert!(child.wait_timeout(Duration::from_millis(20)).unwrap().is_none());
    child.kill().unwrap();
    let status = child.wait_timeout(Duration::from_secs(10)).unwrap().expect("killed child ended");
    assert_eq!(status.signal(), Some(libc::SIGKILL));

    let mut quick = Command::new("/bin/sh").args(["-c", "exit 3"]).spawn().unwrap();
    let status = quick.wait_timeout(Duration::from_secs(10)).unwrap().expect("child ended");
    assert_eq!(status.code(), Some(3));
}

/// Set for the child run of [`qos_report_child`].
#[cfg(target_vendor = "apple")]
const QOS_REPORT: &str = "CMUX_PROCESS_QOS_REPORT";

/// The child run of [`qos_sets_the_childs_class_and_leaves_the_spawning_thread_alone`]:
/// this test binary started again, printing the class it runs at. Its test
/// thread has the class of the process's first thread, which the spawn set
/// (a pthread created without a QoS attribute takes its creator's class,
/// sys/qos.h). Without the variable it does nothing.
#[cfg(target_vendor = "apple")]
#[test]
fn qos_report_child() {
    if std::env::var_os(QOS_REPORT).is_some() {
        println!("cmux-qos={:?}", cmux_threads::current());
    }
}

/// macOS: a child spawned from a UserInteractive thread with
/// `qos(USER_CHILD)` runs at Default and one with `qos(HELPER_CHILD)` at
/// Utility, while the spawning thread stays UserInteractive (the class goes
/// in the spawn attributes). One spawned without `qos` inherits
/// UserInteractive: the bug `qos` fixes (p02-threads 223). The child reports
/// its own class: a base priority does not tell Utility from Default on
/// every host.
#[cfg(target_vendor = "apple")]
#[test]
fn qos_sets_the_childs_class_and_leaves_the_spawning_thread_alone() {
    use cmux_threads::{HELPER_CHILD, LiveQos, QosChange, ThreadQos, USER_CHILD, current};

    let class_of_child = |qos: Option<ThreadQos>| {
        let mut command = Command::new(std::env::current_exe().unwrap());
        command
            .args(["--exact", "tests::qos_report_child", "--nocapture", "--test-threads=1"])
            .env(QOS_REPORT, "1");
        if let Some(qos) = qos {
            command.qos(qos);
        }
        let output = command.output().unwrap();
        assert_eq!(current(), LiveQos::Class(ThreadQos::UserInteractive));
        assert!(output.status.success(), "{output:?}");
        let stdout = String::from_utf8_lossy(&output.stdout).into_owned();
        stdout
            .lines()
            .find_map(|line| line.strip_prefix("cmux-qos="))
            .unwrap_or_else(|| panic!("no class report: {stdout}"))
            .to_owned()
    };
    let (user, helper, unset) = std::thread::spawn(move || {
        assert_eq!(cmux_threads::set_current(ThreadQos::UserInteractive), QosChange::Applied);
        (class_of_child(Some(USER_CHILD)), class_of_child(Some(HELPER_CHILD)), class_of_child(None))
    })
    .join()
    .unwrap();
    assert_eq!(user, format!("{:?}", LiveQos::Class(ThreadQos::Default)));
    assert_eq!(helper, format!("{:?}", LiveQos::Class(ThreadQos::Utility)));
    assert_eq!(
        unset,
        format!("{:?}", LiveQos::Class(ThreadQos::UserInteractive)),
        "a child without qos inherits the thread's class"
    );
}
