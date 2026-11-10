//! The operations: status, begin, apply, discard, roll back.

use std::collections::BTreeMap;
use std::io;

use crate::store::{Ask, Draft, Generation, Index, Kind, Store};
use crate::tree::{self, Part, Scan, Tree};
use crate::{
    Applied, Begun, Change, ChangeKind, DraftInfo, Error, FileDiff, History, Reader, Restored,
    Roots, Status, diff, redact, validate,
};

/// One customization (one person's cmux on one machine).
#[derive(Debug)]
pub struct Customize {
    roots: Roots,
    store: Store,
}

impl Customize {
    pub fn open(roots: Roots) -> Customize {
        let store = Store::at(&roots.state_dir);
        Customize { roots, store }
    }

    /// The customization this process's environment names.
    pub fn from_env() -> Result<Customize, Error> {
        Roots::from_env().map(Customize::open).ok_or(Error::NoHome)
    }

    pub(crate) fn store(&self) -> &Store {
        &self.store
    }

    pub fn roots(&self) -> &Roots {
        &self.roots
    }

    /// Records generation 1, the setup as it is, the first time anything
    /// looks at a customization. Every surface calls this before it reads or
    /// writes, so there is always something to go back to.
    pub fn ensure_baseline(&self, now_ms: u64) -> Result<Option<u32>, Error> {
        if self.store.index()?.current.is_some() {
            return Ok(None);
        }
        let _lock = self.store.lock()?;
        let mut index = self.store.index()?;
        if index.current.is_some() {
            return Ok(None);
        }
        let tree = self.capture()?;
        let label = "the setup before the first customization";
        Ok(Some(self.record(&mut index, Kind::Baseline, &tree, "cmux", label, now_ms)?.n))
    }

    /// What is live, what would apply, and what stops it. Reads only.
    pub fn status(&self) -> Result<Status, Error> {
        let index = self.store.index()?;
        let draft = self.store.draft()?;
        let scan = tree::scan(&self.roots)?;
        let base = self.current_tree(&index)?;
        let changes = changes(&base, &scan.tree, draft.as_ref());
        let problems = validate::problems(&self.live_bytes(&scan.tree)?);
        let ask_to_first_change_ms = draft
            .as_ref()
            .and_then(|draft| draft.asks.last())
            .and_then(|ask| first_change_after(ask.at_ms, &changes, &scan));
        Ok(Status {
            current: index.current().cloned(),
            draft: draft.as_ref().map(DraftInfo::from),
            changes,
            problems,
            skipped: scan.skipped,
            ask_to_first_change_ms,
        })
    }

    /// The text of what the draft changed, with credentials hidden for
    /// `reader` (`redact`).
    pub fn diff(&self, reader: Reader) -> Result<Vec<FileDiff>, Error> {
        let index = self.store.index()?;
        let base = self.current_tree(&index)?;
        let live = tree::scan(&self.roots)?.tree;
        let mut diffs = Vec::new();
        for change in changes(&base, &live, None) {
            let old = match base.get(&change.path) {
                Some(entry) => self.store.object(&entry.sha)?,
                None => Vec::new(),
            };
            let new = tree::read(&self.roots, &change.path)?.unwrap_or_default();
            diffs.push(file_diff(change.path, change.kind, &old, &new, reader));
        }
        Ok(diffs)
    }

    /// What generation `n` changed from the one before it, with credentials
    /// hidden for `reader`: generation 1 is the whole settings file.
    pub fn generation_diff(&self, n: u32, reader: Reader) -> Result<Vec<FileDiff>, Error> {
        let index = self.store.index()?;
        let generation = index.get(n).ok_or(Error::NoSuchGeneration(n))?;
        let new_tree = self.store.tree(n)?;
        let old_tree = match generation.parent {
            Some(parent) if index.get(parent).is_some() => self.store.tree(parent)?,
            _ => Tree::new(),
        };
        let mut diffs = Vec::new();
        for change in changes(&old_tree, &new_tree, None) {
            let read = |tree: &Tree| match tree.get(&change.path) {
                Some(entry) => self.store.object(&entry.sha),
                None => Ok(Vec::new()),
            };
            diffs.push(file_diff(
                change.path.clone(),
                change.kind,
                &read(&old_tree)?,
                &read(&new_tree)?,
                reader,
            ));
        }
        Ok(diffs)
    }

