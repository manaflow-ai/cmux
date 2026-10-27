//! Windows: the detached owner leaves the Job Object of whoever runs
//! `server ensure`.

use std::io;

use cmux_process::Command;

use super::{OwnerSpec, set_owner_stdio};

/// Starts the owner with no console and as the root of its own process
/// group, outside the Job Object of whoever runs `server ensure`
/// (`CREATE_BREAKAWAY_FROM_JOB`), as the terminal host
/// (`terminal_host_runtime/sys/windows/standby.rs`) and acpmux's daemon
/// (`acpmux/src/daemon/windows.rs`) leave the daemon's. `DETACHED_PROCESS`
/// only drops the console: an owner left in the launcher's job dies when a
/// job that kills its processes on close closes (an ssh or IAP session, a
/// scheduled task, an IDE or terminal), and leaves its socket file and
/// `.spawn-lock` with nothing listening, so every later connect is refused
/// (WSAECONNREFUSED). A job that does not allow breakaway refuses the flag
/// with `ERROR_ACCESS_DENIED`; the owner then starts inside it, as before,
/// and lives as long as that job.
pub(super) fn spawn_owner_out_of_callers_job(
    command: &mut Command,
    spec: &OwnerSpec,
) -> io::Result<cmux_process::Child> {
    use windows_sys::Win32::Foundation::ERROR_ACCESS_DENIED;
    use windows_sys::Win32::System::Threading::{
        CREATE_BREAKAWAY_FROM_JOB, CREATE_NEW_PROCESS_GROUP, DETACHED_PROCESS,
    };
    let flags = DETACHED_PROCESS | CREATE_NEW_PROCESS_GROUP;
    set_owner_stdio(command, spec);
    match command.creation_flags(flags | CREATE_BREAKAWAY_FROM_JOB).spawn() {
        Err(error) if error.raw_os_error() == Some(ERROR_ACCESS_DENIED as i32) => {
            set_owner_stdio(command, spec);
            command.creation_flags(flags).spawn()
        }
        spawned => spawned,
    }
}
