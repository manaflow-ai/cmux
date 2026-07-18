use std::io::Write;
use std::process::{Command, Stdio};

use cmux_tui_core::terminal_host::{
    CAPABILITY_TOKEN_LEN, CapabilityToken, HostBootstrap, HostReady, TerminalId,
};
use cmux_tui_core::terminal_host_protocol::{
    MAX_FRAME_PAYLOAD, MessageKind, PROTOCOL_VERSION, encode_frame, read_frame,
};

#[test]
fn hidden_terminal_host_mode_bootstraps_over_private_stdio() {
    let terminal_id = TerminalId::from_bytes([0x31; 16]);
    let owner_token = CapabilityToken::from_bytes([0xa7; CAPABILITY_TOKEN_LEN]);
    let bootstrap = HostBootstrap {
        min_version: PROTOCOL_VERSION,
        max_version: PROTOCOL_VERSION,
        terminal_id,
        owner_token,
    };
    let input = encode_frame(&bootstrap.into_frame(99)).unwrap();

    let mut child = Command::new(env!("CARGO_BIN_EXE_cmux-tui"))
        .args(["__terminal-host", "--bootstrap-stdio"])
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped())
        .spawn()
        .unwrap();
    child.stdin.take().unwrap().write_all(&input).unwrap();
    let output = child.wait_with_output().unwrap();
    assert!(output.status.success(), "{}", String::from_utf8_lossy(&output.stderr));
    assert!(output.stderr.is_empty());
    assert!(
        !output.stdout.windows(CAPABILITY_TOKEN_LEN).any(|window| window == owner_token.as_bytes())
    );

    let frame = read_frame(&mut output.stdout.as_slice(), MAX_FRAME_PAYLOAD).unwrap().unwrap();
    assert_eq!(frame.kind, MessageKind::Ready);
    assert_eq!(frame.request_id, 99);
    let ready = HostReady::decode(&frame.payload).unwrap();
    assert_eq!(ready.selected_version, PROTOCOL_VERSION);
    assert_eq!(ready.terminal_id, terminal_id);
}

#[test]
fn hidden_terminal_host_mode_rejects_unframed_invocation() {
    let output =
        Command::new(env!("CARGO_BIN_EXE_cmux-tui")).arg("__terminal-host").output().unwrap();
    assert!(!output.status.success());
    assert!(String::from_utf8_lossy(&output.stderr).contains("requires --bootstrap-stdio"));
    assert!(output.stdout.is_empty());
}
