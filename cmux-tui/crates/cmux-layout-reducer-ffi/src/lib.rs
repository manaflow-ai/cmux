//! Narrow C ABI for the app's pure Rust rules: one JSON channel
//! (`cmux_layout_reducer_json`: an op name and a JSON request in, a JSON answer out) and typed
//! C functions per handle (the sidebar document mirror below, and modules such as [`focus`],
//! [`close_focus`], [`close_selection`], [`window_close_selection`], [`agent_cursor`],
//! [`sidebar_face`], [`drag_handle`] and [`scroll`]).
//!
//! The JSON channel's ops: the few answered in `cmux_layout_reducer_json`'s own match
//! (`cmux-layout-reducer`'s sidebar drop resolver and section layout reducer, the sidebar's
//! other rules, `cmux-tasks-core`'s Tasks preview, the bookmark preview, the Cloud start's
//! checks, `cmux-focus-core`'s per-key rules, `imessage`, `mobile_host`), and every other op,
//! which belongs to an op module: a file in `src/` with `handles` and `respond`, whose own
//! `//!` says which ops it answers and which crate's rules they are (such as
//! `cmux-window-rules`' first-run step rules and external open router
//! (`onboarding_steps_*`: the Computer Use and Agents steps, where a URL or
//! file macOS hands cmux goes)).
//!
//! Adding a module is adding its file: build.rs writes every module's `mod` line and the op
//! modules' dispatch, so no list in this file grows (see build.rs).

use cmux_layout_reducer::{sidebar_drag, sidebar_drop, sidebar_edits, sidebar_layout};
use std::ffi::{CString, c_char};
use std::panic::{AssertUnwindSafe, catch_unwind};

// Every module's `mod` line and the op modules' dispatch (`respond_op_module`), from the files
// in src/: see build.rs.
include!(concat!(env!("OUT_DIR"), "/dispatch.rs"));

/// How many sidebar drag geometries stay live (`sidebar_geometry`, an op module build.rs declares).
pub use sidebar_geometry::KEEP as SIDEBAR_GEOMETRY_KEEP;

use sidebar_mirror::Mirror;

pub const ABI_VERSION: u32 = 1;
pub const OK: i32 = 0;
pub const ERR_NULL: i32 = -1;
pub const ERR_INVALID: i32 = -2;
pub const ERR_BUFFER: i32 = -3;
pub const ERR_PANIC: i32 = -4;

unsafe fn input<'a>(ptr: *const u8, len: usize) -> Option<&'a [u8]> {
    if len == 0 {
        return Some(&[]);
    }
    if ptr.is_null() {
        return None;
    }
    // SAFETY: guaranteed by the C caller.
    Some(unsafe { std::slice::from_raw_parts(ptr, len) })
}

unsafe fn write_output(
    bytes: &[u8],
    output: *mut u8,
    capacity: usize,
    output_len: *mut usize,
) -> i32 {
    if output_len.is_null() {
        return ERR_NULL;
    }
    // SAFETY: checked non-null and writable by the C caller.
    unsafe { *output_len = bytes.len() };
    if bytes.len() > capacity {
        return ERR_BUFFER;
    }
    if bytes.is_empty() {
        return OK;
    }
    if output.is_null() {
        return ERR_NULL;
    }
    // SAFETY: the caller provided at least `capacity` writable bytes.
    unsafe { std::ptr::copy_nonoverlapping(bytes.as_ptr(), output, bytes.len()) };
    OK
}

#[unsafe(no_mangle)]
pub extern "C" fn cmux_layout_reducer_ffi_abi_version() -> u32 {
    ABI_VERSION
}

