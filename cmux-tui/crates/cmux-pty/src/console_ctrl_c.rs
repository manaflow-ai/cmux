//! Windows: a terminal's child processes Ctrl+C.
//!
//! ConPTY turns a 0x03 input byte (from a key press or a raw write) into a
//! Ctrl+C key, and the pseudoconsole, in processed input mode (the default
//! console mode), turns that key into a `CTRL_C_EVENT` for every process
//! attached to it. A process skips that event, its handlers included, while
//! its "ignore Ctrl+C" attribute is set, and a new process starts with the
//! attribute of the process that created it (`SetConsoleCtrlHandler`: "This
//! attribute of ignoring or processing CTRL+C is inherited by child
//! processes"). `CREATE_NEW_PROCESS_GROUP` sets the attribute in the new
//! process ("an implicit call to SetConsoleCtrlHandler(NULL,TRUE) is made on
//! behalf of the new process", `CreateProcessW` remarks).
//!
//! The terminal owner (`local_owner.rs`, `DETACHED_PROCESS |
//! CREATE_NEW_PROCESS_GROUP`) and the terminal host (`standby.rs`,
//! `CREATE_NO_WINDOW | CREATE_NEW_PROCESS_GROUP`) start in a new group, so
//! they ignore Ctrl+C, and portable-pty's `CreateProcessW` passes that on to
//! the shell; the shell passes it on to every command it runs. Ctrl+C then
//! stopped nothing (`ping -t` ran on, under cmd.exe and pwsh alike).
//!
//! The fix is the Windows side of the Unix child's signal reset (`macos.rs`):
//! right before each PTY spawn the spawning process clears the attribute, so
//! the child starts processing Ctrl+C however the spawning process started.
//! The spawning process then processes Ctrl+C too, which changes nothing it
//! can see: the owner has no console (`DETACHED_PROCESS`), and the host's
//! console has no window and no input, so neither ever gets a Ctrl+C. Ctrl+C
//! reaches only the processes attached to the pseudoconsole, the child tree.

/// Whether the PTY spawn leaves the spawning process ignoring Ctrl+C right
/// before it creates the child, which inherits the attribute: never.
const PTY_SPAWNER_IGNORES_CTRL_C: bool = false;

/// The `Add` argument of `SetConsoleCtrlHandler(NULL, Add)` that gives the
/// calling process `ignore`: TRUE ignores Ctrl+C, FALSE restores normal
/// processing.
const fn null_handler_add_argument(ignore: bool) -> i32 {
    ignore as i32
}

/// Clear the calling process's ignore-Ctrl+C attribute, for the child it
/// creates next to inherit. With a null routine the call only sets the
/// attribute; it needs no console.
#[cfg(windows)]
pub(crate) fn set_for_the_next_child() -> std::io::Result<()> {
    use windows_sys::Win32::System::Console::SetConsoleCtrlHandler;

    let add = null_handler_add_argument(PTY_SPAWNER_IGNORES_CTRL_C);
    // SAFETY: a null handler routine registers nothing; the call only sets
    // this process's ignore-Ctrl+C attribute.
    if unsafe { SetConsoleCtrlHandler(None, add) } == 0 {
        Err(std::io::Error::last_os_error())
    } else {
        Ok(())
    }
}

#[cfg(test)]
#[path = "console_ctrl_c_tests.rs"]
mod tests;
