//! The C ABI of cmux-motion's hover rules for the macOS app
//! (`include/cmux_motion_ffi.h`, the "Hover" section; Swift module
//! `CCmuxMotionFFI`): the hover card machine, tooltip hover intent, the safe
//! triangle, the row card's placement and the hover timing tokens. The app's
//! `HoverCardCoordinator` and `TooltipPresenter` keep only the hit tests, the
//! timer and the panel; the rules live once, in cmux-motion (`hover`).
//!
//! Per pointer move, in process, no allocation and no JSON: the app keeps each
//! machine as a plain struct and passes it by pointer with a batch of typed
//! events. The struct forms and their total conversions are
//! `cmux_motion::hover::c` (tested in the cmux-tui workspace); these
//! functions only check pointers. None panics on any input.

use cmux_motion::hover::c::{
    CmuxHoverCardEffect, CmuxHoverCardEvent, CmuxHoverCardMachine, CmuxHoverEscapeGeometry,
    CmuxHoverIntent, CmuxHoverIntentEffect, CmuxHoverTiming, ZONE_OUTSIDE, intent_call,
    reduce_card_batch, row_alignment, zone,
};
use cmux_motion::hover::{
    HoverCardEscapeGeometry, HoverPoint, HoverRect, duration_from_seconds, hover_card_room,
    hover_edge_gap, hover_row_band,
};

/// Writes every hover timing token (nanoseconds) to `out`. False for a null `out`.
///
/// # Safety
/// `out` is null or points to a writable `CmuxHoverTiming`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_hover_timing(out: *mut CmuxHoverTiming) -> bool {
    if out.is_null() {
        return false;
    }
    // SAFETY: `out` is non-null and writable per the contract above.
    unsafe { out.write(CmuxHoverTiming::standard()) };
    true
}

/// A tunable's seconds as nanoseconds: at least zero, rounded to the millisecond.
#[unsafe(no_mangle)]
pub extern "C" fn cmux_hover_duration_from_seconds(seconds: f64) -> i64 {
    duration_from_seconds(seconds)
}

/// Writes a new hover card machine with the default windows to `out`. False for a null `out`.
///
/// # Safety
/// `out` is null or points to a writable `CmuxHoverCardMachine`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_hover_card_machine_init(out: *mut CmuxHoverCardMachine) -> bool {
    if out.is_null() {
        return false;
    }
    // SAFETY: `out` is non-null and writable per the contract above.
    unsafe { out.write(CmuxHoverCardMachine::new()) };
    true
}

/// Applies `events` in order to `machine` and writes their effects, in
/// order, to `effects`; `*effect_count` gets how many. Returns how many
/// events it applied: it stops before an event while fewer than 3 effect
/// slots are left, so the caller passes the rest again. 0 (and no change)
/// for a null `machine` or `effect_count`, or null arrays with a count.
///
/// # Safety
/// `machine` points to a valid, writable `CmuxHoverCardMachine`; `events`
/// points to `event_count` readable events (or is null with 0); `effects`
/// points to `effect_capacity` writable effects (or is null with 0);
/// `effect_count` is writable.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_hover_card_reduce(
    machine: *mut CmuxHoverCardMachine,
    events: *const CmuxHoverCardEvent,
    event_count: usize,
    effects: *mut CmuxHoverCardEffect,
    effect_capacity: usize,
    effect_count: *mut usize,
) -> usize {
    if machine.is_null() || effect_count.is_null() {
        return 0;
    }
    if (events.is_null() && event_count > 0) || (effects.is_null() && effect_capacity > 0) {
        // SAFETY: `effect_count` is non-null and writable per the contract.
        unsafe { effect_count.write(0) };
        return 0;
    }
    let events: &[CmuxHoverCardEvent] = if event_count == 0 {
        &[]
    } else {
        // SAFETY: non-null and `event_count` readable events per the contract.
        unsafe { std::slice::from_raw_parts(events, event_count) }
    };
    let out: &mut [CmuxHoverCardEffect] = if effect_capacity == 0 {
        &mut []
    } else {
        // SAFETY: non-null and `effect_capacity` writable effects per the contract.
        unsafe { std::slice::from_raw_parts_mut(effects, effect_capacity) }
    };
    // SAFETY: `machine` is non-null, valid and writable per the contract.
    let machine = unsafe { &mut *machine };
    let result = reduce_card_batch(machine, events, out);
    // SAFETY: `effect_count` is non-null and writable per the contract.
    unsafe { effect_count.write(result.effects) };
    result.events
}