/// Resolves one JSON request. See the checked-in header for the pointer rules.
///
/// # Safety
///
/// `request` points to `request_len` readable bytes (or is null with length
/// 0), `operation` is a NUL-terminated C string, `output` points to
/// `output_capacity` writable bytes (or is null with capacity 0) and
/// `output_len` is writable.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_layout_reducer_json(
    request: *const u8,
    request_len: usize,
    operation: *const c_char,
    output: *mut u8,
    output_capacity: usize,
    output_len: *mut usize,
) -> i32 {
    let Some(request) = (unsafe { input(request, request_len) }) else { return ERR_NULL };
    if operation.is_null() {
        return ERR_NULL;
    }
    // SAFETY: operation is a NUL-terminated C string owned by the caller.
    let operation = unsafe { std::ffi::CStr::from_ptr(operation) }.to_bytes();
    let result = catch_unwind(AssertUnwindSafe(|| {
        let response = match operation {
            b"imessage" => imessage::respond(request)?,
            b"base_y" => {
                #[derive(serde::Deserialize)]
                struct BaseY {
                    display_y: f64,
                    gap_y: Option<f64>,
                    gap_height: f64,
                }
                let request: BaseY = serde_json::from_slice(request).map_err(|_| ERR_INVALID)?;
                serde_json::to_vec(&sidebar_drop::base_y(
                    request.display_y,
                    request.gap_y,
                    request.gap_height,
                ))
                .map_err(|_| ERR_INVALID)?
            }
            b"resolve" => {
                let request: sidebar_drop::Request =
                    serde_json::from_slice(request).map_err(|_| ERR_INVALID)?;
                serde_json::to_vec(&sidebar_drop::resolve(&request)).map_err(|_| ERR_INVALID)?
            }
            b"resolve_drag" => {
                let request: sidebar_drag::DragRequest =
                    serde_json::from_slice(request).map_err(|_| ERR_INVALID)?;
                serde_json::to_vec(&sidebar_drag::resolve_drag(&request))
                    .map_err(|_| ERR_INVALID)?
            }
            b"tab_drop" => {
                let request: sidebar_drop::TabRequest =
                    serde_json::from_slice(request).map_err(|_| ERR_INVALID)?;
                serde_json::to_vec(&sidebar_drop::resolve_tab_drop(&request))
                    .map_err(|_| ERR_INVALID)?
            }
            b"tab_refusal" => {
                let request: sidebar_drop::TabRequest =
                    serde_json::from_slice(request).map_err(|_| ERR_INVALID)?;
                serde_json::to_vec(&sidebar_drop::tab_drop_refusal(&request))
                    .map_err(|_| ERR_INVALID)?
            }
            b"sidebar_change_failure" => {
                // A refused or failed sidebar document change: its code (a reducer
                // refusal, or `no_answer`, `unavailable`, `failed`) and the text the
                // app shows when the person made the change.
                #[derive(serde::Deserialize)]
                struct Request {
                    code: String,
                }
                let request: Request = serde_json::from_slice(request).map_err(|_| ERR_INVALID)?;
                let text = cmux_layout_reducer::sidebar_doc::change_failure_text(&request.code);
                let refusal =
                    cmux_layout_reducer::sidebar_doc::Refusal::from_code(&request.code).is_some();
                serde_json::to_vec(&serde_json::json!({ "text": text, "refusal": refusal }))
                    .map_err(|_| ERR_INVALID)?
            }
            b"sidebar_layout_reduce" => {
                let request: sidebar_layout::Request =
                    serde_json::from_slice(request).map_err(|_| ERR_INVALID)?;
                serde_json::to_vec(&sidebar_layout::respond(&request)).map_err(|_| ERR_INVALID)?
            }
            b"sidebar_layout_plan" => {
                let request: cmux_layout_reducer::sidebar_layout_plan::Request =
                    serde_json::from_slice(request).map_err(|_| ERR_INVALID)?;
                serde_json::to_vec(&cmux_layout_reducer::sidebar_layout_plan::respond(&request))
                    .map_err(|_| ERR_INVALID)?
            }
            b"auto_archive_plan" => {
                use cmux_layout_reducer::auto_archive;
                let request: auto_archive::Request =
                    serde_json::from_slice(request).map_err(|_| ERR_INVALID)?;
                serde_json::to_vec(&auto_archive::plan(&request)).map_err(|_| ERR_INVALID)?
            }
            b"sidebar_settle_plan" => {
                use cmux_layout_reducer::settle;
                let request: settle::Request =
                    serde_json::from_slice(request).map_err(|_| ERR_INVALID)?;
                serde_json::to_vec(&settle::plan(&request)).map_err(|_| ERR_INVALID)?
            }
            b"keep_awake_plan" => {
                use cmux_layout_reducer::keep_awake;
                let request: keep_awake::Request =
                    serde_json::from_slice(request).map_err(|_| ERR_INVALID)?;
                serde_json::to_vec(&keep_awake::plan(&request)).map_err(|_| ERR_INVALID)?
            }
            b"sidebar_edits" => {
                let request: sidebar_edits::Request =
                    serde_json::from_slice(request).map_err(|_| ERR_INVALID)?;
                sidebar_edits::respond(&request).map_err(|_| ERR_INVALID)?
            }
            b"sidebar_item_info" => {
                use cmux_layout_reducer::sidebar_item_info;
                let request: sidebar_item_info::Request =
                    serde_json::from_slice(request).map_err(|_| ERR_INVALID)?;
                serde_json::to_vec(&sidebar_item_info::respond(&request))
                    .map_err(|_| ERR_INVALID)?
            }
            b"sidebar_bridge" => {
                let request: cmux_layout_reducer::sidebar_bridge::Request =
                    serde_json::from_slice(request).map_err(|_| ERR_INVALID)?;
                cmux_layout_reducer::sidebar_bridge::respond(&request).map_err(|_| ERR_INVALID)?
            }
            b"sidebar_launch_order" => {
                use cmux_layout_reducer::sidebar_launch_order;
                let request: sidebar_launch_order::Request =
                    serde_json::from_slice(request).map_err(|_| ERR_INVALID)?;
                serde_json::to_vec(&sidebar_launch_order::respond(&request))
                    .map_err(|_| ERR_INVALID)?
            }
            b"sidebar_feeds" => {
                use cmux_layout_reducer::sidebar_feeds;
                let request: sidebar_feeds::Request =
                    serde_json::from_slice(request).map_err(|_| ERR_INVALID)?;
                serde_json::to_vec(&sidebar_feeds::respond(&request)).map_err(|_| ERR_INVALID)?
            }
            b"sidebar_list_rules" => {
                use cmux_layout_reducer::sidebar_list_rules;
                let request: sidebar_list_rules::Request =
                    serde_json::from_slice(request).map_err(|_| ERR_INVALID)?;
                serde_json::to_vec(&sidebar_list_rules::respond(&request))
                    .map_err(|_| ERR_INVALID)?
            }
            b"sidebar_row_layout" => {
                use cmux_layout_reducer::sidebar_row_layout;
                let request: sidebar_row_layout::Request =
                    serde_json::from_slice(request).map_err(|_| ERR_INVALID)?;
                serde_json::to_vec(&sidebar_row_layout::respond(&request))
                    .map_err(|_| ERR_INVALID)?
            }
            b"sidebar_drag_geometry" => {
                use cmux_layout_reducer::sidebar_drag_geometry;
                let request: sidebar_drag_geometry::Request =
                    serde_json::from_slice(request).map_err(|_| ERR_INVALID)?;
                serde_json::to_vec(&sidebar_drag_geometry::respond(&request))
                    .map_err(|_| ERR_INVALID)?
            }
            b"sidebar_region_layout" => {
                use cmux_layout_reducer::sidebar_region_layout;
                let request: sidebar_region_layout::Request =
                    serde_json::from_slice(request).map_err(|_| ERR_INVALID)?;
                serde_json::to_vec(&sidebar_region_layout::respond(&request))
                    .map_err(|_| ERR_INVALID)?
            }
            b"sidebar_band_heights" => {
                use cmux_layout_reducer::sidebar_region_layout;
                let request: sidebar_region_layout::BandHeights =
                    serde_json::from_slice(request).map_err(|_| ERR_INVALID)?;
                serde_json::to_vec(&sidebar_region_layout::band_heights(&request))
                    .map_err(|_| ERR_INVALID)?
            }
            b"sidebar_nav" => {
                use cmux_layout_reducer::sidebar_nav;
                let request: sidebar_nav::Request =
                    serde_json::from_slice(request).map_err(|_| ERR_INVALID)?;
                serde_json::to_vec(&sidebar_nav::respond(&request)).map_err(|_| ERR_INVALID)?
            }
            b"sidebar_section_customization" => {
                let request: cmux_layout_reducer::sidebar_section_customization::Request =
                    serde_json::from_slice(request).map_err(|_| ERR_INVALID)?;
                serde_json::to_vec(&cmux_layout_reducer::sidebar_section_customization::respond(
                    &request,
                ))
                .map_err(|_| ERR_INVALID)?
            }
            b"sidebar_archive_marks" => {
                use cmux_layout_reducer::sidebar_archive_marks;
                let request: sidebar_archive_marks::Request =
                    serde_json::from_slice(request).map_err(|_| ERR_INVALID)?;
                serde_json::to_vec(&sidebar_archive_marks::respond(request))
                    .map_err(|_| ERR_INVALID)?
            }
            b"sidebar_chat_history" => {
                use cmux_layout_reducer::sidebar_chat_history;
                let request: sidebar_chat_history::Request =
                    serde_json::from_slice(request).map_err(|_| ERR_INVALID)?;
                serde_json::to_vec(&sidebar_chat_history::respond(request))
                    .map_err(|_| ERR_INVALID)?
            }
            b"sidebar_doc_target" => {
                use cmux_layout_reducer::sidebar_doc_target;
                let request: sidebar_doc_target::Request =
                    serde_json::from_slice(request).map_err(|_| ERR_INVALID)?;
                serde_json::to_vec(&sidebar_doc_target::respond(request))
                    .map_err(|_| ERR_INVALID)?
            }
            b"sidebar_pending_records" => {
                use cmux_layout_reducer::sidebar_pending_records;
                let request: sidebar_pending_records::Request =
                    serde_json::from_slice(request).map_err(|_| ERR_INVALID)?;
                serde_json::to_vec(&sidebar_pending_records::respond(request))
                    .map_err(|_| ERR_INVALID)?
            }
            b"sidebar_sections" => {
                use cmux_layout_reducer::sidebar_sections;
                let request: sidebar_sections::Request =
                    serde_json::from_slice(request).map_err(|_| ERR_INVALID)?;
                serde_json::to_vec(&sidebar_sections::respond(request)).map_err(|_| ERR_INVALID)?
            }
            b"sidebar_session_tree" => {
                use cmux_layout_reducer::sidebar_session_tree;
                let request: sidebar_session_tree::Request =
                    serde_json::from_slice(request).map_err(|_| ERR_INVALID)?;
                serde_json::to_vec(&sidebar_session_tree::respond(request))
                    .map_err(|_| ERR_INVALID)?
            }
            b"group_hover_summary" => {
                let request: cmux_layout_reducer::group_hover_summary::Request =
                    serde_json::from_slice(request).map_err(|_| ERR_INVALID)?;
                serde_json::to_vec(&cmux_layout_reducer::group_hover_summary::summarize(&request))
                    .map_err(|_| ERR_INVALID)?
            }
            b"workspace_port_links" => {
                use cmux_layout_reducer::workspace_port_links;
                let request: workspace_port_links::Request =
                    serde_json::from_slice(request).map_err(|_| ERR_INVALID)?;
                serde_json::to_vec(&workspace_port_links::respond(&request))
                    .map_err(|_| ERR_INVALID)?
            }
            b"new_placement" => {
                use cmux_layout_reducer::new_placement;
                let request: new_placement::Request =
                    serde_json::from_slice(request).map_err(|_| ERR_INVALID)?;
                serde_json::to_vec(&new_placement::plan(&request)).map_err(|_| ERR_INVALID)?
            }
            b"optimistic" => {
                let request = cmux_layout_reducer::optimistic::parse_request(request)
                    .map_err(|_| ERR_INVALID)?;
                serde_json::to_vec(&cmux_layout_reducer::optimistic::respond(&request))
                    .map_err(|_| ERR_INVALID)?
            }
            b"tasks_preview" => {
                let request: cmux_tasks_core::preview::Request =
                    serde_json::from_slice(request).map_err(|_| ERR_INVALID)?;
                serde_json::to_vec(&cmux_tasks_core::preview::respond(&request))
                    .map_err(|_| ERR_INVALID)?
            }
            b"bookmarks_apply" => {
                let request: cmux_bookmarks_core::preview::Request =
                    serde_json::from_slice(request).map_err(|_| ERR_INVALID)?;
                serde_json::to_vec(&cmux_bookmarks_core::preview::respond(request))
                    .map_err(|_| ERR_INVALID)?
            }
            b"cloud_agent_check" => {
                use cmux_cloud_start_core::agent_check;
                let request: agent_check::Request =
                    serde_json::from_slice(request).map_err(|_| ERR_INVALID)?;
                serde_json::to_vec(&agent_check::check(&request)).map_err(|_| ERR_INVALID)?
            }
            b"cloud_capability_header" => {
                use cmux_cloud_start_core::capability;
                let request: capability::HeaderRequest =
                    serde_json::from_slice(request).map_err(|_| ERR_INVALID)?;
                serde_json::to_vec(&capability::header(&request)).map_err(|_| ERR_INVALID)?
            }
            b"cloud_capability_answer" => {
                use cmux_cloud_start_core::capability;
                let request: capability::AnswerRequest =
                    serde_json::from_slice(request).map_err(|_| ERR_INVALID)?;
                serde_json::to_vec(&capability::answer(request)).map_err(|_| ERR_INVALID)?
            }
            // A held create's approval: the next session call to make, or the outcome (cmux-cloud-start-core approval_answer;
            // a team whose backend refused the one call skips it for a while).
            b"cloud_approval_next" => {
                use cmux_cloud_start_core::approval_answer;
                let request: approval_answer::Request =
                    serde_json::from_slice(request).map_err(|_| ERR_INVALID)?;
                serde_json::to_vec(&approval_answer::next_remembered(&request))
                    .map_err(|_| ERR_INVALID)?
            }
            b"cloud_capability_drop" => {
                cmux_cloud_start_core::capability::forget();
                b"{}".to_vec()
            }
            b"cloud_one_pane" => {
                use cmux_cloud_start_core::one_pane;
                let request: one_pane::Request =
                    serde_json::from_slice(request).map_err(|_| ERR_INVALID)?;
                serde_json::to_vec(&serde_json::json!({ "shown": one_pane::shown(&request) }))
                    .map_err(|_| ERR_INVALID)?
            }
            b"cloud_start_refusal" => {
                #[derive(serde::Deserialize)]
                #[serde(rename_all = "camelCase")]
                struct Request {
                    cloud_disabled: bool,
                    signed_in: bool,
                    #[serde(default)]
                    requested_team: Option<String>,
                    #[serde(default)]
                    active_team: Option<String>,
                }
                let request: Request = serde_json::from_slice(request).map_err(|_| ERR_INVALID)?;
                let refusal = cmux_cloud_start_core::start::refusal(
                    request.cloud_disabled,
                    request.signed_in,
                )
                .or_else(|| {
                    cmux_cloud_start_core::start::team_refusal(
                        request.requested_team.as_deref(),
                        request.active_team.as_deref(),
                    )
                });
                serde_json::to_vec(&serde_json::json!({ "refusal": refusal }))
                    .map_err(|_| ERR_INVALID)?
            }
            b"cloud_ask_answer" => {
                use cmux_cloud_start_core::ask;
                #[derive(serde::Deserialize)]
                #[serde(rename_all = "camelCase")]
                struct Request {
                    #[serde(default)]
                    origin: Option<String>,
                    #[serde(default)]
                    agent_session: Option<String>,
                    delegated: bool,
                    selection: String,
                }
                let request: Request = serde_json::from_slice(request).map_err(|_| ERR_INVALID)?;
                let caller =
                    ask::caller(request.origin.as_deref(), request.agent_session.as_deref());
                let choice = ask::choice(&request.selection);
                let verdict = choice.map(|choice| ask::answer(caller, request.delegated, choice));
                serde_json::to_vec(&serde_json::json!({
                    "caller": caller, "choice": choice, "verdict": verdict,
                }))
                .map_err(|_| ERR_INVALID)?
            }
            b"cloud_ask_first" => {
                #[derive(serde::Deserialize)]
                struct Request {
                    delegated: bool,
                }
                let request: Request = serde_json::from_slice(request).map_err(|_| ERR_INVALID)?;
                let asks = cmux_cloud_start_core::ask::agent_asks_first(request.delegated);
                serde_json::to_vec(&serde_json::json!({ "asks": asks })).map_err(|_| ERR_INVALID)?
            }
            b"cloud_start_account_text" => {
                #[derive(serde::Deserialize)]
                struct Request {
                    account: Vec<Option<String>>,
                }
                let request: Request = serde_json::from_slice(request).map_err(|_| ERR_INVALID)?;
                let text = cmux_cloud_start_core::start::account_text(&request.account);
                serde_json::to_vec(&serde_json::json!({ "text": text })).map_err(|_| ERR_INVALID)?
            }
            b"cloud_start_check_account" => {
                #[derive(serde::Deserialize)]
                #[serde(rename_all = "camelCase")]
                struct Request {
                    asked: Vec<Option<String>>,
                    now: Vec<Option<String>>,
                    list_current: bool,
                }
                let request: Request = serde_json::from_slice(request).map_err(|_| ERR_INVALID)?;
                let check = cmux_cloud_start_core::start::check_account(
                    &request.asked,
                    &request.now,
                    request.list_current,
                );
                serde_json::to_vec(&serde_json::json!({ "check": check }))
                    .map_err(|_| ERR_INVALID)?
            }
            b"cloud_start_pane_recovery" => {
                let failure: cmux_cloud_start_core::recover::PaneFailure =
                    serde_json::from_slice(request).map_err(|_| ERR_INVALID)?;
                serde_json::to_vec(&cmux_cloud_start_core::recover::pane_step(&failure))
                    .map_err(|_| ERR_INVALID)?
            }
            b"cloud_start_list_wait" => {
                #[derive(serde::Deserialize)]
                #[serde(rename_all = "camelCase")]
                struct Request {
                    elapsed_ms: u64,
                    #[serde(default)]
                    deadline_left_ms: Option<u64>,
                    loaded: bool,
                    signed_in: bool,
                }
                let request: Request = serde_json::from_slice(request).map_err(|_| ERR_INVALID)?;
                let next = cmux_cloud_start_core::list_wait::list_wait(
                    std::time::Duration::from_millis(request.elapsed_ms),
                    request.deadline_left_ms.map(std::time::Duration::from_millis),
                    request.loaded,
                    request.signed_in,
                );
                serde_json::to_vec(&next).map_err(|_| ERR_INVALID)?
            }
            b"cloud_start_uploads" => {
                let request: cmux_cloud_start_core::start::Folder =
                    serde_json::from_slice(request).map_err(|_| ERR_INVALID)?;
                let uploads = cmux_cloud_start_core::start::uploads(&request);
                serde_json::to_vec(&serde_json::json!({ "uploads": uploads }))
                    .map_err(|_| ERR_INVALID)?
            }
            // The start's check of the machine's model route: the command to run there, and,
            // given what it printed, the verdict.
            b"cloud_machine_route" => {
                #[derive(serde::Deserialize)]
                struct Request {
                    #[serde(default)]
                    stdout: Option<String>,
                }
                use cmux_cloud_start_core::machine_route;
                let request: Request = serde_json::from_slice(request).map_err(|_| ERR_INVALID)?;
                let verdict = request.stdout.as_deref().map(machine_route::verdict);
                serde_json::to_vec(&serde_json::json!({
                    "command": machine_route::GUEST, "verdict": verdict,
                }))
                .map_err(|_| ERR_INVALID)?
            }
            // A spare machine's warm-home command, with the person's recent shapes read off this
            // Mac's acpmux home (`acpmuxHome`), so the spare warms the harnesses and models they
            // set up beside the default (ask-30d56720f6; off with `ACPMUX_SPARE_PERSONAL=0`).
            b"cloud_warm_home" => {
                #[derive(serde::Deserialize)]
                #[serde(rename_all = "camelCase")]
                struct Request {
                    #[serde(default)]
                    acpmux_home: Option<String>,
                    /// A number, as Swift's `JSONValue` sends one (tests; the clock when absent).
                    #[serde(default)]
                    now_ms: Option<f64>,
                }
                use cmux_cloud_start_core::spare_shapes;
                let request: Request = serde_json::from_slice(request).map_err(|_| ERR_INVALID)?;
                #[allow(
                    clippy::cast_possible_truncation,
                    clippy::cast_sign_loss,
                    reason = "a non-negative f64 millisecond clock; `as u64` saturates past u64::MAX, which is the wanted bound"
                )]
                let now_ms = request.now_ms.map(|ms| ms.max(0.0) as u64).unwrap_or_else(|| {
                    std::time::SystemTime::now()
                        .duration_since(std::time::UNIX_EPOCH)
                        .map(|d| u64::try_from(d.as_millis()).unwrap_or(u64::MAX))
                        .unwrap_or(0)
                });
                let switch = std::env::var(spare_shapes::SWITCH).ok();
                let shapes = request.acpmux_home.as_deref().map_or_else(Vec::new, |home| {
                    spare_shapes::read(std::path::Path::new(home), now_ms, switch.as_deref())
                });
                serde_json::to_vec(&serde_json::json!({
                    "command": spare_shapes::warm_home_command(&shapes), "shapes": shapes,
                }))
                .map_err(|_| ERR_INVALID)?
            }
            b"cloud_folder_too_broad" => {
                #[derive(serde::Deserialize)]
                struct Request {
                    root: String,
                    home: String,
                }
                let request: Request = serde_json::from_slice(request).map_err(|_| ERR_INVALID)?;
                let too_broad =
                    cmux_cloud_start_core::start::too_broad(&request.root, &request.home);
                serde_json::to_vec(&serde_json::json!({ "tooBroad": too_broad }))
                    .map_err(|_| ERR_INVALID)?
            }
            b"cloud_vm_kind" => {
                #[derive(serde::Deserialize)]
                #[serde(rename_all = "camelCase")]
                struct Request {
                    #[serde(default)]
                    vm_kind: Option<String>,
                }
                let request: Request = serde_json::from_slice(request).map_err(|_| ERR_INVALID)?;
                serde_json::to_vec(&cmux_cloud_start_core::vm_kind::read(
                    request.vm_kind.as_deref(),
                ))
                .map_err(|_| ERR_INVALID)?
            }
            b"focus_type_ahead" => {
                let request: cmux_focus_core::wire::TypeAheadRequest =
                    serde_json::from_slice(request).map_err(|_| ERR_INVALID)?;
                serde_json::to_vec(&cmux_focus_core::wire::type_ahead(&request))
                    .map_err(|_| ERR_INVALID)?
            }
            b"focus_child_window_key" => {
                let request: cmux_focus_core::wire::ChildWindowKeyRequest =
                    serde_json::from_slice(request).map_err(|_| ERR_INVALID)?;
                serde_json::to_vec(&cmux_focus_core::wire::child_window_key(&request))
                    .map_err(|_| ERR_INVALID)?
            }
            b"focus_escape_exit" => {
                let request: cmux_focus_core::wire::EscapeExitRequest =
                    serde_json::from_slice(request).map_err(|_| ERR_INVALID)?;
                serde_json::to_vec(&cmux_focus_core::wire::escape_exit(&request))
                    .map_err(|_| ERR_INVALID)?
            }
            b"focus_work_context" => {
                let request: cmux_focus_core::wire::WorkContextRequest =
                    serde_json::from_slice(request).map_err(|_| ERR_INVALID)?;
                serde_json::to_vec(&cmux_focus_core::wire::work_context(&request))
                    .map_err(|_| ERR_INVALID)?
            }
            b"focus_input_world" => {
                let request: cmux_focus_core::invariants::Observation =
                    serde_json::from_slice(request).map_err(|_| ERR_INVALID)?;
                serde_json::to_vec(&cmux_focus_core::wire::input_world(&request))
                    .map_err(|_| ERR_INVALID)?
            }
            b"focus_input_step" => {
                let request: cmux_focus_core::wire::InputStepRequest =
                    serde_json::from_slice(request).map_err(|_| ERR_INVALID)?;
                serde_json::to_vec(&cmux_focus_core::wire::input_step(&request))
                    .map_err(|_| ERR_INVALID)?
            }
            b"focus_debug_window" => {
                let request: cmux_focus_core::wire::DebugWindowRequest =
                    serde_json::from_slice(request).map_err(|_| ERR_INVALID)?;
                serde_json::to_vec(&cmux_focus_core::wire::debug_window(&request))
                    .map_err(|_| ERR_INVALID)?
            }
            b"agent_cursor_visibility" => {
                let request: cmux_focus_core::wire::AgentCursorVisibilityRequest =
                    serde_json::from_slice(request).map_err(|_| ERR_INVALID)?;
                serde_json::to_vec(&cmux_focus_core::wire::agent_cursor_visibility(&request))
                    .map_err(|_| ERR_INVALID)?
            }
            b"mobile_host" => cmux_mobile_host_core::respond(request).map_err(|_| ERR_INVALID)?,
            // Every other op is an op module's (build.rs): adding a module adds no line here.
            operation => match respond_op_module(operation, request) {
                Some(answer) => answer?,
                None => return Err(ERR_INVALID),
            },
        };
        Ok(response)
    }));
    match result {
        Ok(Ok(response)) => unsafe { write_output(&response, output, output_capacity, output_len) },
        Ok(Err(code)) => code,
        Err(_) => ERR_PANIC,
    }
}

