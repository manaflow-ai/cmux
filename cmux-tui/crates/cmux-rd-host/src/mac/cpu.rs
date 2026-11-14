//! Exact-PID benchmark accounting. No process scans or permission changes.
use crate::process_cpu::{interval, Sample};

fn sample(pid: i32) -> Result<Sample, &'static str> {
    if pid <= 0 {
        return Err("invalid_pid");
    }
    let mut usage = std::mem::MaybeUninit::<libc::rusage_info_v0>::zeroed();
    // SAFETY: V0 writes precisely rusage_info_v0 into the aligned writable buffer.
    let status =
        unsafe { libc::proc_pid_rusage(pid, libc::RUSAGE_INFO_V0, usage.as_mut_ptr().cast()) };
    if status != 0 {
        return Err(match std::io::Error::last_os_error().raw_os_error() {
            Some(libc::EPERM | libc::EACCES) => "permission_denied",
            Some(libc::ESRCH) => "process_gone",
            _ => "process_usage_unavailable",
        });
    }
    // SAFETY: all integer fields initialized by the successful V0 call.
    let usage = unsafe { usage.assume_init() };
    if usage.ri_proc_exit_abstime != 0 {
        return Err("process_gone");
    }
    if usage.ri_proc_start_abstime == 0 {
        return Err("unknown_process_start");
    }
    Ok(Sample {
        pid,
        start_abstime: usage.ri_proc_start_abstime,
        cpu_ns: usage
            .ri_user_time
            .checked_add(usage.ri_system_time)
            .ok_or("cpu_counter_overflow")?,
        sampled_ns: crate::clock::now_ns(),
    })
}

/// Standalone benchmark command; endpoint attribution is always explicit.
pub fn run(opts: &crate::args::Opts) -> crate::Res<()> {
    let pid = opts.num_or::<i32>("pid", 0)?;
    let duration_ms = opts.num_or::<u64>("duration-ms", 1000)?;
    if pid <= 0 || !(1..=60_000).contains(&duration_ms) {
        return Err("observe-cpu requires --pid >0 and --duration-ms 1..60000".into());
    }
    let own_pid = std::process::id() as i32;
    let before = sample(pid);
    let observer_before = sample(own_pid);
    // Standalone measurement command, never called on an app/main-thread path.
    std::thread::sleep(std::time::Duration::from_millis(duration_ms));
    let after = sample(pid);
    let observer_after = sample(own_pid);
    println!(
        "{}",
        serde_json::json!({
            "schema": "cmux.process-cpu-interval/1",
            "pid": pid,
            "duration_ms_requested": duration_ms,
            "viewer": interval(before, after),
            "observer_pid": own_pid,
            "observer": interval(observer_before, observer_after),
            "host_cpu_pct": null,
            "unit": "percent of one CPU core; user plus system time",
        })
    );
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn process_cpu_native_self_and_child_identity() {
        let first = sample(std::process::id() as i32).expect("self usage");
        let second = sample(std::process::id() as i32).expect("self usage");
        assert_eq!(first.start_abstime, second.start_abstime);
        assert!(second.cpu_ns >= first.cpu_ns);
        assert!(interval(Ok(first), Ok(second)).cpu_pct.is_some());
        let mut child =
            std::process::Command::new("/bin/sleep").arg("0.2").spawn().expect("owned child");
        let pid = child.id() as i32;
        let usage = sample(pid);
        child.wait().expect("reap owned child");
        assert_eq!(usage.expect("child usage").pid, pid);
        assert!(sample(pid).is_err());
        assert!(sample(-1).is_err());
    }
}