/// Writes a new tooltip hover intent (`delay` and `warm_for` in ns) to `out`.
/// False for a null `out`.
///
/// # Safety
/// `out` is null or points to a writable `CmuxHoverIntent`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_hover_intent_init(
    delay: i64,
    warm_for: i64,
    out: *mut CmuxHoverIntent,
) -> bool {
    if out.is_null() {
        return false;
    }
    // SAFETY: `out` is non-null and writable per the contract above.
    unsafe { out.write(CmuxHoverIntent::new(delay, warm_for)) };
    true
}

/// One call on `intent` (`call` 0 hover: `has_target`, `value` the target;
/// 1 deadline: `value` the token; 2 dismiss). Writes its effects to `effects`
/// and returns how many; 0 and no change for a null pointer, an unknown call
/// or `capacity` under 2.
///
/// # Safety
/// `intent` is null or points to a valid, writable `CmuxHoverIntent`;
/// `effects` is null or points to `capacity` writable effects.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_hover_intent_call(
    intent: *mut CmuxHoverIntent,
    call: u8,
    has_target: bool,
    value: u64,
    effects: *mut CmuxHoverIntentEffect,
    capacity: usize,
) -> usize {
    if intent.is_null() || effects.is_null() || capacity == 0 {
        return 0;
    }
    // SAFETY: non-null and `capacity` writable effects per the contract.
    let out = unsafe { std::slice::from_raw_parts_mut(effects, capacity) };
    // SAFETY: `intent` is non-null, valid and writable per the contract.
    let intent = unsafe { &mut *intent };
    intent_call(intent, call, has_target, value, out)
}

/// Whether a pointer moving from `from` to `to` heads for `card` (the safe
/// triangle); false without both points.
#[unsafe(no_mangle)]
pub extern "C" fn cmux_hover_is_aimed_at(
    card: HoverRect,
    has_from: bool,
    from: HoverPoint,
    has_to: bool,
    to: HoverPoint,
) -> bool {
    card.aimed_at(has_from.then_some(from), has_to.then_some(to))
}

/// The row card's geometry for `anchor` at `width` x `height`, kept inside
/// `visible` when `has_visible`, its near edge `gap` off the anchor when
/// `has_gap` (else 0), on device pixels of `scale`, `alignment` 0 top or 1
/// middle. False for a null `out`.
///
/// # Safety
/// `out` is null or points to a writable `CmuxHoverEscapeGeometry`.
// One C call per placement; a request struct would only move the same fields.
#[allow(clippy::too_many_arguments)]
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_hover_escape_geometry(
    anchor: HoverRect,
    width: f64,
    height: f64,
    has_visible: bool,
    visible: HoverRect,
    scale: f64,
    has_gap: bool,
    gap: f64,
    alignment: u8,
    out: *mut CmuxHoverEscapeGeometry,
) -> bool {
    if out.is_null() {
        return false;
    }
    let geometry = HoverCardEscapeGeometry::new(
        anchor,
        (width, height),
        has_visible.then_some(visible),
        scale,
        has_gap.then_some(gap),
        row_alignment(alignment),
    );
    // SAFETY: `out` is non-null and writable per the contract above.
    unsafe { out.write(CmuxHoverEscapeGeometry::from(geometry)) };
    true
}

/// The zone of `point` for `geometry`: 0 row, 1 card, 2 escape, 3 gap, 4
/// outside (also for a null `geometry`).
///
/// # Safety
/// `geometry` is null or points to a readable `CmuxHoverEscapeGeometry`.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_hover_escape_zone(
    geometry: *const CmuxHoverEscapeGeometry,
    point: HoverPoint,
) -> u8 {
    if geometry.is_null() {
        return ZONE_OUTSIDE;
    }
    // SAFETY: `geometry` is non-null and readable per the contract above.
    zone(unsafe { geometry.read() }, point)
}

/// The room a row's card rests in: `visible` less `margin`, between the
/// window's bottom and top when `has_window`.
#[unsafe(no_mangle)]
pub extern "C" fn cmux_hover_card_room(
    visible: HoverRect,
    has_window: bool,
    window: HoverRect,
    margin: f64,
) -> HoverRect {
    hover_card_room(visible, has_window.then_some(window), margin)
}

/// A sidebar row's anchor: `row`'s height across `column`'s width.
#[unsafe(no_mangle)]
pub extern "C" fn cmux_hover_row_band(row: HoverRect, column: HoverRect) -> HoverRect {
    hover_row_band(row, column)
}

/// One device pixel of `scale` (at least 1): the room beside a `.beside` card.
#[unsafe(no_mangle)]
pub extern "C" fn cmux_hover_edge_gap(scale: f64) -> f64 {
    hover_edge_gap(scale)
}
