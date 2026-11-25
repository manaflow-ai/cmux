//! Windows: the detached owner leaves the Job Object of whoever runs
//! `server ensure`.

use std::io;
use std::os::windows::process::CommandExt;
use std::process::Child;

use super::{Command, OwnerSpec, set_owner_stdio};

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
    spawn: impl Fn(&mut Command) -> io::Result<Child>,
) -> io::Result<Child> {
    const ERROR_ACCESS_DENIED: i32 = 5;
    const DETACHED_PROCESS: u32 = 0x0000_0008;
    const CREATE_NEW_PROCESS_GROUP: u32 = 0x0000_0200;
    const CREATE_BREAKAWAY_FROM_JOB: u32 = 0x0100_0000;
    let flags = DETACHED_PROCESS | CREATE_NEW_PROCESS_GROUP;
    set_owner_stdio(command, spec);
    match spawn(command.creation_flags(flags | CREATE_BREAKAWAY_FROM_JOB)) {
        Err(error) if error.raw_os_error() == Some(ERROR_ACCESS_DENIED) => {
            set_owner_stdio(command, spec);
            spawn(command.creation_flags(flags))
        }
        spawned => spawned,
    }
}
