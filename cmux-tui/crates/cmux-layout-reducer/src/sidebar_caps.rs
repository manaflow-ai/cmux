//! Per-project caps and the "Needs you" section of cmux NEXT's sidebar.
//!
//! Leo, 2026-11-10: "just make it configurable. And we can have a sort of
//! same default. You know, ChatGPT shows like 5 or so per project and then a
//! show more. ... there's obviously no show more for like all projects ...
//! you also don't want to make a, like a scrollable area within a scrollable
//! area". And on what floats: "the working sessions, that's probably too noisy
//! to be constantly sifting up to the top ... But like the ones that are blue
//! that are done, I think we can probably turn that on. Likewise with the
//! yellow ... projects, they don't jump out of projects, they stay within
//! themselves". Spec: leo-workspace design/sidebar.md, "Per-project caps".
//!
//! A project (a sidebar group) lists its members in its own order. It shows
//! the first [`ProjectCaps::cap`] quiet members, then a "Show N more" row that
//! reveals [`SHOW_MORE_STEP`] more at a time and reads "Show less" once every
//! member shows. An active member always shows, whatever the cap: pinned in
//! the project, waiting on you (yellow), finished unread (blue), running, or
//! kept by the caller (the selected row, a row being renamed or dragged). With
//! floating on, yellow then blue rise to the top of their project, below the
//! pinned members; running members never move unless "Include working" is on.
//! Nothing here crosses a project: the top level keeps the order the person
//! gave it.
//!
//! Cost: the caller passes only the active members (sparse, ascending), so a
//! projection's work is the rows it returns plus the active ones, the same
//! for a project of 30 and of 3,000 quiet chats (`project_rows` never walks
//! the hidden rows). `needs_you` reads the active rows only, too.

/// How many more rows one "Show N more" press reveals (never all at once).
pub const SHOW_MORE_STEP: u32 = 20;
/// The rows the "Needs you" section lists before its "N more" row.
pub const NEEDS_YOU_LIMIT: u32 = 3;
/// The default chats per project (ChatGPT's five).
pub const DEFAULT_CAP: u32 = 5;
/// The caps the setting and the per-project menu offer; 0 is All.
pub const CAP_CHOICES: [u32; 4] = [3, 5, 10, 0];

/// A member's state, as bits (the C ABI passes these bytes as they are).
pub mod flag {
    /// Pinned in its project: first, in its own order.
    pub const PINNED: u8 = 1;
    /// Waiting on you: a question or a permission (yellow).
    pub const WAITING: u8 = 2;
    /// Finished, output unread (blue).
    pub const UNREAD: u8 = 4;
    /// A turn runs (the spinner).
    pub const RUNNING: u8 = 8;
    /// Shows in place whatever the cap: the selected row, a renamed or dragged one.
    pub const KEEP: u8 = 16;
}

/// One active member: its index in the project's own order and its [`flag`]s.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Active {
    pub index: u32,
    pub flags: u8,
}

/// What decides a project's rows.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct ProjectCaps {
    /// Quiet members shown before "Show N more"; 0 shows all (no row).
    pub cap: u32,
    /// Rows the person revealed past the cap with "Show N more" (a multiple of
    /// [`SHOW_MORE_STEP`] as stored; any value works).
    pub revealed: u32,
    /// Yellow then blue rise to the top of the project ("Float to top within project").
    pub floats: bool,
    /// Running members count as active for floating ("Include working").
    pub include_working: bool,
}

impl Default for ProjectCaps {
    fn default() -> Self {
        ProjectCaps { cap: DEFAULT_CAP, revealed: 0, floats: true, include_working: false }
    }
}

/// The row after a project's members.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Tail {
    /// Every member shows and nothing was revealed: no row.
    None,
    /// "Show `next` more": `hidden` members are behind it, `next` of them come
    /// with one press.
    ShowMore { hidden: u32, next: u32 },
    /// Revealed past the cap and nothing left behind: "Show less".
    ShowLess,
}

/// A project's rows: member indices in drawn order, then the tail row.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ProjectRows {
    pub rows: Vec<u32>,
    pub tail: Tail,
    /// Members the floating moved above their place (yellow, blue), for the
    /// caller's motion: they slide together with the rest, never pop in.
    pub floated: u32,
    /// Steps the projection took (members visited): the bench's
    /// host-independent cost, the same for 30 and 3,000 quiet chats.
    pub work: u32,
}

fn floats_up(flags: u8, caps: &ProjectCaps) -> Option<u8> {
    if !caps.floats || flags & flag::PINNED != 0 {
        return None;
    }
    if flags & flag::WAITING != 0 {
        Some(0)
    } else if flags & flag::UNREAD != 0 {
        Some(1)
    } else if caps.include_working && flags & flag::RUNNING != 0 {
        Some(2)
    } else {
        None
    }
}

fn is_active(flags: u8) -> bool {
    flags & (flag::PINNED | flag::WAITING | flag::UNREAD | flag::RUNNING | flag::KEEP) != 0
}