    /// Opens a draft for `ask`, or adds the ask to the open one. Hand edits
    /// made outside a draft are recorded first, as their own generation.
    pub fn begin(&self, ask: &str, origin: &str, now_ms: u64) -> Result<Begun, Error> {
        let _lock = self.store.lock()?;
        self.begin_locked(ask, origin, now_ms)
    }

    /// [`Customize::begin`] for a caller that holds the store's lock and
    /// goes on to write under it (a profile import).
    pub(crate) fn begin_locked(
        &self,
        ask: &str,
        origin: &str,
        now_ms: u64,
    ) -> Result<Begun, Error> {
        let mut index = self.store.index()?;
        let existing = self.store.draft()?;
        let (mut baseline, mut by_hand) = (None, None);
        if index.current.is_none() {
            let tree = self.capture()?;
            let label = "the setup before the first customization";
            baseline =
                Some(self.record(&mut index, Kind::Baseline, &tree, "cmux", label, now_ms)?.n);
        } else if existing.is_none() {
            let live = tree::scan(&self.roots)?.tree;
            if live != self.current_tree(&index)? {
                let tree = self.capture()?;
                let label = "changes made by hand";
                by_hand =
                    Some(self.record(&mut index, Kind::ByHand, &tree, "user", label, now_ms)?.n);
            }
        }
        let refined = existing.is_some();
        let mut draft = existing.unwrap_or(Draft {
            base: index.current,
            started_ms: now_ms,
            ..Draft::default()
        });
        draft.asks.push(Ask {
            text: ask.trim().to_owned(),
            at_ms: now_ms,
            origin: origin.to_owned(),
        });
        self.store.put_draft(Some(&draft))?;
        Ok(Begun { draft: DraftInfo::from(&draft), baseline, by_hand, refined })
    }

    /// Names the agent chat doing the draft's work.
    pub fn set_session(&self, session: &str) -> Result<(), Error> {
        let _lock = self.store.lock()?;
        if let Some(mut draft) = self.store.draft()? {
            draft.session = Some(session.to_owned());
            self.store.put_draft(Some(&draft))?;
        }
        Ok(())
    }

    /// Marks the end of an agent's turn: a file that changes after this was
    /// edited by hand, and the next turn's brief says so.
    pub fn end_turn(&self) -> Result<(), Error> {
        let _lock = self.store.lock()?;
        if let Some(mut draft) = self.store.draft()? {
            draft.turn_tree = Some(tree::scan(&self.roots)?.tree);
            self.store.put_draft(Some(&draft))?;
        }
        Ok(())
    }

    /// Validates the live tree and records it as the next generation.
    /// [`Error::Invalid`] records nothing and leaves the preview live.
    pub fn apply(&self, label: Option<&str>, origin: &str, now_ms: u64) -> Result<Applied, Error> {
        let _lock = self.store.lock()?;
        let mut index = self.store.index()?;
        let draft = self.store.draft()?;
        let scan = tree::scan(&self.roots)?;
        let problems = validate::problems(&self.live_bytes(&scan.tree)?);
        if !problems.is_empty() {
            return Err(Error::Invalid(problems));
        }
        let base = self.current_tree(&index)?;
        let changed = changes(&base, &scan.tree, draft.as_ref());
        if let Some(current) = index.current().filter(|_| changed.is_empty()).cloned() {
            self.store.put_draft(None)?;
            return Ok(Applied { generation: current, recorded: false, changes: changed });
        }
        let label = label
            .map(str::trim)
            .filter(|label| !label.is_empty())
            .map(str::to_owned)
            .or_else(|| draft.as_ref().map(asked).filter(|asked| !asked.is_empty()))
            .unwrap_or_else(|| "changes made by hand".to_owned());
        let tree = self.capture()?;
        let kind = if index.current.is_none() { Kind::Baseline } else { Kind::Applied };
        let generation = self.record(&mut index, kind, &tree, origin, &label, now_ms)?;
        self.store.put_draft(None)?;
        self.store.prune(&mut index)?;
        Ok(Applied { generation, recorded: true, changes: changed })
    }

    /// Puts the current generation back. What was live is kept as a
    /// numbered generation, so a discard can be undone with a roll back.
    pub fn discard(&self, origin: &str, now_ms: u64) -> Result<Restored, Error> {
        let _lock = self.store.lock()?;
        let mut index = self.store.index()?;
        let current = index.current().cloned().ok_or(Error::NothingEarlier)?;
        let draft = self.store.draft()?;
        let label = draft.as_ref().map(asked).filter(|asked| !asked.is_empty());
        let label = label.unwrap_or_else(|| "changes made by hand".to_owned());
        self.restore_to(&mut index, current, Kind::Discarded, origin, &label, now_ms)
    }

