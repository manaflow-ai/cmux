//! Part of `Hub`; see `hub/mod.rs`. The sr2 gateway's model-pool pressure, as the fleet reads it
//! (RFD cmuxterm-hq#24665 sections 3.2 and 3.6): a new Claude session started while Claude is
//! short is warned and pointed at Codex, and an idle background lane sleeps sooner while the pool
//! sheds. Nothing is refused for it, and a live conversation never changes harness.
//!
//! On 2026-11-24 the sr2 pool's Codex had about 30 idle accounts all day while Claude had 0 to 2,
//! and Claude sessions met 529s and "no non-exhausted claude accounts" 503s. Leo: "fix 529s
//! properly with better designs".
//!
//! The verdict is leo-workspace `tools/sr2_pool.py` `pressure()`, which that tool writes into its
//! cache of the gateway's `/_subrouter/health` (`SR2_POOL_CACHE`, else
//! `~/.cache/sr2-pool/health.json`) each time lane placement or the elastic fleet reads it:
//! `{"level": "ok"|"tight"|"shed", "why", "codex_room"}`. acpmux reads that file, never the
//! gateway, and needs no credential. A file older than [`STALE`] or without a verdict means
//! no pressure: everything behaves as before.
//!
//! - Admission (`admission.rs`): a Claude-family create while the level is tight or shed starts
//!   as asked, with a warning (`poolPressure` in `_meta.acpmux.admission`) that suggests
//!   `-m codex` when Codex has room.
//! - Idle (`idle.rs`, `host_level.rs` `idle_period`): while the level is shed, a session that
//!   is no person's, coordinator's, Chief's, leader's or priority lane's (the subrouter
//!   priority `background`, `subrouter_priority.rs`) hibernates after [`SHED_IDLE`] instead of the
//!   full idle period, logged with the cause `pool-pressure`. The elastic fleet holds scale-up
//!   while the pool sheds (`tools/lane_elastic.py`), so sleeping lanes free host room for the
//!   work that waits. Its next prompt resumes it as any hibernated chat.

use super::*;
use std::path::{Path, PathBuf};
use std::time::{Duration, Instant};

/// A verdict older than this is no verdict (sr2_pool's own `STALE`).
const STALE: Duration = Duration::from_secs(600);
/// How long a read of the cache file is kept: the idle pass asks on every wake.
const KEEP: Duration = Duration::from_secs(20);
/// The idle period of a background session while the pool sheds.
pub(super) const SHED_IDLE: Duration = Duration::from_secs(30);

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub(crate) enum Level {
    Tight,
    Shed,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub(crate) struct Pressure {
    pub level: Level,
    pub why: String,
    /// Codex is healthy enough to take new work (sr2_pool `codex_healthy`).
    pub codex_room: bool,
    /// Codex's `usable/total`, when known.
    pub codex: Option<String>,
}

/// The verdict in an sr2_pool cache document read at `now` (Unix seconds); None when there is
/// none, it is `ok`, or the document is older than [`STALE`].
pub(crate) fn parse(doc: &Value, now: f64) -> Option<Pressure> {
    let at = doc.get("at").and_then(Value::as_f64)?;
    if now - at > STALE.as_secs_f64() {
        return None;
    }
    let p = doc.get("pressure")?;
    let level = match p.get("level").and_then(Value::as_str)? {
        "tight" => Level::Tight,
        "shed" => Level::Shed,
        _ => return None,
    };
    Some(Pressure {
        level,
        why: p.get("why").and_then(Value::as_str).unwrap_or("the sr2 pool is short").to_owned(),
        codex_room: p.get("codex_room").and_then(Value::as_bool) == Some(true),
        codex: p.get("codex").and_then(Value::as_str).map(str::to_owned),
    })
}

/// Where sr2_pool keeps its cache.
fn cache_path() -> Option<PathBuf> {
    if let Some(p) = std::env::var_os("SR2_POOL_CACHE").filter(|p| !p.is_empty()) {
        return Some(PathBuf::from(p));
    }
    std::env::var_os("HOME")
        .filter(|h| !h.is_empty())
        .map(|h| PathBuf::from(h).join(".cache/sr2-pool/health.json"))
}

/// The verdict in the file at `path` now.
pub(crate) fn read_at(path: &Path) -> Option<Pressure> {
    let bytes = std::fs::read(path).ok()?;
    let doc: Value = serde_json::from_slice(&bytes).ok()?;
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|d| d.as_secs_f64())
        .unwrap_or(0.0);
    parse(&doc, now)
}

