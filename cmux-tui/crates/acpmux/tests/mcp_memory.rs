#![cfg(target_os = "linux")]

/// Exercise the actual stdio process, including its runtime and allocator, with complete
/// session lists. The fixture lives outside the measured child and checks every reply.
#[test]
fn repeated_mcp_calls_keep_process_memory_bounded() {
    let harness = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("tests/mcp_memory.py");
    let status = std::process::Command::new("python3")
        .arg(harness)
        .args(["--binary", env!("CARGO_BIN_EXE_acpmux")])
        .args(["--worker-threads", "32", "--max-rss-mib", "96", "--max-growth-mib", "16"])
        .status()
        .expect("start the isolated MCP memory harness");
    assert!(status.success(), "MCP process memory regression: {status}");
}
