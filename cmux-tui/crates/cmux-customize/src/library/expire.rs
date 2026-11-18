//! Experiment layers expire by themselves: nobody has to remember to turn
//! one off (Leo, 2026-11-18, after his NIGHTLY served a PR layer 508 commits
//! behind for days: "Always do these; experiments shouldn't be left hanging
//! like that").
//!
//! ```text
//! a code entry (pr, branch, sha, dir, fork)   on longer than 24 hours: off
//! a pr entry whose PR merged or closed        off (the CLI asks GitHub)
//! a hand-installed web-dev.json overlay       installed 24 hours ago, or refused: off
//! ```
//!
//! An expired entry is turned off with the note `expired: WHY`, the way
//! `library off` turns one off, so what was under it comes back. An
//! expired overlay gets `enabled: false` in web-dev.json, as
//! `web-overlay.sh off` writes it. Each one is recorded in
//! `<state dir>/expired.json` with its one command back, and
//! `cmux customize library status` and `cmux version` say it for a week:
//! `expired: pr-45206 (on 5 days, past 24 hours; back: cmux customize library on pr-45206)`.
//! Turning it back on starts its 24 hours again.

use std::collections::BTreeMap;

use serde::{Deserialize, Serialize};
use serde_json::Value;

use super::Entry;
use super::code::{CodeKind, WebBase, WebTarget};
use super::overlay::age;
use super::text::one_line;
use crate::Customize;

/// How long a code layer or a hand-installed overlay stays on by itself.
pub const MAX_AGE_MS: u64 = 24 * 3_600_000;
/// How long `library status` and `cmux version` keep saying what expired.
pub const SHOWN_MS: u64 = 7 * 24 * 3_600_000;
/// The name a hand-installed web-dev.json overlay goes by here:
/// `cmux customize library on web-dev-overlay` turns it back on.
pub const WEB_DEV_OVERLAY: &str = "web-dev-overlay";
const EXPIRED: &str = "expired.json";

/// What to judge the layers against.
#[derive(Debug, Clone, Default)]
pub struct Expiry {
    pub now_ms: u64,
    /// The web ABI of the app's own pages: an overlay for another is refused.
    pub app_abi: Option<u32>,
    /// PRs known to be merged or closed, with the word for it (`merged`,
    /// `closed`). Empty when nobody asked GitHub: then only age counts.
    pub ended: BTreeMap<u64, String>,
}

/// One layer that expired.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Expired {
    /// The entry (`pr-45206`), or [`WEB_DEV_OVERLAY`].
    pub name: String,
    /// `PR merged`, `on 5 days, past 24 hours`, `refused: abi 4, app 7`.
    pub why: String,
    pub at_ms: u64,
    /// The one command that turns it back on.
    pub back: String,
}

impl Expired {
    /// `pr-45206 (on 5 days, past 24 hours; back: cmux customize library on pr-45206)`.
    pub fn words(&self) -> String {
        format!("{} ({}; back: {})", self.name, self.why, self.back)
    }
}

/// What one expiry pass did.
#[derive(Debug, Clone, Default, PartialEq, Eq, Serialize)]
pub struct Expiring {
    /// What it turned off now.
    pub expired: Vec<Expired>,
    /// What it could not turn off, and why; never an error, so a report
    /// that runs it still reads.
    #[serde(skip_serializing_if = "Vec::is_empty")]
    pub problems: Vec<String>,
}

#[derive(Debug, Clone, Default, Serialize, Deserialize)]
struct ExpiredFile {
    #[serde(default)]
    expired: Vec<Expired>,
    /// The overlay turned back on by hand, and when: its 24 hours count
    /// from then, not from its install.
    #[serde(default, skip_serializing_if = "Option::is_none")]
    overlay_renewed: Option<Renewed>,
}

#[derive(Debug, Clone, Serialize, Deserialize)]
struct Renewed {
    path: String,
    at_ms: u64,
}

