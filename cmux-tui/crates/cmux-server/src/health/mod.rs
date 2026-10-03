//! The health role (server.md 9): probes fill `Facts`, the pure reducer
//! `cmux_server_core::health::reduce` turns them into alerts and feed
//! posts, and [`HealthRole::wake_at_ms`] gives the next one-shot deadline.
//! There is no interval loop: the owner of the role re-probes on a probe
//! event or at that deadline, nothing else.

pub mod inhibit;
pub mod probe;

use std::path::Path;

use cmux_server_core::health::{
    AlertSet, DiskFacts, Facts, HealthSettings, HostId, InhibitFacts, Post, reduce,
};
use cmux_server_core::layout::Layout;
use cmux_server_core::{InstallMode, Platform};

use crate::fsx;
use crate::process::Runner;

/// Where alerts go. Until the lane 9 feed API exists, the server posts
/// through the local daemon; this seam switches without other changes.
pub trait FeedSink {
    fn post(&self, post: &Post);
}

/// What the caller knows that no probe can read.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ProbeInput {
    /// The link to the control plane is connected (unpaired: false).
    pub link_up: bool,
    /// Linux: the inhibitors the role holds (or would get, for a one-shot
    /// check).
    pub inhibitors: Option<InhibitFacts>,
}

/// Reads every probe once.
pub fn collect(layout: &Layout, host_id: HostId, runner: &dyn Runner, input: &ProbeInput) -> Facts {
    let mut facts = Facts::unknown(host_id, layout.platform, layout.mode);
    facts.link_up = input.link_up;
    facts.disk = probe::disk(&fsx::local(&layout.state));
    if layout.platform == Platform::Linux {
        facts.power = probe::power(Path::new("/sys/class/power_supply"));
        facts.has_route = probe::has_default_route(Path::new("/proc")).unwrap_or(true);
        if layout.mode == InstallMode::User {
            facts.inhibitors = input.inhibitors;
            if let Ok(user) = crate::host::current_user() {
                facts.linger = crate::service::linger_state(runner, &user);
            }
        }
    }
    facts
}

const MIN_RECHECK_MS: u64 = 60_000;
const MAX_RECHECK_MS: u64 = 30 * 60_000;

/// The delay until the next disk re-check (server.md 9.2): headroom to the
/// warning line divided by the observed write rate, clamped to 1 to 30
/// minutes; 30 minutes when free space is not shrinking.
pub fn disk_recheck_ms(
    settings: &HealthSettings,
    previous: Option<(u64, DiskFacts)>,
    now_ms: u64,
    disk: DiskFacts,
) -> u64 {
    let Some((then, before)) = previous else { return MAX_RECHECK_MS };
    let elapsed = now_ms.saturating_sub(then);
    let used = before.free_bytes.saturating_sub(disk.free_bytes);
    if elapsed == 0 || used == 0 {
        return MAX_RECHECK_MS;
    }
    let line = settings.disk_warning_line(disk.total_bytes);
    let headroom = disk.free_bytes.saturating_sub(line);
    let delay = u128::from(headroom) * u128::from(elapsed) / u128::from(used);
    (delay.min(u128::from(MAX_RECHECK_MS)) as u64).max(MIN_RECHECK_MS)
}

/// The role's state: the alert set and the last disk sample.
#[derive(Default)]
pub struct HealthRole {
    alerts: AlertSet,
    last_disk: Option<(u64, DiskFacts)>,
    disk_wake: Option<u64>,
}

impl HealthRole {
    pub fn new() -> HealthRole {
        HealthRole::default()
    }

    pub fn alerts(&self) -> &AlertSet {
        &self.alerts
    }

    /// Feeds one set of facts to the reducer and posts the result.
    pub fn observe(&mut self, facts: &Facts, now_ms: u64, sink: &dyn FeedSink) -> Vec<Post> {
        let (next, posts) = reduce(&self.alerts, facts, now_ms);
        self.alerts = next;
        self.disk_wake = facts.disk.map(|disk| {
            let delay = disk_recheck_ms(&facts.settings, self.last_disk, now_ms, disk);
            self.last_disk = Some((now_ms, disk));
            now_ms.saturating_add(delay)
        });
        for post in &posts {
            sink.post(post);
        }
        posts
    }

    /// The next one-shot deadline: a delayed check, a lock or backup
    /// deadline from the reducer, or the disk re-check.
    pub fn wake_at_ms(&self) -> Option<u64> {
        match (self.alerts.wake_at_ms(), self.disk_wake) {
            (Some(a), Some(b)) => Some(a.min(b)),
            (a, b) => a.or(b),
        }
    }
}

/// Keeps posts in memory (tests, the one-shot CLI).
#[derive(Default)]
pub struct MemorySink {
    pub posts: std::sync::Mutex<Vec<Post>>,
}

impl FeedSink for MemorySink {
    fn post(&self, post: &Post) {
        self.posts.lock().expect("posts").push(post.clone());
    }
}
