//! AutoSize's notices as chat rows (RFD 0080 piece 4, RFD 0133 items 1 and 2): every time the
//! server grows, shrinks or holds an agent's cloud computer it sends the creator's live sockets one
//! ephemeral `cloud.machine.autosize` frame (cmux-platform `machines/AutoSizeEvent.ts`), and the
//! chat shows it as one row from the computer, not from the agent. Leo, 2026-11-23: "we can size
//! it properly for you as your agent does things"; RFD 0133: "tell the person every time it acts".
//!
//! Pure: the app hands the frame's `data` ([`Event`]) and the rows it already shows, and [`push`]
//! answers the rows to show now. The UI never derives a row: it reads [`Row`] and picks its look by
//! the enum values. The server's one `line` is carried as the row's text, so the copy stays the
//! server's and a new hold code still reads.
//!
//! Rules:
//! - Only wire version 1 is drawn; a newer frame is left out, never half-read.
//! - A frame seen twice (same record, kind and time) is one row.
//! - A hold that repeats (same code and shape as the newest row) folds into it with a count, so a
//!   machine held at the plan's limit every 10 minutes is one row, not a column of them.
//! - The upgrade button is offered only on `at_plan_limit` with a plan above, and only to the
//!   machine's creator (the frame goes only to the creator, but a shared view must not offer it).
//! - At most [`MAX_ROWS`] rows are kept per chat, the newest.

use serde::{Deserialize, Serialize};

pub mod feed;

use crate::computer_status::{Reason, Shape, Why};

/// The wire version this build draws (`AUTOSIZE_EVENT_VERSION`).
pub const VERSION: u64 = 1;
/// The frame's event name on the Cloud wire.
pub const EVENT: &str = "cloud.machine.autosize";
/// Rows kept per chat.
pub const MAX_ROWS: usize = 50;

/// What AutoSize did.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Kind {
    Grow,
    Shrink,
    Hold,
}

/// Why it acted, in the server's words (`AutoSizeEventReason`).
#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum Cause {
    Memory,
    Cpu,
    Disk,
    Oom,
    HeavyTask,
    Idle,
    #[serde(other)]
    Unknown,
}

/// A machine's shape with its hourly rate while awake (`AutoSizeEventShape`).
#[derive(Clone, Copy, Debug, PartialEq, Serialize, Deserialize)]
pub struct EventShape {
    pub vcpu: f64,
    pub mem_gib: f64,
    #[serde(default)]
    pub disk_gib: f64,
    #[serde(default)]
    pub hourly_usd: f64,
}

/// The plan that lifts a grow held at the plan's limit (`AutoSizeUpgrade`).
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Upgrade {
    pub plan: String,
    pub label: String,
    pub max_vcpu: f64,
    #[serde(rename = "maxMemGiB")]
    pub max_mem_gib: f64,
    #[serde(default, rename = "maxDiskGiB")]
    pub max_disk_gib: f64,
}

/// One `cloud.machine.autosize` frame's `data` (`AutoSizeEventData`).
#[derive(Clone, Debug, PartialEq, Deserialize)]
pub struct Event {
    pub v: u64,
    pub machine: String,
    pub record: String,
    #[serde(default)]
    pub creator: Option<String>,
    pub kind: Kind,
    #[serde(default)]
    pub hold: Option<String>,
    pub reason: Cause,
    #[serde(default)]
    pub reason_text: String,
    pub from: EventShape,
    #[serde(default)]
    pub to: Option<EventShape>,
    pub hourly_usd: f64,
    #[serde(default)]
    pub upgrade: Option<Upgrade>,
    pub line: String,
    /// Milliseconds since the epoch (the server's `Date.now()`).
    pub at: f64,
}

/// A hold, by its code.
#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case", tag = "code")]
pub enum Hold {
    /// The plan caps the size: the row offers the upgrade when there is a plan above.
    AtPlanLimit,
    /// The largest machine there is.
    AtMaxSize,
    /// The person's own size cap.
    UserCap,
    /// Any other code, kept as sent.
    Other { name: String },
}

impl Hold {
    fn of(code: &str) -> Self {
        match code {
            "at_plan_limit" => Hold::AtPlanLimit,
            "at_max_size" => Hold::AtMaxSize,
            "user_cap" => Hold::UserCap,
            other => Hold::Other { name: other.to_owned() },
        }
    }
}

/// The row's one button, if any.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case", tag = "do")]
pub enum Offer {
    /// "Upgrade to Pro for 8 vCPU / 32 GiB".
    Upgrade { plan: String, label: String, vcpu: f64, mem_gib: f64 },
}

