//! The fixed trace-point catalog: Swift's `SignpostName` ids and texts (CmuxNextSignposts,
//! frozen by p09-observability-000), so a Rust ring and the app's ring give a name the same id. Ids
//! are append-only and never reused; a name's category is the part of its text before the first dot.
//! `tests/macros.rs` reads `SignpostName.swift` and fails when the two tables differ.
//!
//! Every process ring starts with [`CATALOG`] ([`crate::init_blackbox`]), and the trace macros
//! ([`crate::trace_scope!`] and the others) resolve a catalog text to its id at compile time, so a
//! catalog trace point needs no lookup and no interning. Chrome registers its categories the same way,
//! statically (`base/trace_event/builtin_categories.h`).

use crate::category::*;
use crate::layout::{CatalogName, NameKind};

/// The catalog entry for `text` in `category` (one bit of [`crate::category`]).
const fn name(id: u16, category: u64, text: &'static str) -> CatalogName {
    CatalogName { id, kind: NameKind::Catalog, category: category.trailing_zeros() as u8, text }
}

/// Every catalog name, in id order (id = index + 1).
pub const CATALOG: &[CatalogName] = &[
    name(1, ACTION, "action.perform"),
    name(2, ACTION, "action.commit"),
    name(3, ACTION, "action.gate"),
    name(4, MOTION, "motion.frame"),
    name(5, MOTION, "motion.run"),
    name(6, KEY, "key.frame"),
    name(7, KEY, "key.flow"),
    name(8, KEY, "key.scroll_frame"),
    name(9, SWITCH, "switch.workspace"),
    name(10, SWITCH, "switch.tab"),
    name(11, SWITCH, "switch.pane_focus"),
    name(12, CREATE, "create.tab"),
    name(13, CREATE, "create.workspace"),
    name(14, CEF, "cef.pump"),
    name(15, CEF, "cef.create_browser"),
    name(16, STALL, "stall.main_task"),
    name(17, STALL, "stall.over_budget"),
    name(18, MOTION, "motion.drag_frame"),
    name(19, KEY, "key.omnibar_suggest"),
    name(20, KEY, "key.palette_search"),
    name(21, KEY, "key.echo.host_pty_read"),
    name(22, KEY, "key.echo.host_client_write"),
    name(23, KEY, "key.echo.daemon_frames"),
    name(24, KEY, "key.echo.surface_parse"),
    name(25, KEY, "key.echo.attach_encode"),
    name(26, KEY, "key.echo.line_out"),
    name(27, KEY, "key.echo.app_transport_read"),
    name(28, KEY, "key.echo.main_actor"),
    name(29, KEY, "key.echo.output_lane"),
    name(30, KEY, "key.echo.renderer"),
    name(31, KEY, "key.echo.gpu_done"),
    name(32, KEY, "key.echo.contents"),
    name(33, SWITCH, "switch.app_activation"),
    name(34, CEF, "cef.geometry"),
    name(35, CEF, "cef.host_input"),
    name(36, LAUNCH, "launch.process_to_main"),
    name(37, LAUNCH, "launch.first_window"),
    name(38, LAUNCH, "launch.first_frame"),
    name(39, LAUNCH, "launch.daemon_ready"),
    name(40, LAUNCH, "launch.first_terminal_output"),
    name(41, STALL, "stall.create_surface"),
    name(42, STALL, "stall.palette_open"),
    name(43, STALL, "stall.icon_picker_open"),
    name(44, DAEMON, "daemon.request"),
    name(45, FRAME, "frame.tick"),
    name(46, FRAME, "frame.commit"),
    name(47, FRAME, "frame.gpu_done"),
    name(48, FRAME, "frame.present_estimate"),
    name(49, FRAME, "frame.sequence"),
    name(50, TASK, "task.post"),
    name(51, TASK, "task.run"),
    name(52, HANG, "hang.thread_hung"),
    name(53, HANG, "hang.in_progress"),
    name(54, HANG, "hang.invalidated"),
    name(55, INPUT, "input.frame"),
    name(56, WEBVIEW, "webview.inp"),
    name(57, WEBVIEW, "webview.loaf"),
    name(58, REMOTE, "remote.input"),
    name(59, REMOTE, "remote.frame_decoded"),
    name(60, REMOTE, "remote.present"),
    name(61, CRASH, "crash.helper_exit"),
    name(62, CRASH, "crash.webkit_content_end"),
    name(63, CRASH, "crash.renderer_unresponsive"),
    name(64, CRASH, "crash.child_exit"),
    name(65, CRASH, "crash.dump_without_crashing"),
    name(66, CONTROL, "control.request"),
    name(67, GHOSTTY, "ghostty.render"),
    name(68, RESIZE, "resize.frame"),
    name(69, WEBUI, "webui.lifecycle"),
    name(70, WEBUI, "webui.open"),
    name(71, WEBUI, "webui.preload"),
    name(72, WEBUI, "webui.scheme"),
    name(73, STALL, "stall.main_turn"),
    name(74, STALL, "stall.render_starved"),
    name(75, LAUNCH, "launch.startup_task"),
    name(76, LAUNCH, "launch.startup_complete"),
    name(77, DAEMON, "daemon.step"),
    name(78, WEBUI, "webui.agent_pane_step"),
    name(79, STALL, "stall.ghostty_runtime_phase"),
    name(80, LAUNCH, "launch.read_done"),
    name(81, BURST, "burst.event"),
    name(82, MOTION, "motion.late_commits"),
    name(83, ACTION, "action.presented_estimate"),
    name(84, ACTION, "action.presented"),
    name(85, INPUT, "input.latency"),
    name(86, CEF, "cef.memory_pressure_vote"),
    name(87, GHOSTTY, "ghostty.lock_wait"),
];

// `catalog_name` indexes by id: the ids are 1, 2, 3, ... in order. Each text starts with its
// category's name, as every trace point's must (`TraceSite::new`).
const _: () = {
    let mut index = 0;
    while index < CATALOG.len() {
        let entry = &CATALOG[index];
        assert!(entry.id as usize == index + 1, "catalog ids are 1..=len in order");
        assert!(
            crate::macros::has_category_prefix(
                entry.text,
                crate::macros::CATEGORY_NAMES[entry.category as usize]
            ),
            "a catalog name starts with its category's name and a dot"
        );
        index += 1;
    }
};

/// The catalog id of `text`, or 0 when it is not a catalog name. A `const fn`: the trace macros
/// call it in a `static` initializer, so it runs at compile time.
pub const fn catalog_id(text: &str) -> u16 {
    let mut index = 0;
    while index < CATALOG.len() {
        if bytes_equal(CATALOG[index].text.as_bytes(), text.as_bytes()) {
            return CATALOG[index].id;
        }
        index += 1;
    }
    0
}

/// The catalog entry with id `id`.
pub const fn catalog_name(id: u16) -> Option<&'static CatalogName> {
    let index = id as usize;
    if index == 0 || index > CATALOG.len() {
        return None;
    }
    Some(&CATALOG[index - 1])
}

const fn bytes_equal(a: &[u8], b: &[u8]) -> bool {
    if a.len() != b.len() {
        return false;
    }
    let mut index = 0;
    while index < a.len() {
        if a[index] != b[index] {
            return false;
        }
        index += 1;
    }
    true
}
