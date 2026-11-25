//! A Claude account's plan usage limits at rest, for `_acpmux/account/usage` (Settings > Agents >
//! Harnesses, under each account): Claude Code reports its 5-hour and weekly windows only during a
//! turn (`claude_stdio/usage_limits.rs`), so the account's are the ones its chats last saved
//! (each session's `usage_limits`), joined by the login folder the chat runs in (Leo, 2026-11-23,
//! the feature map's `usage-per-account`: "Per-account 5-hour and weekly limits").
//!
//! The windows carry no time they were seen, so per window id the newest is the one with the
//! latest `resetsAt` (a later window), and within one window the highest `usedPercent` (usage
//! only grows until its reset). A window whose reset has passed is left out: what it reads now is
//! unknown, never shown as stale use. With them, `lastCacheMiss`: the newest prompt cache miss
//! (and its likely cause) of those chats, for the account row's hover line ("the last cache-miss
//! cause"). Reads only the metas in memory; starts nothing.

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

use serde_json::{Value, json};

use super::Hub;

/// The folder a Claude chat with no `CLAUDE_CONFIG_DIR` keeps its login and conversations in.
fn default_claude_home() -> Option<PathBuf> {
    dirs::home_dir().map(|h| h.join(".claude"))
}

/// `home` (None: the CLI's default) as one comparable folder.
fn claude_home(home: Option<&Path>) -> Option<PathBuf> {
    let home = home.map(Path::to_path_buf).or_else(default_claude_home)?;
    let text = home.to_string_lossy();
    let trimmed = text.trim_end_matches('/');
    Some(PathBuf::from(if trimmed.is_empty() { "/" } else { trimmed }))
}

/// The newest of each window across `saved` (each a session's `usageLimits`) still open at
/// `now_secs`, in a stable order (5-hour, weekly, then the others by id); its `plan` if one names
/// it. None when no window is known.
pub(crate) fn freshest_windows<'a>(
    saved: impl IntoIterator<Item = &'a Value>,
    now_secs: i64,
) -> Option<Value> {
    let mut best: BTreeMap<String, Value> = BTreeMap::new();
    let mut plan: Option<Value> = None;
    let key = |w: &Value| {
        let resets = w.get("resetsAt").and_then(Value::as_i64).unwrap_or(0);
        let used = w.get("usedPercent").and_then(Value::as_f64).unwrap_or(0.0);
        (resets, used)
    };
    for limits in saved {
        if plan.is_none() {
            plan = limits.get("plan").filter(|p| p.is_string()).cloned();
        }
        for w in limits.get("windows").and_then(Value::as_array).into_iter().flatten() {
            let Some(id) = w.get("id").and_then(Value::as_str) else { continue };
            if w.get("usedPercent").and_then(Value::as_f64).is_none() {
                continue;
            }
            if w.get("resetsAt").and_then(Value::as_i64).is_some_and(|at| at <= now_secs) {
                continue;
            }
            let newer = best.get(id).is_none_or(|old| {
                let (a, b) = (key(w), key(old));
                a.0 > b.0 || (a.0 == b.0 && a.1 > b.1)
            });
            if newer {
                best.insert(id.to_owned(), w.clone());
            }
        }
    }
    if best.is_empty() {
        return None;
    }
    let rank = |id: &str| match id {
        "session" => 0,
        "weekly" => 1,
        _ => 2,
    };
    let mut windows: Vec<(String, Value)> = best.into_iter().collect();
    windows.sort_by(|(a, _), (b, _)| rank(a).cmp(&rank(b)).then_with(|| a.cmp(b)));
    let mut out = json!({"windows": windows.into_iter().map(|(_, w)| w).collect::<Vec<_>>()});
    if let Some(plan) = plan {
        out["plan"] = plan;
    }
    Some(out)
}

/// The newest of the chats' last prompt cache misses (`_meta.acpmux.cacheMiss` of each saved
/// `usage_update`, `{cause, at}`, `claude_stdio/prompt_cache.rs`): the one with the latest `at`.
pub(crate) fn newest_miss<'a>(misses: impl IntoIterator<Item = &'a Value>) -> Option<Value> {
    let at = |m: &Value| m.get("at").and_then(Value::as_u64).filter(|at| *at > 0);
    misses
        .into_iter()
        .filter(|m| at(m).is_some() && m.get("cause").is_some_and(Value::is_string))
        .max_by_key(|m| at(m))
        .map(|m| json!({"cause": m["cause"], "at": m["at"]}))
}

