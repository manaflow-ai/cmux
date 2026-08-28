//! Byte-accounting audit taps (issue 10431), backed by the shared
//! non-blocking writer in [`cmux_tui_core::input_audit`] so the taps here and
//! the surface-lifecycle notes in `cmux-tui-core` share one open path and one
//! regular-file-only, mode-0600 contract. Raw payload capture requires
//! `CMUX_TUI_INPUT_AUDIT_ALLOW_SENSITIVE=1` in addition to the audit path.
//! `main()` installs the error
//! reporter that carries the single "audit disabled" note into the client
//! log.

pub(crate) use cmux_tui_core::input_audit::{enabled, note, record};

/// Route the audit sink's one-time failure note into the client log.
pub(crate) fn install_error_reporter() {
    cmux_tui_core::input_audit::set_error_reporter(|message| {
        crate::client_log::error("input-audit", message);
    });
}
