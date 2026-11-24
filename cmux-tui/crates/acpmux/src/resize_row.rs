//! The chat rows a VM's size shows (cmuxterm-hq RFD 0133, "What the person sees", items 1, 2 and
//! 9): the warning row before or during a job too big for the machine, with **Resize now**,
//! **Run it on a build machine** and **Carry on**, and the AutoSize row after the machine grew,
//! shrank or was held at the plan's limit. The webview draws what this decides (the pane's
//! `ResizeRow.tsx`): which buttons, which size, which plan, the hourly rate, in numbers it formats
//! in the person's language. Pure: the caller hands in the machine's shape, its plan and the
//! event.

use crate::heavy_precheck::{self, Project, Short};
use serde::Serialize;

const GB: u64 = 1_000_000_000;
const GIB: u64 = 1 << 30;

/// A machine size.
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Size {
    pub vcpu: u32,
    #[serde(rename = "memGiB")]
    pub mem_gib: u32,
}

impl Size {
    pub const fn new(vcpu: u32, mem_gib: u32) -> Self {
        Self { vcpu, mem_gib }
    }

    /// The awake rate at this size, in cents an hour: $0.045 per vCPU-hour and $0.0145 per
    /// GiB-hour at every size (RFD 0063, 0133).
    pub fn hourly_cents(self) -> u32 {
        let usd = f64::from(self.vcpu) * heavy_precheck::VCPU_HOUR_USD
            + f64::from(self.mem_gib) * heavy_precheck::GIB_HOUR_USD;
        (usd * 100.0).round() as u32
    }

    fn holds(self, other: Size) -> bool {
        self.vcpu >= other.vcpu && self.mem_gib >= other.mem_gib
    }
}

/// A paid plan and its size ceiling (cmux-platform `Plan.ts`: Plus 4 / 16, Pro 8 / 32, Max 32 / 64).
#[derive(Debug, Clone, Copy, PartialEq, Eq, PartialOrd, Ord, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum Plan {
    Plus,
    Pro,
    Max,
}

impl Plan {
    pub const ALL: [Plan; 3] = [Plan::Plus, Plan::Pro, Plan::Max];

    pub fn ceiling(self) -> Size {
        match self {
            Self::Plus => Size::new(4, 16),
            Self::Pro => Size::new(8, 32),
            Self::Max => Size::new(32, 64),
        }
    }
}

/// The size a resize asks for: RFD 0133's 16 vCPU / 32 GiB, or 32 / 64 for a job that needs
/// more than 32 GiB.
pub const BURST: Size = Size::new(16, 32);
pub const BIG_BURST: Size = Size::new(32, 64);

/// The row's first button.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(tag = "kind", rename_all = "camelCase")]
pub enum First {
    /// **Resize now** to `to`: `POST /v1/machines/:id/resize`, back to the chat's size at the next
    /// pause.
    #[serde(rename_all = "camelCase")]
    Resize { to: Size, hourly_cents: u32 },
    /// **Upgrade to `plan` for its ceiling**: the plan's ceiling is in the way.
    #[serde(rename_all = "camelCase")]
    Upgrade { plan: Plan, to: Size, hourly_cents: u32 },
}

/// The first button for a job that needs `need_mem_gib` on a machine whose plan is `plan`:
/// resize to the burst size, cut to the plan's ceiling when that still holds the memory, else the
/// upgrade to the first plan whose ceiling does.
pub fn first_action(need_mem_gib: u32, plan: Plan) -> First {
    let want = if need_mem_gib > BURST.mem_gib { BIG_BURST } else { BURST };
    let ceiling = plan.ceiling();
    if ceiling.holds(want) {
        return First::Resize { to: want, hourly_cents: want.hourly_cents() };
    }
    if ceiling.mem_gib >= want.mem_gib {
        let to = Size::new(ceiling.vcpu.min(want.vcpu), want.mem_gib);
        return First::Resize { to, hourly_cents: to.hourly_cents() };
    }
    let up =
        Plan::ALL.into_iter().find(|p| p.ceiling().mem_gib >= want.mem_gib).unwrap_or(Plan::Max);
    let to = up.ceiling();
    First::Upgrade { plan: up, to, hourly_cents: to.hourly_cents() }
}

/// Why the warning shows.
#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(tag = "kind", rename_all = "camelCase")]
pub enum Why {
    /// A known-heavy job before it starts (`heavy_precheck`): a project short of its published
    /// minimums.
    #[serde(rename_all = "camelCase")]
    Project {
        project: Project,
        command: String,
        short: Vec<Short>,
        /// Whole GB, as the project publishes them.
        needs_disk_gb: u64,
        needs_memory_gb: Option<u64>,
        disk_free_gb: u64,
        memory_gb: u64,
        /// Hours here and on [`BIG_BURST`] if it fit, and that run's cost in cents (Chromium only).
        #[serde(skip_serializing_if = "Option::is_none")]
        hours_here: Option<f64>,
        #[serde(skip_serializing_if = "Option::is_none")]
        hours_burst: Option<f64>,
        #[serde(skip_serializing_if = "Option::is_none")]
        burst_cents: Option<u32>,
        #[serde(skip_serializing_if = "Option::is_none")]
        burst_vcpu: Option<u32>,
    },
    /// A build in a checkout bigger than free memory times 8.
    #[serde(rename_all = "camelCase")]
    BigCheckout { command: String, checkout_gib: f64, memory_free_gib: f64 },
    /// Memory available under 25%, or CPUs busy for minutes, while a job runs.
    #[serde(rename_all = "camelCase")]
    Pressure { mem_used_gib: f64, mem_total_gib: f64, busy_minutes: Option<u32> },
}