/// The current verdict, read from the cache file at most once per [`KEEP`]: one small file
/// read, never a network call.
pub(crate) fn current() -> Option<Pressure> {
    static LAST: std::sync::Mutex<Option<(Instant, Option<Pressure>)>> =
        std::sync::Mutex::new(None);
    let mut last = LAST.lock().unwrap_or_else(|e| e.into_inner());
    if let Some((at, kept)) = last.as_ref()
        && at.elapsed() < KEEP
    {
        return kept.clone();
    }
    let fresh = cache_path().and_then(|p| read_at(&p));
    *last = Some((Instant::now(), fresh.clone()));
    fresh
}

/// Whether harness family `family` draws on the sr2 pool's Claude accounts.
pub(crate) fn is_claude(family: &str) -> bool {
    family.trim().to_ascii_lowercase().starts_with("claude")
}

/// The admission warning of a Claude create under `p`.
pub(crate) fn warning(p: &Pressure) -> String {
    let state = match p.level {
        Level::Tight => "tight",
        Level::Shed => "shedding",
    };
    let next = if p.codex_room {
        let codex = p.codex.as_deref().map(|c| format!(" ({c} usable)")).unwrap_or_default();
        format!(
            " Codex has room{codex}: a new lane that need not be Claude can start with `acpmux new -m codex`."
        )
    } else {
        String::new()
    };
    format!(
        "the sr2 model pool's Claude is {state} ({}); started on Claude as asked, and its turns may wait or meet 529s.{next}",
        p.why
    )
}

/// The `poolPressure` admission field.
pub(crate) fn field(p: &Pressure) -> Value {
    json!({
        "level": match p.level { Level::Tight => "tight", Level::Shed => "shed" },
        "why": p.why,
        "codexRoom": p.codex_room,
    })
}

/// Whether a session of subrouter priority `priority` sleeps after [`SHED_IDLE`] under `p`.
pub(crate) fn sleeps_sooner(p: Option<&Pressure>, priority: &str) -> bool {
    p.is_some_and(|p| p.level == Level::Shed) && priority == crate::subrouter_priority::BACKGROUND
}

impl Hub {
    /// The ids live chats report to (`lane.reportsTo`): leaders, which stay up. Kept for
    /// [`KEEP`], so an idle pass under pressure costs one walk of the live chats, not one per
    /// chat.
    fn pool_pressure_leaders(&self) -> Arc<std::collections::HashSet<String>> {
        static LAST: std::sync::Mutex<Option<(Instant, Arc<std::collections::HashSet<String>>)>> =
            std::sync::Mutex::new(None);
        let mut last = LAST.lock().unwrap_or_else(|e| e.into_inner());
        if let Some((at, kept)) = last.as_ref()
            && at.elapsed() < KEEP
        {
            return kept.clone();
        }
        let leaders: std::collections::HashSet<String> = self
            .live_session_handles()
            .iter()
            .filter_map(|s| s.meta().tags.get(super::REPORTS_TO_TAG).map(|t| t.value.clone()))
            .collect();
        let leaders = Arc::new(leaders);
        *last = Some((Instant::now(), leaders.clone()));
        leaders
    }