    /// Makes generation `to` current and live; with `None`, the one before
    /// the current one. Unapplied changes are kept as their own generation.
    pub fn rollback(&self, to: Option<u32>, origin: &str, now_ms: u64) -> Result<Restored, Error> {
        let _lock = self.store.lock()?;
        let mut index = self.store.index()?;
        let target = match to {
            Some(n) => index.get(n).cloned().ok_or(Error::NoSuchGeneration(n))?,
            None => index
                .current()
                .and_then(|current| current.parent)
                .and_then(|parent| index.get(parent).cloned())
                .ok_or(Error::NothingEarlier)?,
        };
        let label = format!("unapplied changes when rolling back to {}", target.n);
        self.restore_to(&mut index, target, Kind::Autosaved, origin, &label, now_ms)
    }

    pub fn generations(&self) -> Result<History, Error> {
        let index = self.store.index()?;
        let mut generations = index.generations;
        generations.reverse();
        Ok(History { current: index.current, generations })
    }

    // ---- inside ----

    fn current_tree(&self, index: &Index) -> io::Result<Tree> {
        match index.current {
            Some(n) => self.store.tree(n),
            None => Ok(Tree::new()),
        }
    }

    fn live_bytes(&self, tree: &Tree) -> io::Result<BTreeMap<String, Vec<u8>>> {
        let mut files = BTreeMap::new();
        for path in tree.keys() {
            if let Some(bytes) = tree::read(&self.roots, path)? {
                files.insert(path.clone(), bytes);
            }
        }
        Ok(files)
    }

    /// The live tree with every file's content in the store. Each file is
    /// stored from one read, so the tree names exactly what was stored even
    /// while someone is saving.
    fn capture(&self) -> io::Result<Tree> {
        let Scan { mut tree, .. } = tree::scan(&self.roots)?;
        let paths: Vec<String> = tree.keys().cloned().collect();
        for path in paths {
            if tree.get(&path).is_some_and(|entry| self.store.has_object(&entry.sha)) {
                continue;
            }
            match tree::read(&self.roots, &path)? {
                Some(bytes) => {
                    let sha = self.store.put_object(&bytes)?;
                    if let Some(entry) = tree.get_mut(&path) {
                        entry.sha = sha;
                        entry.size = bytes.len() as u64;
                    }
                }
                None => {
                    tree.remove(&path);
                }
            }
        }
        Ok(tree)
    }

    /// Writes generation `next` and its index row. Baseline, applied and
    /// by-hand generations become current; a discarded or autosaved one is
    /// only kept.
    fn record(
        &self,
        index: &mut Index,
        kind: Kind,
        tree: &Tree,
        origin: &str,
        label: &str,
        now_ms: u64,
    ) -> io::Result<Generation> {
        let parent_tree = self.current_tree(index)?;
        let changed = changes(&parent_tree, tree, None);
        let mut parts: Vec<Part> = changed.iter().map(|change| change.part).collect();
        parts.sort();
        parts.dedup();
        let n = index.next.max(1);
        let generation = Generation {
            n,
            kind,
            at_ms: now_ms,
            origin: origin.to_owned(),
            label: one_line(label),
            parent: index.current,
            changed: changed.len() as u32,
            parts,
        };
        self.store.put_tree(n, tree)?;
        index.version = 1;
        index.next = n + 1;
        index.generations.push(generation.clone());
        if matches!(kind, Kind::Baseline | Kind::Applied | Kind::ByHand) {
            index.current = Some(n);
        }
        self.store.put_index(index)?;
        Ok(generation)
    }

