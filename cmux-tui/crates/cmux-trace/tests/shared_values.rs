//! The numbers every ring writer shares (plans/cmux-next/trace.md: "Release trace ring: category
//! bits" and "Release trace ring v1"). Swift's `SignpostTraceCatalogTests` and
//! `TraceRuntimeContractTests` pin the same values; a change here without them makes a merged app
//! and daemon trace turn on and label the wrong categories.

use cmux_trace::{Phase, Role, category};

#[test]
fn category_bits_match_the_shared_table() {
    let bits = [
        (category::ACTION, 0),
        (category::KEY, 1),
        (category::SWITCH, 2),
        (category::CREATE, 3),
        (category::CEF, 4),
        (category::LAUNCH, 5),
        (category::DAEMON, 6),
        (category::HANG, 7),
        (category::CRASH, 8),
        (category::MOTION, 9),
        (category::FRAME, 10),
        (category::STALL, 11),
        (category::TASK, 12),
        (category::BURST, 13),
        (category::INPUT, 14),
        (category::WEBVIEW, 15),
        (category::REMOTE, 16),
        (category::CONTROL, 17),
        (category::GHOSTTY, 18),
        (category::RESIZE, 19),
        (category::WEBUI, 20),
        (category::LOG, 21),
    ];
    for (mask, bit) in bits {
        assert_eq!(mask, 1u64 << bit, "category bit {bit}");
    }
    assert_eq!(category::BLACKBOX, 0x1ff, "the black box records bits 0-8");
    assert_eq!(category::ALL, (1 << 22) - 1, "every category is in ALL");
    assert_eq!(category::BLACKBOX & category::RECORDING, 0);
}

#[test]
fn roles_match_the_ring_v1_header_table() {
    let roles = [
        (Role::App, 1),
        (Role::Daemon, 2),
        (Role::Holder, 3),
        (Role::TerminalHost, 4),
        (Role::Acpmux, 5),
        (Role::ChromiumHost, 6),
        (Role::Cli, 7),
        (Role::AgentHost, 8),
        (Role::AppHost, 9),
        (Role::BrowserHost, 10),
    ];
    for (role, raw) in roles {
        assert_eq!(role as u16, raw, "{role:?}");
        assert_eq!(Role::from_raw(raw), Some(role));
    }
    assert_eq!(Role::from_raw(0), None);
    assert_eq!(Role::from_raw(11), None);
}

#[test]
fn phases_are_chromes_ascii_codes() {
    let phases = [
        (Phase::Begin, 0x42),
        (Phase::End, 0x45),
        (Phase::Instant, 0x49),
        (Phase::AsyncBegin, 0x62),
        (Phase::AsyncEnd, 0x65),
        (Phase::FlowOut, 0x73),
        (Phase::FlowIn, 0x66),
        (Phase::Counter, 0x43),
    ];
    for (phase, raw) in phases {
        assert_eq!(phase as u8, raw, "{phase:?}");
        assert_eq!(Phase::from_raw(raw), Some(phase));
    }
    assert_eq!(Phase::from_raw(0), None);
}
