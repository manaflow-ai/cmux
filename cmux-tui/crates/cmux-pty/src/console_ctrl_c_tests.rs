use super::*;

/// `CREATE_NEW_PROCESS_GROUP` (processthreadsapi.h).
const CREATE_NEW_PROCESS_GROUP: u32 = 0x0000_0200;
/// `DETACHED_PROCESS`, as the terminal owner is started.
const DETACHED_PROCESS: u32 = 0x0000_0008;
/// `CREATE_NO_WINDOW`, as the terminal host is started.
const CREATE_NO_WINDOW: u32 = 0x0800_0000;
/// The creation flags of portable-pty 0.9's ConPTY `CreateProcessW`
/// (`EXTENDED_STARTUPINFO_PRESENT | CREATE_UNICODE_ENVIRONMENT`,
/// `win/psuedocon.rs`): no new group, so the child inherits.
const PORTABLE_PTY_CREATION_FLAGS: u32 = 0x0008_0000 | 0x0000_0400;

/// Whether a process made by `CreateProcessW` with `creation_flags`
/// starts ignoring Ctrl+C, when its creator does so or not (the
/// documented behavior above).
const fn created_process_ignores_ctrl_c(creator_ignores: bool, creation_flags: u32) -> bool {
    creation_flags & CREATE_NEW_PROCESS_GROUP != 0 || creator_ignores
}

/// The owner and the host start in a new group and so ignore Ctrl+C; a
/// PTY child of either inherits that unless the spawn clears it first.
/// The cfg-independent half of the Windows test
/// `a_pty_child_processes_ctrl_c_from_a_spawner_that_ignores_it`.
#[test]
fn a_pty_child_of_a_new_group_spawner_processes_ctrl_c() {
    for spawner_flags in
        [DETACHED_PROCESS | CREATE_NEW_PROCESS_GROUP, CREATE_NO_WINDOW | CREATE_NEW_PROCESS_GROUP]
    {
        let spawner_ignores = created_process_ignores_ctrl_c(false, spawner_flags);
        assert!(spawner_ignores, "{spawner_flags:#x}");
        assert!(
            created_process_ignores_ctrl_c(spawner_ignores, PORTABLE_PTY_CREATION_FLAGS),
            "without the reset the child inherits the ignore attribute"
        );
        assert!(!created_process_ignores_ctrl_c(
            PTY_SPAWNER_IGNORES_CTRL_C,
            PORTABLE_PTY_CREATION_FLAGS
        ));
    }
}

/// `SetConsoleCtrlHandler(NULL, FALSE)` is the call that restores
/// processing; TRUE would ignore Ctrl+C.
#[test]
fn the_spawner_restores_processing_with_a_false_add_argument() {
    assert_eq!(null_handler_add_argument(PTY_SPAWNER_IGNORES_CTRL_C), 0);
    assert_eq!(null_handler_add_argument(true), 1);
}
