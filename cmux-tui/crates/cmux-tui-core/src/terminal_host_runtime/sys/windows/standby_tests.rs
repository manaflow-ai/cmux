//! Tests of `standby.rs`. The stand-in host is this test binary running
//! [`host_helper`]: it opens the bootstrap pipes like a host and answers
//! line commands.

use super::*;
use std::io::{BufRead, BufReader, Write};
use std::path::PathBuf;

use windows_sys::Win32::Foundation::{
    GetHandleInformation, HANDLE_FLAG_INHERIT, SetHandleInformation,
};
use windows_sys::Win32::Storage::FileSystem::GetFinalPathNameByHandleW;

const HELPER: &str = "terminal_host_runtime::sys::windows::standby::tests::host_helper";

fn system32(exe: &str) -> PathBuf {
    let root = std::env::var("SystemRoot").unwrap_or_else(|_| r"C:\Windows".into());
    PathBuf::from(root).join("System32").join(exe)
}

/// Breakaway when this runner allows it. The hosted Windows runner runs
/// tests in a job that forbids breakaway (run 37935857605); there the
/// hook-taking tests start their host inside the runner's job.
fn test_breakaway() -> Breakaway {
    if breakaway_allowed().unwrap() { Breakaway::Required } else { Breakaway::Stay }
}

fn helper_args() -> [&'static str; 4] {
    ["--exact", HELPER, "--ignored", "--test-threads=1"]
}

fn stand_in_host() -> HostProcess {
    spawn_host_process(&std::env::current_exe().unwrap(), &helper_args()).unwrap()
}

fn ask(host: &mut HostProcess, reader: &mut BufReader<File>, line: &str) -> String {
    writeln!(host.stdin.as_mut().unwrap(), "{line}").unwrap();
    let mut answer = String::new();
    reader.read_line(&mut answer).unwrap();
    answer.trim_end().to_owned()
}

