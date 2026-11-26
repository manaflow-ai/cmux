//! Getting back to a setup that loads, for every customization (Leo,
//! 2026-11-19: "make sure you can recover and stuff. for all
//! customizations").
//!
//! ```text
//! one broken file     its newest version a generation holds that loads (Restore)
//! the whole setup     every code layer and hand overlay off, and the newest
//!                     generation whose files all load made live (Recover)
//! ```
//!
//! Nothing is lost on the way: a restored file's broken text is moved into
//! `<state dir>/doctor/removed/<ms>/` first, and a recover keeps what was
//! live as its own generation, so `cmux customize rollback N` brings it back.

use std::collections::BTreeMap;

use serde::Serialize;
use serde_json::Value;

use super::super::code::{WebBase, WebTarget};
use super::super::expire::Expiry;
use crate::store::Generation;
use crate::tree::SETTINGS;
use crate::{Customize, Error, tree, validate};

/// How far back a recover looks for a setup that loads.
const GENERATIONS_LOOKED_AT: usize = 50;

/// What a recover would do, as the notice says it before anyone asks.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct RecoverPlan {
    /// Code layers that are on, top first: turned off.
    pub layers: Vec<String>,
    /// A hand-installed web-dev.json overlay that is on: turned off.
    pub overlay: bool,
    /// The generation made live, when files that are live do not load.
    pub generation: Option<u32>,
    /// That generation's label and when it was made.
    pub generation_label: Option<String>,
    /// One line: `Turns pr-45206 off and puts back generation 12 (compact sidebar)`.
    pub said: String,
}

/// What a recover did.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct Recovery {
    pub turned_off: Vec<String>,
    pub overlay_off: bool,
    /// The generation now live.
    pub restored: Option<u32>,
    /// What was live, kept: `cmux customize rollback N` brings it back.
    pub kept_as: Option<u32>,
    pub said: Vec<String>,
}

impl Customize {
    /// What [`Customize::doctor_recover`] would do now; `None` when the
    /// setup already loads with no code layer or hand overlay on.
    pub fn recover_plan(&self, expiry: &Expiry) -> Option<RecoverPlan> {
        let layers = self.code_layers_on();
        let overlay = self.overlay(expiry.app_abi).is_some_and(|o| !o.library && o.enabled);
        let target = if self.live_files_fail() { self.good_generation() } else { None };
        if layers.is_empty() && !overlay && target.is_none() {
            return None;
        }
        let mut parts = Vec::new();
        if !layers.is_empty() {
            parts.push(format!("turns {} off", layers.join(", ")));
        }
        if overlay {
            parts.push("turns the web-dev overlay off".to_owned());
        }
        if let Some(target) = &target {
            parts.push(format!("puts back generation {} ({})", target.n, target.label));
        }
        let said = format!("Recover {}; what is live now is kept.", parts.join(", "));
        Some(RecoverPlan {
            layers,
            overlay,
            generation: target.as_ref().map(|target| target.n),
            generation_label: target.map(|target| target.label),
            said,
        })
    }

    /// Back to a setup that loads: every code layer and hand overlay off,
    /// and when live files do not load, the newest generation whose files
    /// all do. What was live is kept as a generation first.
    pub fn doctor_recover(&self, expiry: &Expiry, origin: &str) -> Result<Recovery, Error> {
        let now = expiry.now_ms;
        let mut out = Recovery {
            turned_off: Vec::new(),
            overlay_off: false,
            restored: None,
            kept_as: None,
            said: Vec::new(),
        };
        if !self.code_layers_on().is_empty() {
            let recovered = self.library_off_code(Some("recovered by the doctor"), origin, now)?;
            if !recovered.turned_off.is_empty() {
                out.said.push(format!("turned off {}", recovered.turned_off.join(", ")));
            }
            out.said.extend(recovered.notes);
            out.turned_off = recovered.turned_off;
        }
        if self.overlay(expiry.app_abi).is_some_and(|o| !o.library && o.enabled) {
            let off = WebBase {
                overlay: self.overlay_value(),
                enabled: Some(Value::Bool(false)),
                no_file: false,
                text: None,
            };
            self.write_web_dev(&WebTarget::Base, &off)?;
            out.overlay_off = true;
            out.said.push("turned the web-dev overlay off".to_owned());
        }
        if self.live_files_fail()
            && let Some(target) = self.good_generation()
        {
            let restored = self.rollback(Some(target.n), origin, now)?;
            out.restored = Some(restored.generation.n);
            out.kept_as = restored.kept_as;
            out.said.push(match restored.kept_as {
                Some(kept) => format!(
                    "put back generation {} ({}); what was live is generation {kept}: cmux customize rollback {kept}",
                    target.n, target.label
                ),
                None => format!("put back generation {} ({})", target.n, target.label),
            });
        }
        if out.said.is_empty() {
            out.said.push("nothing to recover: your setup loads and no layer is on".to_owned());
        }
        Ok(out)
    }