impl Hub {
    /// The plan usage limits of the Claude login in `home` (None: the CLI's own, `~/.claude`), from
    /// the chats here that run in it ([`freshest_windows`]), with `lastCacheMiss`, the newest
    /// prompt cache miss among them ([`newest_miss`]), when one is known. None when the chats
    /// reported neither.
    pub(crate) async fn claude_account_usage(
        &self,
        home: Option<&Path>,
        now_secs: i64,
    ) -> Option<Value> {
        let want = claude_home(home)?;
        let mut saved = Vec::new();
        let mut misses = Vec::new();
        for session in self.session_handles() {
            // Cheap first: only chats that saved limits or a miss are read further.
            let (limits, miss) = session.read_meta(|m| {
                let miss =
                    m.usage.as_ref().and_then(|u| u.pointer("/_meta/acpmux/cacheMiss")).cloned();
                (m.usage_limits.clone(), miss)
            });
            if limits.is_none() && miss.is_none() {
                continue;
            }
            let meta = session.meta();
            let family = {
                let cfg = self.config.read().await;
                match cfg.profile(&meta.harness) {
                    Some(profile) => crate::config::derive_family(&meta.harness, profile),
                    None => meta.family.clone().unwrap_or_default(),
                }
            };
            if family != "claude" {
                continue;
            }
            let (_, env) = self.harness_env(&meta).await;
            let runs_in = crate::route_account::current_home(&meta, "claude", &env);
            if claude_home(runs_in.as_deref()).as_ref() != Some(&want) {
                continue;
            }
            saved.extend(limits);
            misses.extend(miss);
        }
        let miss = newest_miss(&misses);
        let mut usage = freshest_windows(&saved, now_secs);
        if let Some(miss) = miss {
            usage.get_or_insert_with(|| json!({"windows": []}))["lastCacheMiss"] = miss;
        }
        usage
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn w(id: &str, used: f64, resets: Option<i64>) -> Value {
        let mut w = json!({"id": id, "usedPercent": used});
        if let Some(at) = resets {
            w["resetsAt"] = json!(at);
        }
        w
    }

    #[test]
    fn the_newest_window_wins_and_a_passed_one_is_left_out() {
        let now = 1_000;
        let older =
            json!({"windows": [w("weekly", 60.0, Some(5_000)), w("session", 90.0, Some(900))]});
        let newer =
            json!({"windows": [w("session", 12.0, Some(2_000)), w("weekly", 55.0, Some(5_000))]});
        let got = freshest_windows([&older, &newer], now).unwrap();
        // The 5-hour window that reset at 900 is gone; the one resetting at 2000 is newer.
        // Within the same weekly window, the higher use is the later reading.
        assert_eq!(
            got,
            json!({"windows": [w("session", 12.0, Some(2_000)), w("weekly", 60.0, Some(5_000))]})
        );
    }

    #[test]
    fn windows_come_in_a_stable_order_and_nothing_known_is_none() {
        let a = json!({"windows": [w("weekly_opus", 3.0, None), w("weekly", 4.0, None), w("session", 5.0, None)], "plan": "max"});
        let got = freshest_windows([&a], 0).unwrap();
        let ids: Vec<&str> =
            got["windows"].as_array().unwrap().iter().map(|w| w["id"].as_str().unwrap()).collect();
        assert_eq!(ids, ["session", "weekly", "weekly_opus"]);
        assert_eq!(got["plan"], "max");
        assert_eq!(freshest_windows([&json!({"windows": []})], 0), None);
        assert_eq!(freshest_windows([&json!({"windows": [w("session", 99.0, Some(1))]})], 5), None);
        assert_eq!(freshest_windows(std::iter::empty(), 0), None);
    }

    #[test]
    fn the_newest_miss_is_the_latest_one_with_a_cause() {
        let old = json!({"cause": "expired", "at": 100});
        let new = json!({"cause": "model", "at": 300});
        let bad = json!({"at": 900});
        let zero = json!({"cause": "effort", "at": 0});
        assert_eq!(newest_miss([&old, &bad, &new, &zero]), Some(new.clone()));
        assert_eq!(newest_miss([&bad, &zero]), None);
        assert_eq!(newest_miss(std::iter::empty()), None);
    }

    #[test]
    fn the_default_home_and_its_spelled_out_folder_are_one_account() {
        let spelled = default_claude_home().unwrap();
        let with_slash = PathBuf::from(format!("{}/", spelled.display()));
        assert_eq!(claude_home(None), claude_home(Some(&spelled)));
        assert_eq!(claude_home(None), claude_home(Some(&with_slash)));
        assert_ne!(claude_home(None), claude_home(Some(Path::new("/tmp/claude-2"))));
    }
}
