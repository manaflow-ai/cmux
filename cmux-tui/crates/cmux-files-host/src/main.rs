//! `cmux-files-host`: see the crate docs and docs/cmux-files-host.md.

use cmux_files_host::{EXECUTABLE, Invocation, REFUSED_STATUS};
use cmux_process::{Child, Command, Stdio};
use std::ffi::OsString;
use std::path::{Path, PathBuf};
use std::process::ExitCode;

fn main() -> ExitCode {
    let args: Vec<OsString> = std::env::args_os().skip(1).collect();
    match cmux_files_host::parse(&args) {
        Invocation::LaunchServicesOpen => ExitCode::SUCCESS,
        Invocation::Usage => {
            eprintln!("usage: {EXECUTABLE} run|host -- PROGRAM [ARGS...]");
            ExitCode::from(2)
        }
        Invocation::Run(program) => match launch_host(&program) {
            Ok(status) => status,
            Err(reason) => {
                eprintln!("{EXECUTABLE}: {reason}; running the program without cmux Files");
                exec_program(&program)
            }
        },
        Invocation::Host(program) => host(&program),
    }
}

/// The launcher: stage this bundle outside the app, start the staged copy as the host with
/// responsibility disclaimed, and wait for it. An error leaves every descriptor open, so the
/// caller can still run the program in place.
fn launch_host(program: &[OsString]) -> Result<ExitCode, String> {
    let own = std::env::current_exe().map_err(|error| format!("no executable path: {error}"))?;
    let first = program.first().ok_or("no program")?;
    if cmux_files_host::allowed_program(first, &own).is_none() {
        return Err(format!("{} is not from this DEV build", first.to_string_lossy()));
    }
    let bundle = cmux_files_host::own_bundle(&own).ok_or("not inside its bundle")?;
    let host = if cmux_files_host::nested_in_app(&bundle) {
        let home = std::env::var_os("HOME").map(PathBuf::from).ok_or("no HOME")?;
        let requirement = cmux_files_host::requirement();
        cmux_files_host::stage(&bundle, &cmux_files_host::staging_root(&home), |copy| {
            cmux_signed_bundle::verify(copy, &requirement)
        })?
    } else {
        own
    };
    let mut command = Command::new(&host);
    command.arg("host").arg("--").args(program).disclaim_responsibility();
    let descriptors = pass_descriptors(&mut command)?;
    let mut child =
        command.spawn().map_err(|error| format!("cannot start {}: {error}", host.display()))?;
    close(&descriptors);
    Ok(supervise(&mut child, None))
}

/// The host: run the program (from a DEV build that embeds these same bytes) as its child, in
/// its own session as the daemon was before, and wait for it.
fn host(program: &[OsString]) -> ExitCode {
    let refuse = |reason: String| {
        eprintln!("{EXECUTABLE}: {reason}");
        ExitCode::from(REFUSED_STATUS as u8)
    };
    let own = match std::env::current_exe() {
        Ok(own) => own,
        Err(error) => return refuse(format!("no executable path: {error}")),
    };
    let Some((first, rest)) = program.split_first() else { return refuse("no program".into()) };
    let Some(canonical) = cmux_files_host::allowed_program(first, &own) else {
        return refuse(format!(
            "refused {}: only a program of a DEV build that embeds this helper runs here",
            first.to_string_lossy()
        ));
    };
    let parent = parent_pid();
    let mut command = Command::new(&canonical);
    command.arg0(first).args(rest).new_session();
    let descriptors = match pass_descriptors(&mut command) {
        Ok(descriptors) => descriptors,
        Err(reason) => return refuse(reason),
    };
    match command.spawn() {
        Ok(mut child) => {
            close(&descriptors);
            supervise(&mut child, Some(parent))
        }
        Err(error) => {
            eprintln!("{EXECUTABLE}: cannot run {}: {error}", canonical.display());
            ExitCode::from(127)
        }
    }
}

/// Runs the program in place of this process (the launcher's fallback: as cmux ran it before);
/// returns only when it cannot.
fn exec_program(program: &[OsString]) -> ExitCode {
    let Some(first) = program.first() else { return ExitCode::from(2) };
    let error = cmux_files_host::exec_in_place(program);
    eprintln!("{EXECUTABLE}: cannot run {}: {error}", Path::new(first).display());
    ExitCode::from(127)
}

/// Gives the child every descriptor above 2 this process was given, at the same number, and
/// stdin, stdout and stderr as they are.
fn pass_descriptors(command: &mut Command) -> Result<Vec<i32>, String> {
    use std::os::fd::BorrowedFd;
    command.stdin(Stdio::inherit()).stdout(Stdio::inherit()).stderr(Stdio::inherit());
    let descriptors = cmux_files_host::inherited_descriptors();
    for fd in &descriptors {
        // SAFETY: the descriptor is open (inherited_descriptors checked it) and stays open until
        // `close` after the spawn; the builder only duplicates it.
        let borrowed = unsafe { BorrowedFd::borrow_raw(*fd) };
        command.inherit_fd(borrowed, *fd).map_err(|error| format!("descriptor {fd}: {error}"))?;
    }
    Ok(descriptors)
}