    /// The newest version of `path` a generation holds that loads and is
    /// not what is live now: `(generation, bytes)`.
    pub(super) fn last_good_version(&self, path: &str) -> Option<(u32, Vec<u8>)> {
        self.last_good_version_where(path, |_| true)
    }

    /// [`Self::last_good_version`], also held to `also` (the settings file's menus all load).
    pub(super) fn last_good_version_where(
        &self,
        path: &str,
        also: impl Fn(&[u8]) -> bool,
    ) -> Option<(u32, Vec<u8>)> {
        let live = tree::read(self.roots(), path).ok().flatten();
        // A file is checked with the live files beside it: a views manifest names its
        // `runtime.main`, which is in the folder, not in the manifest.
        let folder = path.rsplit_once('/').map(|(dir, _)| format!("{dir}/"));
        let beside: BTreeMap<String, Vec<u8>> = match &folder {
            Some(folder) => tree::scan(self.roots())
                .map(|scan| {
                    scan.tree
                        .keys()
                        .filter(|other| other.starts_with(folder.as_str()) && *other != path)
                        .filter_map(|other| {
                            Some((other.clone(), tree::read(self.roots(), other).ok()??))
                        })
                        .collect()
                })
                .unwrap_or_default(),
            None => BTreeMap::new(),
        };
        let index = self.store().index().ok()?;
        for generation in index.generations.iter().rev().take(GENERATIONS_LOOKED_AT) {
            let Ok(tree) = self.store().tree(generation.n) else { continue };
            let Some(entry) = tree.get(path) else { continue };
            let Ok(bytes) = self.store().object(&entry.sha) else { continue };
            if live.as_ref() == Some(&bytes) {
                continue;
            }
            let mut one = beside.clone();
            one.insert(path.to_owned(), bytes.clone());
            let loads = validate::problems(&one).iter().all(|problem| problem.path != path);
            if loads && also(&bytes) {
                return Some((generation.n, bytes));
            }
        }
        None
    }

    /// Writes `path`'s last good version back; the broken text is copied aside first. The file
    /// is written in place (through a link: a file in a dotfiles repo stays linked), so it is
    /// never missing, even if cmux stops between the copy and the write.
    /// The settings file prefers a version whose menus all load, and falls back to any version
    /// that loads, so a readable file is still offered when every saved one skips a menu entry.
    pub(super) fn restore_file(&self, path: &str, now_ms: u64) -> Result<(u32, String), Error> {
        let good = if path == SETTINGS {
            self.last_good_settings().or_else(|| self.last_good_version(path))
        } else {
            self.last_good_version(path)
        };
        self.write_back(path, good, now_ms)
    }

    /// Puts back the newest settings file whose menus all load (a menu finding's Restore: the
    /// same rule that offered it).
    pub(super) fn restore_settings_menus(&self, now_ms: u64) -> Result<(u32, String), Error> {
        self.write_back(SETTINGS, self.last_good_settings(), now_ms)
    }

    fn write_back(
        &self,
        path: &str,
        good: Option<(u32, Vec<u8>)>,
        now_ms: u64,
    ) -> Result<(u32, String), Error> {
        let (n, bytes) = good.ok_or_else(|| {
            Error::Library(format!("no generation holds a version of {path} that loads"))
        })?;
        let file = tree::locate(self.roots(), path)
            .ok_or_else(|| Error::Library(format!("{path} is not a customization file")))?;
        let kept = match std::fs::read(&file) {
            Ok(broken) => Some(self.keep_copy(&file, &broken, now_ms)?),
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => None,
            Err(error) => return Err(error.into()),
        };
        tree::write(self.roots(), path, &bytes, false)?;
        Ok((
            n,
            match kept {
                Some(kept) => format!(
                    "put back {path} from generation {n}; the broken one is at {}",
                    kept.display()
                ),
                None => format!("put back {path} from generation {n}"),
            },
        ))
    }

    fn code_layers_on(&self) -> Vec<String> {
        self.read_library()
            .map(|library| {
                library
                    .entries
                    .iter()
                    .filter(|entry| entry.on && entry.code.is_some())
                    .map(|entry| entry.name().to_owned())
                    .collect()
            })
            .unwrap_or_default()
    }

    /// Some live file does not load.
    fn live_files_fail(&self) -> bool {
        let Ok(scan) = tree::scan(self.roots()) else { return false };
        let mut bytes = BTreeMap::new();
        for path in scan.tree.keys() {
            if let Ok(Some(content)) = tree::read(self.roots(), path) {
                bytes.insert(path.clone(), content);
            }
        }
        !validate::problems(&bytes).is_empty()
    }

    /// The newest generation whose files all load.
    fn good_generation(&self) -> Option<Generation> {
        let index = self.store().index().ok()?;
        index.generations.iter().rev().take(GENERATIONS_LOOKED_AT).find_map(|generation| {
            let tree = self.store().tree(generation.n).ok()?;
            let mut bytes = BTreeMap::new();
            for (path, entry) in &tree {
                bytes.insert(path.clone(), self.store().object(&entry.sha).ok()?);
            }
            validate::problems(&bytes).is_empty().then(|| generation.clone())
        })
    }
}