/// A new sidebar mirror. Free it with `cmux_sidebar_mirror_free`.
#[unsafe(no_mangle)]
pub extern "C" fn cmux_sidebar_mirror_new() -> *mut Mirror {
    Box::into_raw(Box::new(Mirror::new()))
}

/// # Safety
///
/// `mirror` is null or a pointer from `cmux_sidebar_mirror_new` that was not
/// freed yet.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_sidebar_mirror_free(mirror: *mut Mirror) {
    if !mirror.is_null() {
        // SAFETY: the pointer came from Box::into_raw and is freed once.
        drop(unsafe { Box::from_raw(mirror) });
    }
}

/// Frees a string a `cmux_sidebar_mirror_*` call returned.
///
/// # Safety
///
/// `text` is null or a string from a `cmux_sidebar_mirror_*` call that was
/// not freed yet.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_sidebar_mirror_string_free(text: *mut c_char) {
    if !text.is_null() {
        // SAFETY: the pointer came from CString::into_raw and is freed once.
        drop(unsafe { CString::from_raw(text) });
    }
}

/// Run one mirror call: JSON in, a newly allocated NUL-terminated JSON
/// string out (null only for a null mirror or input pointer).
unsafe fn mirror_call(
    mirror: *mut Mirror,
    json: *const u8,
    json_len: usize,
    call: fn(&mut Mirror, &[u8]) -> serde_json::Value,
) -> *mut c_char {
    if mirror.is_null() {
        return std::ptr::null_mut();
    }
    let Some(bytes) = (unsafe { input(json, json_len) }) else { return std::ptr::null_mut() };
    // SAFETY: a live mirror from cmux_sidebar_mirror_new, used by one thread.
    let mirror = unsafe { &mut *mirror };
    let value = catch_unwind(AssertUnwindSafe(|| call(mirror, bytes)))
        .unwrap_or_else(|_| serde_json::json!({"error": "panic"}));
    let text = serde_json::to_string(&value).unwrap_or_else(|_| "{}".into());
    CString::new(text).map_or(std::ptr::null_mut(), CString::into_raw)
}