impl Customize {
    /// Turns off every layer past its bound (see the module) and records
    /// each. What `cmux customize library expire` runs (the app runs it at
    /// launch, with `ended` from GitHub), and what `library status`, `library
    /// list` and `cmux version` run first, with age alone.
    pub fn expire_stale(&self, expiry: &Expiry, origin: &str) -> Expiring {
        let now = expiry.now_ms;
        let mut out = Expiring::default();
        if let Ok(library) = self.read_library() {
            let stale: Vec<(String, String)> = library
                .entries
                .iter()
                .filter(|entry| entry.on)
                .filter_map(|entry| Some((entry.name().to_owned(), stale_why(entry, expiry)?)))
                .collect();
            if !stale.is_empty() {
                let names: Vec<&str> = stale.iter().map(|(name, _)| name.as_str()).collect();
                let label = format!("library: expired {}", names.join(", "));
                let change = self.library_change(&label, origin, now, |library| {
                    for entry in library.entries.iter_mut() {
                        let Some((_, why)) = stale.iter().find(|(name, _)| name == entry.name())
                        else {
                            continue;
                        };
                        entry.on = false;
                        if let Some(code) = entry.code.as_mut() {
                            code.note = one_line(&format!("expired: {why}"));
                        }
                    }
                    Ok(())
                });
                match change {
                    Ok(_) => out.expired.extend(stale.into_iter().map(|(name, why)| Expired {
                        back: format!("cmux customize library on {name}"),
                        name,
                        why,
                        at_ms: now,
                    })),
                    Err(error) => out.problems.push(format!(
                        "{} {} past {} but stay on: {error}",
                        names.join(", "),
                        if names.len() == 1 { "is" } else { "are" },
                        age(MAX_AGE_MS)
                    )),
                }
            }
        }
        let mut file = self.read_expired();
        if let Some(overlay) = self.overlay(expiry.app_abi).filter(|o| !o.library && o.enabled) {
            let renewed = file
                .overlay_renewed
                .as_ref()
                .filter(|renewed| renewed.path == overlay.path)
                .map(|renewed| renewed.at_ms);
            let since = overlay.installed_ms.max(renewed);
            let why = if overlay.refused && renewed.is_none() {
                Some(format!(
                    "refused: abi {}, app {}",
                    overlay.abi.unwrap_or_default(),
                    overlay.app_abi.unwrap_or_default()
                ))
            } else {
                since
                    .filter(|at| now.saturating_sub(*at) > MAX_AGE_MS)
                    .map(|at| format!("installed {} ago, past {}", age(now - at), age(MAX_AGE_MS)))
            };
            if let Some(why) = why {
                let off = WebBase {
                    overlay: Some(Value::String(overlay.path.clone())),
                    enabled: Some(Value::Bool(false)),
                    no_file: false,
                };
                match self.write_web_dev(&WebTarget::Base, &off) {
                    Ok(()) => out.expired.push(Expired {
                        name: WEB_DEV_OVERLAY.to_owned(),
                        why,
                        at_ms: now,
                        back: format!("cmux customize library on {WEB_DEV_OVERLAY}"),
                    }),
                    Err(error) => out
                        .problems
                        .push(format!("web-dev.json overlay {} stays on: {error}", overlay.path)),
                }
            }
        }
        if !out.expired.is_empty() {
            for expired in &out.expired {
                file.expired.retain(|old| old.name != expired.name);
                file.expired.push(expired.clone());
            }
            file.expired.retain(|old| now.saturating_sub(old.at_ms) < SHOWN_MS);
            if let Err(error) = self.write_expired(&file) {
                out.problems.push(format!("{EXPIRED} was not written: {error}"));
            }
        }
        out
    }

    /// What expired in the last week and is still off, oldest first.
    pub fn expired(&self, now_ms: u64) -> Vec<Expired> {
        let file = self.read_expired();
        if file.expired.is_empty() {
            return Vec::new();
        }
        // One turned back on some other way (`use pr:N` again,
        // `web-overlay.sh install`) is no longer expired.
        let on: Vec<String> = self
            .read_library()
            .map(|library| {
                library
                    .entries
                    .iter()
                    .filter(|entry| entry.on)
                    .map(|entry| entry.name().to_owned())
                    .collect()
            })
            .unwrap_or_default();
        let overlay_on =
            self.overlay(None).is_some_and(|overlay| !overlay.library && overlay.enabled);
        file.expired
            .into_iter()
            .filter(|expired| now_ms.saturating_sub(expired.at_ms) < SHOWN_MS)
            .filter(|expired| {
                if expired.name == WEB_DEV_OVERLAY {
                    !overlay_on
                } else {
                    !on.contains(&expired.name)
                }
            })
            .collect()
    }

    /// `cmux customize library on web-dev-overlay`: the hand-installed
    /// overlay web-dev.json names is on again (`enabled: true`), for another
    /// 24 hours from now.
    pub fn renew_overlay(&self, now_ms: u64) -> Result<String, crate::Error> {
        let overlay = self.overlay(None).filter(|overlay| !overlay.library).ok_or_else(|| {
            crate::Error::Library(
                "web-dev.json names no hand-installed overlay; `scripts/cmux-next/web-overlay.sh install` puts one there".to_owned(),
            )
        })?;
        let on = WebBase {
            overlay: Some(Value::String(overlay.path.clone())),
            enabled: Some(Value::Bool(true)),
            no_file: false,
        };
        self.write_web_dev(&WebTarget::Base, &on)?;
        let mut file = self.read_expired();
        file.expired.retain(|old| old.name != WEB_DEV_OVERLAY);
        file.overlay_renewed = Some(Renewed { path: overlay.path.clone(), at_ms: now_ms });
        self.write_expired(&file)?;
        Ok(overlay.path)
    }

    fn read_expired(&self) -> ExpiredFile {
        std::fs::read(self.roots().state_dir.join(EXPIRED))
            .ok()
            .and_then(|bytes| serde_json::from_slice(&bytes).ok())
            .unwrap_or_default()
    }

    fn write_expired(&self, file: &ExpiredFile) -> Result<(), crate::Error> {
        std::fs::create_dir_all(&self.roots().state_dir)?;
        let mut text = serde_json::to_string_pretty(file).map_err(std::io::Error::other)?;
        text.push('\n');
        cmux_config::fsio::write_atomic(&self.roots().state_dir.join(EXPIRED), text.as_bytes())?;
        Ok(())
    }
}

/// Why code entry `entry`, which is on, should be off now; `None` while it
/// is within its bound, and for every entry that is not code.
fn stale_why(entry: &Entry, expiry: &Expiry) -> Option<String> {
    let code = entry.code.as_ref()?;
    if code.kind == CodeKind::Pr
        && let Some(ended) = expiry.ended.get(&code.pr)
    {
        return Some(format!("PR {ended}"));
    }
    let since = entry.on_ms.or(entry.added_ms)?;
    let on_for = expiry.now_ms.saturating_sub(since);
    (on_for > MAX_AGE_MS).then(|| format!("on {}, past {}", age(on_for), age(MAX_AGE_MS)))
}
