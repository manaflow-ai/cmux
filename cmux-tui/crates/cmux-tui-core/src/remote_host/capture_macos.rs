//! Native observations for the daemon capture boundary. No PID-only kill or socket-close proof.
use super::capture_lease::{Binding, Stamp};
use super::{Connection, platform};
use std::ffi::CStr;
use std::time::{Duration, Instant};

pub(super) fn validate_app(
    binding: &Binding,
    app: Stamp,
    peer: Option<cmux_link::app_caller::PeerToken>,
) -> Result<(), String> {
    let same = || platform::process_start(app.pid) == Some((app.start_sec, app.start_usec));
    if !same() {
        return Err("remote_app_unverified".into());
    }
    // Resolve only the retained socket audit token. PID reuse and exec invalidate it.
    let executable = cmux_link::app_caller::executable_path(&peer.ok_or("remote_app_unverified")?)
        .ok_or("remote_app_unverified")?;
    let bundle = executable
        .ancestors()
        .find(|path| path.extension().is_some_and(|ext| ext == "app"))
        .ok_or("remote_app_unverified")?;
    if platform::bundle_id(bundle).as_deref() != Some(binding.bundle_id.as_str()) || !same() {
        return Err("remote_app_mismatch".into());
    }
    // getpwuid_r reads the login HOME, independently of the capture's HOME override.
    let mut password: libc::passwd = unsafe { std::mem::zeroed() };
    let mut storage = vec![0_i8; 16_384];
    let mut result = std::ptr::null_mut();
    // SAFETY: all output pointers refer to owned buffers kept alive through the CStr read.
    let status = unsafe {
        libc::getpwuid_r(
            libc::geteuid(),
            &mut password,
            storage.as_mut_ptr(),
            storage.len(),
            &mut result,
        )
    };
    if status != 0 || result.is_null() || password.pw_dir.is_null() {
        return Err("remote_private_home_unverified".into());
    }
    // SAFETY: getpwuid_r succeeded and pw_dir points into storage.
    let login = unsafe { CStr::from_ptr(password.pw_dir) }
        .to_str()
        .map_err(|_| "remote_private_home_unverified")?;
    if binding.private_root == std::path::Path::new(login) {
        return Err("remote_private_home_unverified".into());
    }
    Ok(())
}

/// Unknown process metadata never authorizes losing the sole adoption record.
pub(super) fn record_exited(record: &super::HostRecord) -> bool {
    if let Some(stamp) = platform::process_start(record.pid) {
        return stamp != (record.start_sec, record.start_usec);
    }
    // SAFETY: signal zero observes the recorded PID without signalling it.
    (unsafe { libc::kill(record.pid as i32, 0) }) != 0
        && std::io::Error::last_os_error().raw_os_error() == Some(libc::ESRCH)
}

pub(super) fn drain_and_verify(connection: &Connection) -> Result<(), String> {
    let stamp = Stamp::of_record(&connection.record);
    if platform::process_start(stamp.pid) != Some((stamp.start_sec, stamp.start_usec)) {
        return Err("remote_host_identity_unverified".into());
    }
    // A host is created as its own session/group leader; workers inherit that owned group.
    // SAFETY: getpgid is a read of the already stamped process.
    if unsafe { libc::getpgid(stamp.pid as i32) } != stamp.pid as i32 {
        return Err("remote_host_group_unverified".into());
    }
    wait_exit(connection, stamp)?;
    group_absent(stamp.pid)
}

pub(super) fn group_absent(pid: u32) -> Result<(), String> {
    let group = i32::try_from(pid)
        .ok()
        .filter(|group| *group > 1)
        .ok_or("remote_descendants_unverified")?;
    // SAFETY: signal zero only queries the group recorded when our host was spawned.
    // No process enumeration or signal is sent. A lingering zombie conservatively holds admission.
    let result = if unsafe { libc::kill(-group, 0) } == 0 {
        Ok(())
    } else {
        Err(std::io::Error::last_os_error().raw_os_error().unwrap_or(0))
    };
    super::capture::group_absence(result)
}

fn wait_exit(connection: &Connection, stamp: Stamp) -> Result<(), String> {
    // SAFETY: kqueue/kevent use initialized owned structures and an owned descriptor, closed below.
    unsafe {
        let queue = libc::kqueue();
        if queue < 0 {
            return Err("remote_exit_unverified".into());
        }
        let result: Result<(), &str> = (|| {
            let mut change: libc::kevent = std::mem::zeroed();
            change.ident = stamp.pid as libc::uintptr_t;
            change.filter = libc::EVFILT_PROC;
            change.flags = libc::EV_ADD | libc::EV_ONESHOT | libc::EV_RECEIPT;
            change.fflags = libc::NOTE_EXIT;
            let mut event: libc::kevent = std::mem::zeroed();
            if libc::kevent(queue, &change, 1, &mut event, 1, std::ptr::null()) != 1
                || event.flags & libc::EV_ERROR != 0 && event.data != 0
                || platform::process_start(stamp.pid) != Some((stamp.start_sec, stamp.start_usec))
            {
                return Err("remote_exit_unverified");
            }
            connection.notify("drain");
            let deadline = Instant::now() + Duration::from_secs(15);
            loop {
                let remaining = deadline.saturating_duration_since(Instant::now());
                if remaining.is_zero() {
                    return Err("remote_exit_timeout");
                }
                let timeout = libc::timespec {
                    tv_sec: remaining.as_secs() as _,
                    tv_nsec: remaining.subsec_nanos() as _,
                };
                let ready = libc::kevent(queue, std::ptr::null(), 0, &mut event, 1, &timeout);
                if ready == 1
                    && event.flags & libc::EV_ERROR == 0
                    && event.fflags & libc::NOTE_EXIT != 0
                {
                    return Ok(());
                }
                if ready == 0 {
                    return Err("remote_exit_timeout");
                }
                if ready < 0
                    && std::io::Error::last_os_error().kind() == std::io::ErrorKind::Interrupted
                {
                    continue;
                }
                return Err("remote_exit_unverified");
            }
        })();
        libc::close(queue);
        result.map_err(str::to_string)
    }
}