/// Closes this process's copies once the child holds them: end of file on a readiness pipe
/// then still means the program exited.
fn close(descriptors: &[i32]) {
    for fd in descriptors {
        // SAFETY: descriptors this process owns and no longer uses.
        unsafe { libc::close(*fd) };
    }
}

fn parent_pid() -> libc::pid_t {
    // SAFETY: getppid has no preconditions.
    unsafe { libc::getppid() }
}

/// Waits for the child, passing on the forwarded signals and, with `parent`, killing it when
/// that process exits first. Returns the child's status (128 + signal for a signal).
fn supervise(child: &mut Child, parent: Option<libc::pid_t>) -> ExitCode {
    // The child's group is the program's own (its session, or the host's group): it must outlive
    // nothing here, but a drop must never kill the group of a daemon that handed its terminals on.
    child.detach("the launcher and the host only wait for their one child");
    #[cfg(target_os = "macos")]
    watch(child.id() as libc::pid_t, parent);
    #[cfg(not(target_os = "macos"))]
    let _ = parent;
    let status = loop {
        match child.wait() {
            Ok(status) => break status,
            Err(error) if error.kind() == std::io::ErrorKind::Interrupted => {}
            Err(error) => {
                eprintln!("{EXECUTABLE}: cannot wait for the program: {error}");
                return ExitCode::from(1);
            }
        }
    };
    use std::os::unix::process::ExitStatusExt;
    let code = status.code().or_else(|| status.signal().map(|signal| 128 + signal)).unwrap_or(1);
    ExitCode::from(u8::try_from(code).unwrap_or(1))
}

/// Blocks until the child exits: forwards [`cmux_files_host::FORWARDED_SIGNALS`] (ignored here,
/// seen through kqueue, set only after the spawn so the child keeps their defaults) and kills the
/// child when `parent` exits first.
#[cfg(target_os = "macos")]
fn watch(child: libc::pid_t, parent: Option<libc::pid_t>) {
    // SAFETY: kqueue has no preconditions; the descriptor is closed below.
    let queue = unsafe { libc::kqueue() };
    if queue < 0 {
        return;
    }
    let event = |ident: usize, filter: i16, fflags: u32| libc::kevent {
        ident,
        filter,
        flags: libc::EV_ADD | libc::EV_ENABLE,
        fflags,
        data: 0,
        udata: std::ptr::null_mut(),
    };
    let register = |change: libc::kevent| {
        // SAFETY: one valid change, no events out.
        let result = unsafe {
            libc::kevent(queue, &raw const change, 1, std::ptr::null_mut(), 0, std::ptr::null())
        };
        result == 0
    };
    if !register(event(child as usize, libc::EVFILT_PROC, libc::NOTE_EXIT)) {
        // Already exited: the caller's wait returns at once.
        // SAFETY: closes the queue opened above.
        unsafe { libc::close(queue) };
        return;
    }
    for signal in cmux_files_host::FORWARDED_SIGNALS {
        // SAFETY: SIG_IGN for a catchable signal; kqueue still records each delivery.
        unsafe { libc::signal(signal, libc::SIG_IGN) };
        register(event(signal as usize, libc::EVFILT_SIGNAL, 0));
    }
    if let Some(parent) = parent
        && (parent <= 1 || !register(event(parent as usize, libc::EVFILT_PROC, libc::NOTE_EXIT)))
    {
        // The process that waits for this one is already gone.
        // SAFETY: a signal to our own child.
        unsafe { libc::kill(child, libc::SIGKILL) };
    }
    loop {
        // SAFETY: a zeroed kevent is a valid out buffer.
        let mut out: libc::kevent = unsafe { std::mem::zeroed() };
        // SAFETY: one out event, no changes, no timeout.
        let count =
            unsafe { libc::kevent(queue, std::ptr::null(), 0, &raw mut out, 1, std::ptr::null()) };
        if count < 0 {
            if std::io::Error::last_os_error().kind() == std::io::ErrorKind::Interrupted {
                continue;
            }
            break;
        }
        if count == 0 {
            continue;
        }
        if out.filter == libc::EVFILT_SIGNAL {
            // SAFETY: passes the signal on to our own child.
            unsafe { libc::kill(child, out.ident as libc::c_int) };
        } else if out.ident == child as usize {
            break;
        } else {
            // The parent exited before the child: end the child as that parent would have.
            // SAFETY: a signal to our own child.
            unsafe { libc::kill(child, libc::SIGKILL) };
        }
    }
    // SAFETY: closes the queue opened above.
    unsafe { libc::close(queue) };
}