    /// Whether `session` hibernates after [`SHED_IDLE`] now (module docs): the pool sheds and
    /// it is background work. The pressure is read first, so with none this costs one cached
    /// read.
    pub(super) fn pool_pressure_sleeps(&self, session: &Session) -> bool {
        let pressure = current();
        if !sleeps_sooner(pressure.as_ref(), crate::subrouter_priority::BACKGROUND) {
            return false;
        }
        let meta = session.meta();
        let leads = usize::from(self.pool_pressure_leaders().contains(&session.id));
        let tag = meta.tags.get(crate::subrouter_priority::TAG).map(|t| t.value.as_str());
        let priority = crate::subrouter_priority::classify_role(
            &meta.name,
            self.for_a_person(session),
            leads,
            tag,
        );
        sleeps_sooner(pressure.as_ref(), priority)
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn doc(level: &str, at: f64, room: bool) -> Value {
        json!({"at": at, "pool": {}, "pressure": {
            "level": level, "why": "claude 1/209 usable", "codex_room": room, "codex": "30/47"}})
    }

    #[test]
    fn reads_the_verdict_sr2_pool_wrote_and_drops_a_stale_or_ok_one() {
        let now = 1_000_000.0;
        let shed = parse(&doc("shed", now - 30.0, true), now).unwrap();
        assert_eq!(shed.level, Level::Shed);
        assert!(shed.codex_room);
        assert_eq!(shed.codex.as_deref(), Some("30/47"));
        assert_eq!(parse(&doc("tight", now, false), now).unwrap().level, Level::Tight);
        assert_eq!(parse(&doc("ok", now, true), now), None);
        assert_eq!(parse(&doc("shed", now - 601.0, true), now), None, "stale: no pressure");
        assert_eq!(parse(&json!({"at": now, "pool": {}}), now), None, "an older sr2_pool");
    }

    #[test]
    fn reads_the_cache_file() {
        let dir = std::env::temp_dir().join(format!("acpmux-pool-{}", uuid::Uuid::now_v7()));
        std::fs::create_dir_all(&dir).unwrap();
        let path = dir.join("health.json");
        let now = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_secs_f64();
        std::fs::write(&path, doc("shed", now, true).to_string()).unwrap();
        assert_eq!(read_at(&path).map(|p| p.level), Some(Level::Shed));
        std::fs::write(&path, b"{\"at\":").unwrap();
        assert_eq!(read_at(&path), None, "a torn file is no pressure");
        assert_eq!(read_at(&dir.join("missing.json")), None);
        let _ = std::fs::remove_dir_all(&dir);
    }

    #[test]
    fn the_warning_suggests_codex_only_when_it_has_room() {
        let now = 5.0;
        let room = parse(&doc("tight", now, true), now).unwrap();
        let text = warning(&room);
        assert!(text.contains("Claude is tight (claude 1/209 usable)"), "{text}");
        assert!(text.contains("acpmux new -m codex") && text.contains("30/47"), "{text}");
        assert!(text.contains("started on Claude as asked"), "never a refusal: {text}");
        let none = parse(&doc("shed", now, false), now).unwrap();
        assert!(!warning(&none).contains("codex"), "{}", warning(&none));
        assert_eq!(
            field(&room),
            json!({"level": "tight", "why": "claude 1/209 usable", "codexRoom": true})
        );
    }

    #[test]
    fn only_background_work_sleeps_sooner_and_only_while_the_pool_sheds() {
        let now = 5.0;
        let shed = parse(&doc("shed", now, true), now);
        let tight = parse(&doc("tight", now, true), now);
        use crate::subrouter_priority::{BACKGROUND, INTERACTIVE};
        assert!(sleeps_sooner(shed.as_ref(), BACKGROUND));
        assert!(!sleeps_sooner(shed.as_ref(), INTERACTIVE), "person, coordinator, Chief: never");
        assert!(!sleeps_sooner(tight.as_ref(), BACKGROUND), "tight only warns");
        assert!(!sleeps_sooner(None, BACKGROUND));
        assert!(is_claude("claude") && is_claude("claude-sr2") && !is_claude("codex"));
    }
}