#[test]
fn arguments_are_quoted_by_the_msvc_rules() {
    assert_eq!(quote_arg("--bootstrap-stdio"), "--bootstrap-stdio");
    assert_eq!(quote_arg(""), "\"\"");
    assert_eq!(quote_arg("a b"), "\"a b\"");
    assert_eq!(quote_arg(r#"say "hi""#), r#""say \"hi\"""#);
    assert_eq!(quote_arg(r"C:\dir with space\"), r#""C:\dir with space\\""#);
}

#[test]
fn only_our_random_pipe_names_are_bootstrap_names() {
    let name = random_base_name().unwrap();
    assert!(valid_base_name(&name), "{name}");
    assert_ne!(name, random_base_name().unwrap());
    assert!(!valid_base_name(r"\\.\pipe\other"));
    assert!(!valid_base_name(&format!("{name}x")));
    assert!(!valid_base_name(r"\\.\pipe\cmux-th-boot-..\..\x0000000000000000000000000"));
}

/// The host talks to the daemon over its two bootstrap pipes.
#[test]
fn a_host_process_gets_its_bootstrap_pipes() {
    let mut host = stand_in_host();
    let mut reader = BufReader::new(host.stdout.take().unwrap());
    assert_eq!(ask(&mut host, &mut reader, "echo hello host"), "hello host");
    // The daemon's ends are not inheritable: no later spawn gets them.
    for end in [host.stdin.as_ref().unwrap(), reader.get_ref()] {
        let mut flags = 0u32;
        // SAFETY: a handle owned by `end`.
        assert_ne!(unsafe { GetHandleInformation(end.as_raw_handle() as HANDLE, &mut flags) }, 0);
        assert_eq!(flags & HANDLE_FLAG_INHERIT, 0, "a daemon-side pipe end is inheritable");
    }
    host.stdin.take();
    assert!(host.wait_timeout(Duration::from_secs(10)), "the host exits at EOF");
}

/// The host inherits no handle: one made inheritable in the daemon (as a
/// careless spawn elsewhere would) is not open in the host.
#[test]
fn the_host_inherits_no_handle_of_the_daemon() {
    let name =
        format!("cmux-inheritable-probe-{}", &random_base_name().unwrap()[PIPE_PREFIX.len()..]);
    let path = std::env::temp_dir().join(&name);
    let probe = File::create(&path).unwrap();
    // SAFETY: a handle owned by `probe`.
    let marked = unsafe {
        SetHandleInformation(
            probe.as_raw_handle() as HANDLE,
            HANDLE_FLAG_INHERIT,
            HANDLE_FLAG_INHERIT,
        )
    };
    assert_ne!(marked, 0);
    let mut host = stand_in_host();
    let mut reader = BufReader::new(host.stdout.take().unwrap());
    let answer =
        ask(&mut host, &mut reader, &format!("probe {} {name}", probe.as_raw_handle() as usize));
    assert_eq!(answer, "hidden", "the host can use the daemon's inheritable handle");
    // The probe is real: the helper's check finds a handle it opened itself.
    let answer = ask(&mut host, &mut reader, &format!("self-probe {name}-self"));
    assert_eq!(answer, "visible", "the helper's check does not see a real handle");
    drop(host);
    drop(probe);
    let _ = std::fs::remove_file(&path);
}

#[test]
fn dropping_an_unused_host_ends_that_process() {
    let host = stand_in_host();
    let pid = host.pid();
    assert!(host.is_alive());
    drop(host);
    let exists = std::process::Command::new(system32("tasklist.exe"))
        .args(["/fi", &format!("PID eq {pid}"), "/nh"])
        .output()
        .unwrap();
    assert!(
        !String::from_utf8_lossy(&exists.stdout).contains(&pid.to_string()),
        "host {pid} still runs"
    );
}

/// Another process (here the test runner) that opens a bootstrap pipe
/// before the host is refused, and the host is ended.
#[test]
fn a_pipe_opened_by_another_process_is_refused() {
    let exe = std::env::current_exe().unwrap();
    let breakaway = test_breakaway();
    let mut squatter = None;
    let result = spawn_host_process_with(&exe, &helper_args(), breakaway, |base| {
        squatter = Some(OpenOptions::new().read(true).open(format!("{base}.in")).unwrap());
    });
    match result {
        Err(HostSpawnError::Io(error)) => {
            assert_eq!(error.kind(), io::ErrorKind::PermissionDenied, "{error}");
        }
        other => panic!("expected a refusal, got {other:?}"),
    }
    drop(squatter);
}

/// A host that ends without opening its pipes does not block the daemon.
#[test]
fn a_host_that_never_connects_is_refused() {
    let cmd = system32("cmd.exe");
    let args = ["/d", "/c", "exit", "0"];
    let breakaway = test_breakaway();
    let started = std::time::Instant::now();
    let result = spawn_host_process_with(&cmd, &args, breakaway, |_| {});
    assert!(result.is_err(), "{result:?}");
    assert!(started.elapsed() < CONNECT_TIMEOUT, "waited for the timeout, not the exit");
}

const JOB_HELPER_ENV: &str = "CMUX_TEST_STANDBY_BREAKAWAY_HELPER";

/// Runs `helper_in_a_job_without_breakaway` in a child test process with
/// `mode` (`plain` or `kill-on-close`); it puts itself in such a job (the
/// test runner stays out).
fn run_job_helper(mode: &str) {
    let output = std::process::Command::new(std::env::current_exe().unwrap())
        .args([
            "--exact",
            "terminal_host_runtime::sys::windows::standby::tests::helper_in_a_job_without_breakaway",
            "--ignored",
            "--nocapture",
            "--test-threads=1",
        ])
        .env(JOB_HELPER_ENV, mode)
        .output()
        .unwrap();
    let text = format!(
        "{}{}",
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    );
    assert!(output.status.success(), "{text}");
    assert!(text.contains("1 passed"), "the helper did not run: {text}");
}

/// A job without breakaway and without kill-on-close: breakaway is denied,
/// the host starts inside the job, and it does not end with the job's
/// owner (no notice).
#[test]
fn a_job_without_breakaway_keeps_the_host_inside_it() {
    run_job_helper("plain");
}

/// The same in a kill-on-close job: the host starts inside it and says it
/// ends with that job (the notice).
#[test]
fn a_kill_on_close_job_without_breakaway_marks_the_host() {
    run_job_helper("kill-on-close");
}

#[test]
#[ignore = "run by the job tests in its own process"]
fn helper_in_a_job_without_breakaway() {
    let Some(mode) = std::env::var_os(JOB_HELPER_ENV) else {
        return;
    };
    let kill_on_close = mode == "kill-on-close";
    use windows_sys::Win32::System::JobObjects::{
        AssignProcessToJobObject, CreateJobObjectW, JOBOBJECT_EXTENDED_LIMIT_INFORMATION,
        JobObjectExtendedLimitInformation, SetInformationJobObject,
    };
    // SAFETY: an unnamed job without BREAKAWAY_OK; this helper process puts
    // itself in it and never closes it.
    let job = unsafe {
        let job = CreateJobObjectW(ptr::null(), ptr::null());
        assert!(!job.is_null(), "{}", io::Error::last_os_error());
        if kill_on_close {
            let mut limits: JOBOBJECT_EXTENDED_LIMIT_INFORMATION = std::mem::zeroed();
            limits.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
            assert_ne!(
                SetInformationJobObject(
                    job,
                    JobObjectExtendedLimitInformation,
                    (&raw const limits).cast(),
                    size_of::<JOBOBJECT_EXTENDED_LIMIT_INFORMATION>() as u32,
                ),
                0,
                "{}",
                io::Error::last_os_error()
            );
        }
        assert_ne!(
            AssignProcessToJobObject(job, GetCurrentProcess()),
            0,
            "{}",
            io::Error::last_os_error()
        );
        job
    };
    assert!(in_job().unwrap());
    assert!(!breakaway_allowed().unwrap());
    assert_eq!(job_kills_on_close().unwrap(), kill_on_close);
    let exe = std::env::current_exe().unwrap();
    match spawn_host_process_with(&exe, &helper_args(), Breakaway::Required, |_| {}) {
        Err(HostSpawnError::BreakawayDenied) => {}
        other => panic!("expected BreakawayDenied, got {other:?}"),
    }
    let mut host = spawn_host_process(&exe, &helper_args()).expect("a host inside the job");
    assert_eq!(host.ends_with_daemon_job(), kill_on_close);
    let mut inside = 0;
    // SAFETY: the host's process handle and our job handle.
    unsafe { IsProcessInJob(host.process.as_raw_handle() as HANDLE, job, &mut inside) };
    assert_ne!(inside, 0, "the host is not in the daemon's job");
    let mut reader = BufReader::new(host.stdout.take().unwrap());
    assert_eq!(ask(&mut host, &mut reader, "echo inside"), "inside");
}

/// Whether `handle` (a value in this process) is open on a file whose path
/// ends with `name`.
fn handle_names_file(handle: usize, name: &str) -> bool {
    let mut flags = 0u32;
    // SAFETY: a query on any value; an invalid one fails.
    if unsafe { GetHandleInformation(handle as HANDLE, &mut flags) } == 0 {
        return false;
    }
    let mut path = vec![0u16; 1024];
    // SAFETY: a buffer of the given length.
    let len =
        unsafe { GetFinalPathNameByHandleW(handle as HANDLE, path.as_mut_ptr(), 1024, 0) } as usize;
    len > 0 && len < path.len() && String::from_utf16_lossy(&path[..len]).ends_with(name)
}

/// The stand-in host: opens the bootstrap pipes named by its last argument
/// and answers `echo <text>`, `probe <handle> <file name>` (is that handle
/// value open on that file here) and `self-probe <file name>` (creates that
/// file in its temp dir and probes its own handle: the check works) until
/// EOF.
#[test]
#[ignore = "run as a stand-in host by the spawn tests"]
fn host_helper() {
    let Some(base) = std::env::args().last().filter(|arg| valid_base_name(arg)) else {
        return;
    };
    let (input, mut output) = open_bootstrap_pipes(&base).unwrap();
    let mut kept = Vec::new();
    for line in BufReader::new(input).lines() {
        let line = line.unwrap();
        let answer = if let Some(text) = line.strip_prefix("echo ") {
            text.to_owned()
        } else if let Some(rest) = line.strip_prefix("probe ") {
            let (handle, name) = rest.split_once(' ').unwrap();
            if handle_names_file(handle.parse().unwrap(), name) { "visible" } else { "hidden" }
                .to_owned()
        } else if let Some(name) = line.strip_prefix("self-probe ") {
            let own = std::env::temp_dir().join(name);
            let file = File::create(&own).unwrap();
            let seen = handle_names_file(file.as_raw_handle() as usize, name);
            kept.push((file, own));
            if seen { "visible" } else { "hidden" }.to_owned()
        } else {
            format!("unknown {line}")
        };
        writeln!(output, "{answer}").unwrap();
    }
    for (file, path) in kept {
        drop(file);
        let _ = std::fs::remove_file(path);
    }
}