macro_rules! mirror_entry {
    ($(#[$doc:meta])* $name:ident => $method:ident) => {
        $(#[$doc])*
        ///
        /// # Safety
        ///
        /// `mirror` is a live mirror, `json` points to `json_len` readable
        /// bytes (or is null with length 0). Free the result with
        /// `cmux_sidebar_mirror_string_free`.
        #[unsafe(no_mangle)]
        pub unsafe extern "C" fn $name(
            mirror: *mut Mirror,
            json: *const u8,
            json_len: usize,
        ) -> *mut c_char {
            unsafe { mirror_call(mirror, json, json_len, Mirror::$method) }
        }
    };
}

mirror_entry!(
    /// The confirmed document from `sidebar.get`.
    cmux_sidebar_mirror_load => load
);
mirror_entry!(
    /// One echoed `session.events` batch; drops the matching pending intent.
    cmux_sidebar_mirror_apply_batch => apply_batch
);
mirror_entry!(
    /// One optimistic intent: `{"ok":true,"inverse":[...]}` or `{"refusal":...}`.
    cmux_sidebar_mirror_apply_intent => apply_intent
);
mirror_entry!(
    /// The flat rows of a view request.
    cmux_sidebar_mirror_view => view
);
mirror_entry!(
    /// The acceptance table of a drag over the rows of the last view.
    cmux_sidebar_mirror_drag_begin => drag_begin
);
mirror_entry!(
    /// The sections a view request's rows draw (`sidebar_doc::project`).
    cmux_sidebar_mirror_project => project
);
mirror_entry!(
    /// The ops of New Subgroup or of a remote group (`sidebar_doc::plan`).
    cmux_sidebar_mirror_plan => plan
);

/// Run one typed mirror call: JSON in, a pointer to a reply the mirror owns
/// (valid until the next typed call on it, or its free); null for a null
/// mirror or input pointer, or a panic.
unsafe fn typed_call<T>(
    mirror: *mut Mirror,
    json: *const u8,
    json_len: usize,
    call: fn(&mut Mirror, &[u8]) -> *const T,
) -> *const T {
    if mirror.is_null() {
        return std::ptr::null();
    }
    let Some(bytes) = (unsafe { input(json, json_len) }) else { return std::ptr::null() };
    // SAFETY: a live mirror from cmux_sidebar_mirror_new, used by one thread.
    let mirror = unsafe { &mut *mirror };
    catch_unwind(AssertUnwindSafe(|| call(mirror, bytes))).unwrap_or(std::ptr::null())
}

macro_rules! typed_entry {
    ($(#[$doc:meta])* $name:ident => $method:ident -> $reply:ty) => {
        $(#[$doc])*
        ///
        /// # Safety
        ///
        /// `mirror` is a live mirror, `json` points to `json_len` readable
        /// bytes (or is null with length 0). The reply belongs to the
        /// mirror: read it before the next typed call; never free it.
        #[unsafe(no_mangle)]
        pub unsafe extern "C" fn $name(
            mirror: *mut Mirror,
            json: *const u8,
            json_len: usize,
        ) -> *const $reply {
            unsafe { typed_call(mirror, json, json_len, Mirror::$method) }
        }
    };
}

typed_entry!(
    /// `load` with a typed status.
    cmux_sidebar_mirror_load_typed => load_typed -> typed::CReply
);
typed_entry!(
    /// `apply_batch` with a typed status.
    cmux_sidebar_mirror_apply_batch_typed => apply_batch_typed -> typed::CReply
);
typed_entry!(
    /// `apply_intent` with a typed status and the stamped ops (JSON bytes).
    cmux_sidebar_mirror_apply_intent_typed => apply_intent_typed -> typed::CReply
);
typed_entry!(
    /// `view` as fixed-size rows and one string table.
    cmux_sidebar_mirror_view_typed => view_typed -> typed::CRows
);
typed_entry!(
    /// `drag_begin` as fixed-size entries and one string table.
    cmux_sidebar_mirror_drag_begin_typed => drag_begin_typed -> typed::CAcceptanceTable
);

#[cfg(test)]
mod op_module_tests {
    use super::OP_MODULES;

    /// Every string literal in the crate's sources and tests that could name an op.
    fn names_in(dir: &std::path::Path, names: &mut Vec<String>) {
        for entry in std::fs::read_dir(dir).expect("read dir") {
            let path = entry.expect("entry").path();
            if path.is_dir() {
                names_in(&path, names);
            } else if path.extension().is_some_and(|e| e == "rs" || e == "swift" || e == "c") {
                let text = std::fs::read_to_string(&path).expect("read source");
                for (index, piece) in text.split('"').enumerate() {
                    let op_like = !piece.is_empty()
                        && piece.starts_with(|c: char| c.is_ascii_lowercase())
                        && piece
                            .chars()
                            .all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == '_');
                    if index % 2 == 1 && op_like {
                        names.push(piece.to_owned());
                    }
                }
            }
        }
    }

    /// The dispatch asks the op modules in name order; no op is two modules', so that order
    /// never decides which one answers. A new module whose ops overlap another's narrows its
    /// own `handles` (or the other's) until this passes.
    #[test]
    fn op_modules_are_disjoint() {
        let root = std::path::Path::new(env!("CARGO_MANIFEST_DIR"));
        let mut names = Vec::new();
        names_in(&root.join("src"), &mut names);
        names_in(&root.join("tests"), &mut names);
        names.sort();
        names.dedup();
        assert!(names.len() > 100, "found {} op-like names", names.len());
        for name in &names {
            let owners: Vec<&str> = OP_MODULES
                .iter()
                .filter(|(_, handles)| handles(name.as_bytes()))
                .map(|(module, _)| *module)
                .collect();
            assert!(owners.len() <= 1, "`{name}` is handled by {owners:?}");
        }
    }

    #[test]
    fn op_modules_are_listed() {
        let modules: Vec<&str> = OP_MODULES.iter().map(|(module, _)| *module).collect();
        for module in
            ["cloud_bootstrap", "cloud_machine", "pane_focus", "tab_strip", "window_rules"]
        {
            assert!(modules.contains(&module), "{module} missing from {modules:?}");
        }
        assert!(
            !modules.contains(&"window_rules_desktop"),
            "a #[path] submodule is not an op module"
        );
        // `mobile_host` is an arm of its own before the op modules; none of them answers it.
        assert!(OP_MODULES.iter().all(|(_, handles)| !handles(b"mobile_host")));
    }
}