/// One chat row.
#[derive(Clone, Debug, PartialEq, Serialize, Deserialize)]
pub struct Row {
    /// Stable across a resend: `record:kind:at`.
    pub key: String,
    pub machine: String,
    pub record: String,
    pub kind: Kind,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub hold: Option<Hold>,
    pub cause: Cause,
    pub cause_text: String,
    pub from: EventShape,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub to: Option<EventShape>,
    /// The rate from now on.
    pub hourly_usd: f64,
    /// The change in the hourly rate: positive on a grow, negative on a shrink, 0 on a hold.
    pub rate_change_usd: f64,
    /// The server's one line, shown as the row's text.
    pub line: String,
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub offer: Option<Offer>,
    pub at_ms: u64,
    /// A repeated hold's newest time; equal to `at_ms` until one repeats.
    pub last_at_ms: u64,
    /// How many times this row happened (a repeated hold counts up).
    pub count: u32,
}

impl Row {
    /// The shape the computer has now, for the chat header's Size row (`ComputerStatus.shape`).
    pub fn shape_now(&self) -> Shape {
        let now = match (self.kind, self.to) {
            (Kind::Grow | Kind::Shrink, Some(to)) => to,
            _ => self.from,
        };
        Shape { vcpu: now.vcpu, memory_gib: now.mem_gib }
    }

    /// The Why row's reason this row gives, if it is one the header names: a grow for memory.
    pub fn why(&self) -> Option<Why> {
        let grew_for_memory =
            self.kind == Kind::Grow && matches!(self.cause, Cause::Memory | Cause::Oom);
        grew_for_memory.then_some(Why {
            at_ms: self.at_ms,
            reason: Reason::GrewForMemory,
            command: None,
        })
    }
}

fn millis(at: f64) -> u64 {
    if at.is_finite() && at > 0.0 { at as u64 } else { 0 }
}

fn cents(usd: f64) -> f64 {
    (usd * 10_000.0).round() / 10_000.0
}

/// `event` as a row, seen by `viewer` (a user id; `None` is the machine's creator, as the frame
/// goes only to the creator's sockets). `None` for a wire version this build does not draw.
pub fn row(event: &Event, viewer: Option<&str>) -> Option<Row> {
    if event.v != VERSION {
        return None;
    }
    let hold = (event.kind == Kind::Hold).then(|| Hold::of(event.hold.as_deref().unwrap_or("")));
    let is_creator = match (viewer, event.creator.as_deref()) {
        (Some(viewer), Some(creator)) => viewer == creator,
        _ => true,
    };
    let offer = match (&hold, &event.upgrade) {
        (Some(Hold::AtPlanLimit), Some(up)) if is_creator => Some(Offer::Upgrade {
            plan: up.plan.clone(),
            label: up.label.clone(),
            vcpu: up.max_vcpu,
            mem_gib: up.max_mem_gib,
        }),
        _ => None,
    };
    let rate_change_usd = match (event.kind, event.to) {
        (Kind::Grow | Kind::Shrink, Some(to)) => cents(to.hourly_usd - event.from.hourly_usd),
        _ => 0.0,
    };
    let at_ms = millis(event.at);
    let kind_word = match event.kind {
        Kind::Grow => "grow",
        Kind::Shrink => "shrink",
        Kind::Hold => "hold",
    };
    Some(Row {
        key: format!("{}:{kind_word}:{at_ms}", event.record),
        machine: event.machine.clone(),
        record: event.record.clone(),
        kind: event.kind,
        hold,
        cause: event.reason,
        cause_text: event.reason_text.clone(),
        from: event.from,
        to: event.to,
        hourly_usd: event.hourly_usd,
        rate_change_usd,
        line: event.line.clone(),
        offer,
        at_ms,
        last_at_ms: at_ms,
        count: 1,
    })
}

/// Whether `next` repeats `last`: the same hold on the same machine record at the same shape.
fn repeats(last: &Row, next: &Row) -> bool {
    last.kind == Kind::Hold
        && next.kind == Kind::Hold
        && last.record == next.record
        && last.hold == next.hold
        && last.from == next.from
}

/// The rows to show once `next` arrived, oldest first: a resend is dropped, a repeated hold folds
/// into the newest row, and only the newest [`MAX_ROWS`] stay.
pub fn push(mut rows: Vec<Row>, next: Row) -> Vec<Row> {
    if rows.iter().any(|row| row.key == next.key) {
        return rows;
    }
    match rows.last_mut() {
        Some(last) if repeats(last, &next) => {
            last.count = last.count.saturating_add(1);
            last.last_at_ms = last.last_at_ms.max(next.at_ms);
            last.line = next.line;
            last.offer = next.offer;
        }
        _ => rows.push(next),
    }
    let extra = rows.len().saturating_sub(MAX_ROWS);
    rows.drain(..extra);
    rows
}

#[cfg(test)]
#[path = "autosize_row/tests.rs"]
mod tests;
