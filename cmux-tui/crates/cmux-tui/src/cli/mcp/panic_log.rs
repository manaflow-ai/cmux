//! The panic log of `cmux mcp serve`.
//!
//! An MCP client (Claude Code, Codex) starts the server with its stdio as
//! the JSON-RPC wire and drops stderr, so a panic on a watch or upstream
//! thread used to leave nothing. The hook appends one JSON line per panic
//! (cmux-panic-log) to `mcp-panics.jsonl` at the owner's state root
//! (`HelperPanicLog::McpServe`), then runs the previous hook. The cmux-next
//! app sends new lines to Sentry (`RustPanicSource.mcp`).

/// Debug builds only: `thread` makes a worker thread panic once the hook
/// is installed (tests/mcp_panic_log.rs). Its line carries `"test": true`.
#[cfg(debug_assertions)]
const TEST_PANIC_ENV: &str = "CMUX_TUI_TEST_MCP_PANIC";
#[cfg(debug_assertions)]
const TEST_PANIC_THREAD: &str = "mcp-panic-test";

/// Install the hook; with no state directory, the default hook stays.
pub(super) fn install() {
    let Some(path) = cmux_tui_core::diagnostics::HelperPanicLog::McpServe.path() else { return };
    let mut fields = cmux_panic_log::Fields::new();
    fields.insert("process".into(), "cmux-mcp".into());
    fields.insert("pid".into(), std::process::id().into());
    fields.insert("version".into(), crate::version_report::DISTRIBUTION_VERSION.into());
    fields.insert("os".into(), std::env::consts::OS.into());
    fields.insert("arch".into(), std::env::consts::ARCH.into());
    cmux_panic_log::install(path, fields, is_test_thread);
    #[cfg(debug_assertions)]
    panic_for_test();
}

/// The debug test trigger's thread; its line carries `"test": true`.
fn is_test_thread(thread: &str) -> bool {
    #[cfg(debug_assertions)]
    {
        thread == TEST_PANIC_THREAD
    }
    #[cfg(not(debug_assertions))]
    {
        let _ = thread;
        false
    }
}

/// Debug builds only: panic a worker thread when the test asks for it.
#[cfg(debug_assertions)]
#[allow(clippy::panic, reason = "debug-build test trigger for the MCP server panic log")]
fn panic_for_test() {
    if std::env::var(TEST_PANIC_ENV).as_deref() != Ok("thread") {
        return;
    }
    let _ = cmux_threads::spawn(TEST_PANIC_THREAD, cmux_threads::ThreadQos::Utility, || {
        // crash-allow: debug-only test trigger for the MCP server panic log
        panic!("cmux mcp serve test panic")
    });
}
