//! What a hosted terminal spawn hands its new host besides its options.

/// The launch inputs of a new hosted terminal (`Surface::spawn_with_terminal_id_and_resource_identity_at_cell_pixels`).
/// `Default` is a fresh terminal: a new id, no seed, no workspace yet, a new
/// host process.
#[derive(Default)]
pub(crate) struct HostLaunch<'a> {
    /// The registry-reserved terminal id; `None` mints one.
    pub(crate) terminal_id: Option<crate::terminal_host::TerminalId>,
    /// VT replay the host applies before the child's first byte (empty: none).
    pub(crate) seed: &'a [u8],
    /// The workspace the host's first record names (its recovery mirror), so
    /// the spawn needs no second synced record write (empty: none yet).
    pub(crate) workspace_key: &'a str,
    /// A host process started ahead (R81, the pool's spare); `None` starts one.
    #[cfg(any(unix, windows))]
    pub(crate) standby: Option<crate::terminal_host_runtime::StandbyTerminalHost>,
}