/// The rows of a project of `count` members whose active members are `active`
/// (ascending by index, each index below `count`; quiet members are left out).
/// Out-of-order, repeated or out-of-range entries are ignored.
pub fn project_rows(count: u32, active: &[Active], caps: &ProjectCaps) -> ProjectRows {
    // The valid active members, ascending and unique.
    let mut actives: Vec<Active> = Vec::with_capacity(active.len());
    for a in active {
        if a.index < count
            && is_active(a.flags)
            && actives.last().is_none_or(|last| last.index < a.index)
        {
            actives.push(*a);
        }
    }
    let quiet_total = count - actives.len() as u32;
    let mut limit = if caps.cap == 0 {
        quiet_total
    } else {
        caps.cap.saturating_add(caps.revealed).min(quiet_total)
    };
    // One row over the limit shows whole: a row that hides one row saves nothing.
    if quiet_total == limit.saturating_add(1) {
        limit = quiet_total;
    }

    let mut rows: Vec<u32> = Vec::with_capacity(actives.len() + limit as usize + 1);
    // Pinned first, then yellow, blue (and running, with Include working).
    rows.extend(actives.iter().filter(|a| a.flags & flag::PINNED != 0).map(|a| a.index));
    let mut floated = 0;
    for rank in 0..3u8 {
        for a in &actives {
            if floats_up(a.flags, caps) == Some(rank) {
                rows.push(a.index);
                floated += 1;
            }
        }
    }
    // Then the rest in place: active members that did not float, and the first
    // `limit` quiet ones. The walk stops at the limit-th quiet member; active
    // members past it come straight from `actives`, never by walking the
    // hidden rows.
    let stays = |a: &Active| a.flags & flag::PINNED == 0 && floats_up(a.flags, caps).is_none();
    let mut next_active = 0usize;
    let mut quiet_shown = 0u32;
    let mut index = 0u32;
    while quiet_shown < limit && index < count {
        if let Some(a) = actives.get(next_active).filter(|a| a.index == index) {
            if stays(a) {
                rows.push(index);
            }
            next_active += 1;
        } else {
            rows.push(index);
            quiet_shown += 1;
        }
        index += 1;
    }
    let work = index.saturating_add(u32::try_from(actives.len()).unwrap_or(u32::MAX));
    rows.extend(
        actives.get(next_active..).unwrap_or_default().iter().filter(|a| stays(a)).map(|a| a.index),
    );

    let hidden = quiet_total - quiet_shown;
    let tail = if hidden > 0 {
        // One row past a step would show anyway (a list one row over its limit shows whole), so the
        // label counts it: "Show 21 more" reveals 21, never "Show 20 more" revealing 21.
        let next = if hidden <= SHOW_MORE_STEP.saturating_add(1) { hidden } else { SHOW_MORE_STEP };
        Tail::ShowMore { hidden, next }
    } else if caps.cap != 0 && caps.revealed > 0 && quiet_total > caps.cap.saturating_add(1) {
        Tail::ShowLess
    } else {
        Tail::None
    };
    ProjectRows { rows, tail, floated, work }
}

/// What a press of the tail row stores as the project's revealed count.
pub fn after_press(tail: Tail, caps: &ProjectCaps) -> u32 {
    match tail {
        Tail::ShowMore { next, .. } => caps.revealed.saturating_add(next),
        Tail::ShowLess | Tail::None => 0,
    }
}

/// The "Needs you" section: `rows` are the sidebar's active rows in drawn
/// order (every project and loose workspace; `index` is the row's place,
/// ascending). Yellow first, then blue, then running with `include_working`,
/// each in drawn order; at most `limit` (0: [`NEEDS_YOU_LIMIT`]).
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct NeedsYou {
    pub rows: Vec<u32>,
    /// Rows past the limit: the "N more" row.
    pub more: u32,
}

pub fn needs_you(rows: &[Active], include_working: bool, limit: u32) -> NeedsYou {
    let limit = if limit == 0 { NEEDS_YOU_LIMIT } else { limit };
    let caps = ProjectCaps { floats: true, include_working, ..ProjectCaps::default() };
    let rank = |a: &Active| floats_up(a.flags & !flag::PINNED, &caps);
    let mut result = NeedsYou::default();
    let mut total = 0u32;
    for wanted in 0..3u8 {
        for a in rows.iter().filter(|a| rank(a) == Some(wanted)) {
            total += 1;
            if (result.rows.len() as u32) < limit {
                result.rows.push(a.index);
            }
        }
    }
    result.more = total - result.rows.len() as u32;
    result
}

/// A cap as the setting and the per-project menu store it: "3", "5", "10" or
/// "all" (also the numbers, 0 for all). `None` for anything else.
pub fn read_cap(value: &serde_json::Value) -> Option<u32> {
    let cap = match value {
        serde_json::Value::String(text) if text == "all" => 0,
        serde_json::Value::String(text) => text.parse::<u32>().ok()?,
        serde_json::Value::Number(number) => u32::try_from(number.as_u64()?).ok()?,
        _ => return None,
    };
    CAP_CHOICES.contains(&cap).then_some(cap)
}

#[cfg(test)]
#[path = "sidebar_caps_tests.rs"]
mod tests;