/// The warning row: why, the machine now, and the three buttons (the first decided here; the
/// second and third are always **Run it on a build machine** and **Carry on**).
#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct WarningRow {
    pub why: Why,
    pub now: Size,
    pub first: First,
    /// The size it goes back to at the next pause.
    pub back_to: Size,
}

/// The warning row for a precheck's warning on a machine of `now`'s size under `plan`.
pub fn warning_row(
    warning: &heavy_precheck::Warning,
    shape: &heavy_precheck::Shape,
    now: Size,
    plan: Plan,
) -> WarningRow {
    let need_mem_gib = warning.needs_memory.map_or(0, |b| b.div_ceil(GIB) as u32);
    let why = match warning.project {
        Some(project) => {
            let chromium = project == Project::Chromium;
            let (hours_here, hours_burst) = if chromium {
                (
                    Some(round_hours(
                        heavy_precheck::CHROMIUM_CPU_HOURS / f64::from(now.vcpu.max(1)),
                    )),
                    Some(round_hours(
                        heavy_precheck::CHROMIUM_CPU_HOURS / f64::from(BIG_BURST.vcpu),
                    )),
                )
            } else {
                (None, None)
            };
            let burst_cents = chromium.then(|| {
                let wall = heavy_precheck::CHROMIUM_CPU_HOURS / f64::from(BIG_BURST.vcpu);
                (wall * f64::from(BIG_BURST.hourly_cents())).round() as u32
            });
            Why::Project {
                project,
                command: warning.command.clone(),
                short: warning.short.clone(),
                needs_disk_gb: warning.needs_disk.unwrap_or(0) / GB,
                needs_memory_gb: warning.needs_memory.map(|m| m / GB),
                disk_free_gb: round_div(shape.disk_free, GB),
                memory_gb: round_div(shape.mem_total, GB),
                hours_here,
                hours_burst,
                burst_cents,
                burst_vcpu: chromium.then_some(BIG_BURST.vcpu),
            }
        }
        None => Why::BigCheckout {
            command: warning.command.clone(),
            checkout_gib: tenths(
                warning.needs_memory.unwrap_or(0) as f64
                    * heavy_precheck::CHECKOUT_PER_FREE_MEMORY as f64
                    / GIB as f64,
            ),
            memory_free_gib: tenths(
                shape.mem_available.unwrap_or(shape.mem_total) as f64 / GIB as f64,
            ),
        },
    };
    WarningRow { why, now, first: first_action(need_mem_gib, plan), back_to: now }
}

/// The warning row for memory or CPU pressure during a job (RFD 0133's example: "3.8 of 4 GiB in
/// use, 2 vCPUs busy for 6 minutes").
pub fn pressure_row(
    mem_used: u64,
    mem_total: u64,
    busy_minutes: Option<u32>,
    now: Size,
    plan: Plan,
) -> WarningRow {
    let why = Why::Pressure {
        mem_used_gib: tenths(mem_used as f64 / GIB as f64),
        mem_total_gib: tenths(mem_total as f64 / GIB as f64),
        busy_minutes,
    };
    WarningRow { why, now, first: first_action(now.mem_gib * 2, plan), back_to: now }
}

/// What AutoSize did.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum Act {
    Grew,
    Shrank,
    /// A grow the plan's ceiling held (`at_plan_limit` in cmux-platform's AutoSize).
    HeldAtPlanLimit,
}

/// What made AutoSize act (cmux-platform `AutoSizePolicy.ts`'s signals).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "camelCase")]
pub enum Reason {
    Memory,
    Cpu,
    Disk,
    OomKill,
    Idle,
}

/// One AutoSize event as the chat shows it (RFD 0133 items 1 and 2).
#[derive(Debug, Clone, PartialEq, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct AutoSizeRow {
    pub act: Act,
    pub reason: Reason,
    pub from: Size,
    /// The size now: the new one, or `from` when held.
    pub to: Size,
    pub hourly_cents: u32,
    /// The plan in the way and the size it would allow, when held.
    #[serde(skip_serializing_if = "Option::is_none")]
    pub upgrade: Option<First>,
    /// A grow can be undone at the next pause: the machine goes back to `from` then.
    pub undo_at_pause: bool,
}

/// The row for one AutoSize event under `plan`. `wanted` is the size a held grow asked for.
pub fn autosize_row(
    act: Act,
    reason: Reason,
    from: Size,
    to: Size,
    wanted: Size,
    plan: Plan,
) -> AutoSizeRow {
    let upgrade = (act == Act::HeldAtPlanLimit).then(|| {
        let up = Plan::ALL
            .into_iter()
            .find(|p| {
                *p > plan
                    && p.ceiling()
                        .holds(Size::new(wanted.vcpu.min(p.ceiling().vcpu), wanted.mem_gib))
            })
            .or_else(|| Plan::ALL.into_iter().find(|p| *p > plan))
            .unwrap_or(Plan::Max);
        let size = up.ceiling();
        First::Upgrade { plan: up, to: size, hourly_cents: size.hourly_cents() }
    });
    let to = if act == Act::HeldAtPlanLimit { from } else { to };
    AutoSizeRow {
        act,
        reason,
        from,
        to,
        hourly_cents: to.hourly_cents(),
        upgrade,
        undo_at_pause: act == Act::Grew,
    }
}

/// Whole hours from 10, else up to the next half hour ("20", "1.5").
fn round_hours(h: f64) -> f64 {
    if h >= 10.0 { h.round() } else { (h * 2.0).ceil() / 2.0 }
}

fn round_div(n: u64, d: u64) -> u64 {
    (n as f64 / d as f64).round() as u64
}

fn tenths(x: f64) -> f64 {
    (x * 10.0).round() / 10.0
}

#[cfg(test)]
#[path = "resize_row_tests.rs"]
mod tests;
