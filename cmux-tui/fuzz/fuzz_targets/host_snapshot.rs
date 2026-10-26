//! The terminal-host Snapshot payload (`decode_snapshot_with_program_status`,
//! terminal_host_runtime/shared/codec.rs), the attach state a daemon or a
//! smart renderer reads from a host. The first byte picks the protocol
//! version (low three bits, 0 and 5..7 unsupported) and the negotiated
//! tails (metadata, shell activity, program status); the rest is the payload.

#![no_main]

#[path = "support/codec.rs"]
mod codec;

use cmux_tui_core::fuzz_entry::{SnapshotTails, host_snapshot};
use cmux_tui_core::terminal_host_protocol::PROTOCOL_VERSION;
use libfuzzer_sys::fuzz_target;

fuzz_target!(|data: &[u8]| {
    let Some((&wire, payload)) = data.split_first() else {
        return;
    };
    let version = u16::from(wire & 0b111);
    let tails = SnapshotTails {
        terminal_metadata: wire & 0b1000 != 0,
        shell_activity: wire & 0b1_0000 != 0,
        program_status: wire & 0b10_0000 != 0,
    };
    codec::assert_canonical(host_snapshot(payload, version, tails), |canonical| {
        host_snapshot(canonical, PROTOCOL_VERSION, tails)
    });
});