    /// Keeps what is live (as `keep`, when it differs from the current
    /// generation), then makes `target` live and current.
    fn restore_to(
        &self,
        index: &mut Index,
        target: Generation,
        keep: Kind,
        origin: &str,
        label: &str,
        now_ms: u64,
    ) -> Result<Restored, Error> {
        let target_tree = self.store.tree(target.n)?;
        // Every object the restore needs is read and checked before one live
        // file changes: a damaged store refuses whole.
        let mut wanted = BTreeMap::new();
        let Scan { tree: live, .. } = tree::scan(&self.roots)?;
        // The executable bit counts: a script whose only change is its mode
        // is written again, so the restore leaves nothing dirty.
        let differs = |path: &String, entry: &tree::Entry| {
            live.get(path).is_none_or(|now| now.sha != entry.sha || now.exec != entry.exec)
        };
        // Something on disk that no generation holds (a file grown past the
        // size limit, a folder swapped for a link into a dotfiles repo) has
        // no copy anywhere: writing over it would lose it for good.
        let in_the_way: Vec<_> = target_tree
            .iter()
            .filter(|(path, entry)| differs(path, entry))
            .filter_map(|(path, _)| tree::in_the_way(&self.roots, path, &live))
            .collect();
        if !in_the_way.is_empty() {
            return Err(Error::Untracked(in_the_way));
        }
        for (path, entry) in &target_tree {
            if differs(path, entry) {
                wanted.insert(path.clone(), (self.store.object(&entry.sha)?, entry.exec));
            }
        }
        let mut kept_as = None;
        if live != self.current_tree(index)? {
            let tree = self.capture()?;
            kept_as = Some(self.record(index, keep, &tree, origin, label, now_ms)?.n);
        }
        // A views app reloads when its manifest lands, so its scripts go
        // first and its manifest last (the order `cmux ext dev` copies in).
        let manifest_last = |path: &String| path.starts_with("customize/cmux-app");
        for (path, (bytes, exec)) in wanted.iter().filter(|(path, _)| !manifest_last(path)) {
            tree::write(&self.roots, path, bytes, *exec)?;
        }
        for path in live.keys().filter(|path| !target_tree.contains_key(*path)) {
            tree::remove(&self.roots, path)?;
        }
        for (path, (bytes, exec)) in wanted.iter().filter(|(path, _)| manifest_last(path)) {
            tree::write(&self.roots, path, bytes, *exec)?;
        }
        index.current = Some(target.n);
        self.store.put_index(index)?;
        self.store.put_draft(None)?;
        self.store.prune(index)?;
        Ok(Restored { generation: target, kept_as, changes: changes(&live, &target_tree, None) })
    }
}

/// What the draft asked for, in one line.
fn asked(draft: &Draft) -> String {
    draft.asks.iter().map(|ask| ask.text.as_str()).collect::<Vec<_>>().join("; ")
}

fn one_line(text: &str) -> String {
    let line = text.split_whitespace().collect::<Vec<_>>().join(" ");
    if line.chars().count() > 200 {
        let mut short: String = line.chars().take(200).collect();
        short.push('…');
        return short;
    }
    line
}

/// How `new` differs from `old`. With a draft that has a turn mark, a change
/// is by hand when the file differs from the mark; with no agent in the
/// picture every change is by hand.
fn changes(old: &Tree, new: &Tree, draft: Option<&Draft>) -> Vec<Change> {
    let mark = draft.and_then(|draft| draft.turn_tree.as_ref());
    let agent = draft.is_some_and(|draft| !draft.asks.is_empty());
    let by_hand = |path: &str| match mark {
        Some(mark) => {
            mark.get(path).map(|entry| &entry.sha) != new.get(path).map(|entry| &entry.sha)
        }
        None => !agent,
    };
    let mut out = Vec::new();
    for (path, entry) in new {
        let kind = match old.get(path) {
            None => ChangeKind::Added,
            Some(before) if before.sha != entry.sha || before.exec != entry.exec => {
                ChangeKind::Modified
            }
            Some(_) => continue,
        };
        out.push(Change { path: path.clone(), part: Part::of(path), kind, by_hand: by_hand(path) });
    }
    for path in old.keys().filter(|path| !new.contains_key(*path)) {
        out.push(Change {
            path: path.clone(),
            part: Part::of(path),
            kind: ChangeKind::Removed,
            by_hand: by_hand(path),
        });
    }
    out.sort_by(|a, b| a.path.cmp(&b.path));
    out
}

fn first_change_after(asked_ms: u64, changes: &[Change], scan: &Scan) -> Option<u64> {
    changes
        .iter()
        .filter_map(|change| scan.mtimes.get(&change.path))
        .filter(|modified| **modified >= asked_ms)
        .min()
        .map(|modified| modified - asked_ms)
}

fn file_diff(path: String, kind: ChangeKind, old: &[u8], new: &[u8], reader: Reader) -> FileDiff {
    // Redacted before the diff, so no line of it can carry a credential.
    let shown = |bytes: &[u8]| {
        std::str::from_utf8(bytes).ok().map(|text| {
            if path == tree::SETTINGS { redact::settings(text, reader) } else { redact::text(text) }
        })
    };
    let diff = match (shown(old), shown(new)) {
        (Some(old), Some(new)) => diff::unified(&old, &new),
        _ => None,
    };
    FileDiff { path, kind, diff }
}
