//! One item of the way back's work list, by the rules of [`super`]: what this Mac has at the
//! path now, against its base, decides a create, a replace, a delete or a conflict.

use std::collections::BTreeSet;
use std::fs::Permissions;
use std::os::unix::fs::PermissionsExt as _;

use serde_json::Value;

use crate::link::sync_cli::local::permissions_of;
use crate::link::sync_cli::place::Dir;
use crate::link::sync_cli::pull::mode_bits;
use crate::link::sync_cli::remote::refusal_code;
use crate::link::sync_cli::stat_walk::times_of;

use super::disk::{self, Fold, Mac, Swap, With, same};
use super::rules::{self, Shape, join, parent};
use super::{Base, Change, Failure, Item, Left, Run, Work, below, fatal, find, io_failure};

/// What this Mac does with the machine's version of a path.
enum Plan {
    Create,
    Replace,
    /// A folder here the machine replaced with a file or symlink: emptied of what it was
    /// shown, then the create.
    Clear,
    /// The machine's version goes beside `next_to` (this Mac's own name for the path).
    Beside {
        kept: Option<String>,
        next_to: String,
    },
    Refuse(&'static str),
}

/// The machine's version of a file or symlink, staged or not.
enum Bring<'a> {
    File,
    Link(&'a str),
}

/// A machine file looked at: its revision and synced permissions.
struct Seen {
    revision: String,
    perm: u32,
}

impl Run<'_, '_> {
    /// Applies one item.
    pub(super) fn item(&mut self, item: &Item) -> Result<(), Failure> {
        let path = item.path.as_str();
        if rules::in_dotgit(path) {
            self.out.skipped_git = self.out.skipped_git.saturating_add(1);
            return Ok(());
        }
        if let Work::Refused(why) = &item.work {
            self.refuse(path, why);
            return Ok(());
        }
        let mac = self.disk.look(path).map_err(|error| io_failure(&error))?;
        if mac == Mac::Blocked {
            self.refuse(path, "symlink_on_the_way");
            return Ok(());
        }
        let shape = match (&item.work, &mac) {
            (Work::Link(_), _) | (Work::Delete | Work::Vanished, Mac::Link(_)) => Shape::Link,
            (Work::Dir, _) | (Work::Delete | Work::Vanished, Mac::Dir) => Shape::Dir,
            _ => Shape::File,
        };
        if let Some(why) = self.kept(path, shape) {
            self.refuse(path, why);
            return Ok(());
        }
        let base = self.base(path);
        match &item.work {
            Work::File => self.file(path, &mac, &base),
            Work::Metadata => self.metadata(path, &mac, &base),
            Work::Link(text) => self.link(path, text, &mac, &base),
            Work::Dir => self.dir(path, &mac, &base),
            Work::Delete => self.delete(path, "delete", &mac, &base),
            Work::Vanished => {
                let listed = find(self.back.manifest, path).is_some_and(|(_, entry)| !entry.gone);
                if listed {
                    // The machine shows this Mac's file there again: nothing to do.
                    self.mark(path, "gone");
                    return Ok(());
                }
                self.delete(path, "delete", &mac, &base)
            }
            Work::Refused(_) => Ok(()),
        }
    }

    /// Why the Mac walker would not have listed `path`, if it would not.
    fn kept(&self, path: &str, shape: Shape) -> Option<&'static str> {
        let has_file = |at: &str| {
            matches!(self.upper.get(at), Some(Change::File | Change::Metadata))
                || find(self.back.manifest, at)
                    .is_some_and(|(_, entry)| entry.stat.kind == cmux_projfs::Kind::File)
        };
        rules::kept_home(self.back.root, path, shape, &has_file)
    }

    /// Notes the machine version `tag` of `path` without changing what is left here.
    fn mark(&mut self, path: &str, tag: &str) {
        let left = self.ledger.paths.get(path).map_or(Left::Missing, |pulled| pulled.mac.clone());
        self.record(path, tag, left);
    }

    /// What is at `path` now, as the ledger keeps it.
    fn left(&self, path: &str) -> Left {
        self.disk.look(path).map_or(Left::Missing, |mac| Left::of(&mac))
    }

    fn count(&mut self, created: bool) {
        self.out.applied = self.out.applied.saturating_add(1);
        if created {
            self.out.created = self.out.created.saturating_add(1);
        }
    }

    fn counted_delete(&mut self) {
        self.out.applied = self.out.applied.saturating_add(1);
        self.out.deleted = self.out.deleted.saturating_add(1);
    }

    /// The machine's path of `path`.
    fn there(&self, path: &str) -> String {
        format!("{}/{path}", self.back.machine_folder.trim_end_matches('/'))
    }

    /// The machine's file at `path` looked at; why not, as a refusal reason.
    fn seen(&mut self, path: &str) -> Result<Result<Seen, &'static str>, Failure> {
        let at = self.there(path);
        let stat = match self.remote.stat(&at) {
            Ok(Some(stat)) => stat,
            Ok(None) => return Ok(Err("gone_on_machine")),
            Err(error) if refusal_code(&error).is_some() => return Ok(Err("machine_refused")),
            Err(error) => return Err(fatal(&error)),
        };
        if stat.get("kind").and_then(Value::as_str) != Some("file") {
            return Ok(Err("not_a_file_on_machine"));
        }
        let revision = stat.get("revision").and_then(Value::as_str).unwrap_or_default();
        let mode = stat.get("mode_display").and_then(Value::as_str).map_or(0o644, mode_bits);
        Ok(Ok(Seen { revision: revision.to_owned(), perm: permissions_of(mode) }))
    }

    fn file(&mut self, path: &str, mac: &Mac, base: &Base) -> Result<(), Failure> {
        let seen = match self.seen(path)? {
            Ok(seen) => seen,
            Err(why) => {
                self.refuse(path, why);
                return Ok(());
            }
        };
        let tag = format!("file:{}:{:o}", seen.revision, seen.perm);
        if self.settled(path, &tag) {
            return Ok(());
        }
        let plan = self.plan(path, mac, base)?;
        self.land(path, &tag, mac, plan, &Bring::File, seen)
    }

    fn link(&mut self, path: &str, text: &str, mac: &Mac, base: &Base) -> Result<(), Failure> {
        if !rules::link_stays_inside(path, text) {
            self.refuse(path, "link_leaves_folder");
            return Ok(());
        }
        let tag = format!("link:{text}");
        if self.settled(path, &tag) {
            return Ok(());
        }
        let plan = self.plan(path, mac, base)?;
        let none = Seen { revision: String::new(), perm: 0 };
        self.land(path, &tag, mac, plan, &Bring::Link(text), none)
    }

    /// A permission change of a file whose bytes the machine did not change: applied to this
    /// Mac's file when it is still the base (never its owner). With no file base, a file.
    fn metadata(&mut self, path: &str, mac: &Mac, base: &Base) -> Result<(), Failure> {
        let Base::Shown(Mac::File(_)) = base else { return self.file(path, mac, base) };
        let seen = match self.seen(path)? {
            Ok(seen) => seen,
            Err(why) => {
                self.refuse(path, why);
                return Ok(());
            }
        };
        let tag = format!("meta:{:o}", seen.perm);
        if self.settled(path, &tag) {
            return Ok(());
        }
        let Base::Shown(expected) = base else { return Ok(()) };
        if !same(mac, expected) {
            self.conflict(path, Some(path), None);
            self.record(path, &tag, Left::Conflict);
            return Ok(());
        }
        if self.back.dry_run {
            self.count(false);
            return Ok(());
        }
        let holder = self.disk.holder(path).map_err(|error| io_failure(&error))?;
        let changed = holder.and_then(|(dir, name)| dir.open_file(&name).ok()).and_then(|file| {
            let now = file.metadata().ok().map(|meta| Mac::File(times_of(&meta)))?;
            same(&now, expected).then(|| file.set_permissions(Permissions::from_mode(seen.perm)))
        });
        match changed {
            Some(Ok(())) => {
                self.count(false);
                let left = self.left(path);
                self.record(path, &tag, left);
            }
            Some(Err(error)) => return Err(io_failure(&error)),
            None => {
                self.conflict(path, Some(path), None);
                self.record(path, &tag, Left::Conflict);
            }
        }
        Ok(())
    }

    fn dir(&mut self, path: &str, mac: &Mac, base: &Base) -> Result<(), Failure> {
        if self.settled(path, "dir") {
            return Ok(());
        }
        if *mac == Mac::Dir {
            self.record(path, "dir", Left::Dir);
            return Ok(());
        }
        let plan = self.plan(path, mac, base)?;
        let made = match plan {
            Plan::Refuse(why) => {
                self.refuse(path, why);
                return Ok(());
            }
            Plan::Beside { kept, .. } => {
                self.conflict(path, kept.as_deref(), None);
                self.record(path, "dir", Left::Conflict);
                return Ok(());
            }
            _ if self.back.dry_run => true,
            Plan::Replace => {
                let holder = self.disk.holder(path).map_err(|error| io_failure(&error))?;
                let gone = match holder {
                    Some((dir, name)) => self.disk.delete(&dir, &name, mac),
                    None => Ok(Swap::Changed),
                };
                matches!(gone.map_err(|error| io_failure(&error))?, Swap::Done | Swap::Gone)
                    && self.mkdir(path)?
            }
            Plan::Create | Plan::Clear => self.mkdir(path)?,
        };
        if made {
            self.count(true);
            self.record(path, "dir", Left::Dir);
        } else {
            self.conflict(path, Some(path), None);
            self.record(path, "dir", Left::Conflict);
        }
        Ok(())
    }

    /// Makes the folder `path`; whether a folder is there now.
    fn mkdir(&mut self, path: &str) -> Result<bool, Failure> {
        let (dir, name) = self.disk.make_parent(path).map_err(|error| io_failure(&error))?;
        match dir.mkdir(&name) {
            Ok(()) => {}
            Err(error) if error.kind() == std::io::ErrorKind::AlreadyExists => {}
            Err(error) => return Err(io_failure(&error)),
        }
        self.disk.noted(parent(path), &name);
        Ok(disk::look_in(&dir, &name).map_err(|error| io_failure(&error))? == Mac::Dir)
    }

    /// What this Mac does with a new version of a file or symlink at `path`.
    fn plan(&mut self, path: &str, mac: &Mac, base: &Base) -> Result<Plan, Failure> {
        let beside = |kept: Option<&str>| Plan::Beside {
            kept: kept.map(str::to_owned),
            next_to: path.to_owned(),
        };
        Ok(match (base, mac) {
            (Base::Withheld, _) => Plan::Refuse("secret"),
            (Base::Conflicted, Mac::Missing) => beside(None),
            (Base::Conflicted, _) => beside(Some(path)),
            (Base::Shown(Mac::Missing), Mac::Missing) => {
                match self.disk.fold(path).map_err(|error| io_failure(&error))? {
                    Fold::Folder => Plan::Refuse("case"),
                    Fold::Name(own) => Plan::Beside { kept: Some(own.clone()), next_to: own },
                    Fold::Clear if self.ignored.contains(path) => Plan::Refuse("ignored"),
                    Fold::Clear => Plan::Create,
                }
            }
            (Base::Shown(Mac::Dir), Mac::Dir) => Plan::Clear,
            (Base::Shown(expected), Mac::File(_) | Mac::Link(_)) if same(mac, expected) => {
                Plan::Replace
            }
            (_, Mac::Missing) => beside(None),
            _ => beside(Some(path)),
        })
    }

    /// Carries out `plan` for the machine's file or symlink at `path`.
    fn land(
        &mut self,
        path: &str,
        tag: &str,
        mac: &Mac,
        plan: Plan,
        bring: &Bring<'_>,
        seen: Seen,
    ) -> Result<(), Failure> {
        if let Plan::Refuse(why) = plan {
            self.refuse(path, why);
            return Ok(());
        }
        if self.back.dry_run {
            match plan {
                Plan::Create | Plan::Clear => self.count(true),
                Plan::Replace => self.count(false),
                Plan::Beside { kept, next_to } => {
                    let side = disk::free_beside(None, disk::name_of(&next_to))
                        .map_err(|error| io_failure(&error))?
                        .map(|side| join(parent(path), &side));
                    self.conflict(path, kept.as_deref(), side.as_deref());
                }
                Plan::Refuse(_) => {}
            }
            return Ok(());
        }
        let (dir, name) = self.disk.make_parent(path).map_err(|error| io_failure(&error))?;
        let (staged, tag) = match bring {
            Bring::Link(_) => (None, tag.to_owned()),
            Bring::File => match self.fetch(path, &dir, seen)? {
                Some((temp, seen)) => {
                    (Some(temp), format!("file:{}:{:o}", seen.revision, seen.perm))
                }
                None => return Ok(()),
            },
        };
        let with = match (&staged, bring) {
            (Some(temp), _) => With::Staged(temp),
            (None, Bring::Link(text)) => With::Link(text),
            (None, Bring::File) => return Ok(()),
        };
        let done = self.put(path, &tag, (&dir, &name), mac, plan, &with);
        if let Some(temp) = &staged {
            let _ = dir.unlink(temp, false);
        }
        done
    }

    /// Puts `with` at `path` (`name` in `dir`) by `plan`.
    fn put(
        &mut self,
        path: &str,
        tag: &str,
        (dir, name): (&Dir, &str),
        mac: &Mac,
        plan: Plan,
        with: &With<'_>,
    ) -> Result<(), Failure> {
        let io = |error: std::io::Error| io_failure(&error);
        let placed = match plan {
            Plan::Create => disk::place_new(dir, with, name).map_err(io)?,
            Plan::Replace => self.disk.replace(dir, name, mac, with).map_err(io)? == Swap::Done,
            Plan::Clear => self.clear(path)? && disk::place_new(dir, with, name).map_err(io)?,
            Plan::Beside { kept, next_to } => {
                return self.beside(path, tag, (dir, &next_to), kept.as_deref(), with);
            }
            Plan::Refuse(_) => return Ok(()),
        };
        if !placed {
            return self.beside(path, tag, (dir, path), Some(path), with);
        }
        // The staged name goes before the stat is kept: unlinking it changes the file's ctime.
        if let With::Staged(temp) = with {
            let _ = dir.unlink(temp, false);
        }
        self.count(matches!(plan, Plan::Create | Plan::Clear));
        self.disk.noted(parent(path), name);
        let left = self.left(path);
        self.record(path, tag, left);
        Ok(())
    }

    /// Puts `with` beside `next_to` under a conflict name; this Mac's entry `kept` stays.
    fn beside(
        &mut self,
        path: &str,
        tag: &str,
        (dir, next_to): (&Dir, &str),
        kept: Option<&str>,
        with: &With<'_>,
    ) -> Result<(), Failure> {
        let name = disk::name_of(next_to);
        match disk::place_beside(dir, with, name).map_err(|error| io_failure(&error))? {
            Some(side) => {
                self.disk.noted(parent(path), &side);
                let side = join(parent(path), &side);
                self.conflict(path, kept, Some(&side));
                self.record(path, tag, Left::Conflict);
            }
            None => self.refuse(path, "no_conflict_name"),
        }
        Ok(())
    }

    /// Reads the machine's file at `path` into a file of this pull in `dir`, read again when it
    /// changed meanwhile; the staged name and what was read, or None (refused) when it cannot be.
    fn fetch(
        &mut self,
        path: &str,
        dir: &Dir,
        mut seen: Seen,
    ) -> Result<Option<(String, Seen)>, Failure> {
        let at = self.there(path);
        for _ in 0..3 {
            let (temp, mut file) = self.disk.temp(dir).map_err(|error| io_failure(&error))?;
            let size = match self.remote.read_into(&at, &mut file) {
                Ok(Some(size)) => size,
                Ok(None) => {
                    let _ = dir.unlink(&temp, false);
                    self.refuse(path, "gone_on_machine");
                    return Ok(None);
                }
                Err(error) => {
                    let _ = dir.unlink(&temp, false);
                    if refusal_code(&error).is_none() {
                        return Err(fatal(&error));
                    }
                    self.refuse(path, "machine_refused");
                    return Ok(None);
                }
            };
            let now = match self.seen(path)? {
                Ok(now) => now,
                Err(why) => {
                    let _ = dir.unlink(&temp, false);
                    self.refuse(path, why);
                    return Ok(None);
                }
            };
            if now.revision != seen.revision {
                let _ = dir.unlink(&temp, false);
                seen = now;
                continue;
            }
            let ready = file
                .set_permissions(Permissions::from_mode(now.perm))
                .and_then(|()| file.sync_all());
            if let Err(error) = ready {
                let _ = dir.unlink(&temp, false);
                return Err(io_failure(&error));
            }
            self.out.bytes = self.out.bytes.saturating_add(size);
            return Ok(Some((temp, now)));
        }
        self.refuse(path, "changing_on_machine");
        Ok(None)
    }

    /// The delete rule at `path`.
    fn delete(&mut self, path: &str, tag: &str, mac: &Mac, base: &Base) -> Result<(), Failure> {
        if self.settled(path, tag) {
            return Ok(());
        }
        match (base, mac) {
            (_, Mac::Missing) => self.record(path, tag, Left::Missing),
            (Base::Withheld, _) => self.refuse(path, "secret"),
            // A folder that stays (something here the machine was not shown) is a conflict below.
            (Base::Shown(Mac::Dir), Mac::Dir) if self.back.dry_run || self.clear(path)? => {
                self.counted_delete();
                self.record(path, tag, Left::Missing);
            }
            (Base::Shown(expected), Mac::File(_) | Mac::Link(_)) if same(mac, expected) => {
                let swap =
                    if self.back.dry_run { Swap::Done } else { self.remove(path, expected)? };
                match swap {
                    Swap::Done => {
                        self.counted_delete();
                        self.record(path, tag, Left::Missing);
                    }
                    Swap::Gone => self.record(path, tag, Left::Missing),
                    Swap::Changed => {
                        self.conflict(path, Some(path), None);
                        self.record(path, tag, Left::Conflict);
                    }
                }
            }
            _ => {
                self.conflict(path, Some(path), None);
                self.record(path, tag, Left::Conflict);
            }
        }
        Ok(())
    }

    /// Deletes the file or symlink at `path` when it is still `expected`.
    fn remove(&mut self, path: &str, expected: &Mac) -> Result<Swap, Failure> {
        let Some((dir, name)) = self.disk.holder(path).map_err(|error| io_failure(&error))? else {
            return Ok(Swap::Changed);
        };
        self.disk.delete(&dir, &name, expected).map_err(|error| io_failure(&error))
    }

    /// Empties the folder `top` of what the machine was shown in it (and earlier pulls brought)
    /// that still equals its base, then removes it when nothing else is left; whether it is gone.
    fn clear(&mut self, top: &str) -> Result<bool, Failure> {
        let prefix = format!("{top}/");
        let mut paths: BTreeSet<String> = self
            .ledger
            .paths
            .range(prefix.clone()..)
            .take_while(|(path, _)| path.starts_with(&prefix))
            .map(|(path, _)| path.clone())
            .collect();
        let manifest = self.back.manifest;
        if let Some((at, _)) = find(manifest, top) {
            paths.extend(below(manifest, at).into_iter().filter_map(|at| manifest.path_of(at)));
        }
        // Children sort after their folder: the reverse order empties a folder before it.
        for path in paths.iter().rev() {
            if rules::in_dotgit(path) {
                continue;
            }
            let mac = self.disk.look(path).map_err(|error| io_failure(&error))?;
            let shape = match mac {
                Mac::Dir => Shape::Dir,
                Mac::Link(_) => Shape::Link,
                _ => Shape::File,
            };
            if self.kept(path, shape).is_some() {
                continue;
            }
            let gone = match (&mac, self.base(path)) {
                (Mac::Dir, _) => self.disk.remove_dir(path).map_err(|error| io_failure(&error))?,
                (Mac::File(_) | Mac::Link(_), Base::Shown(expected)) if same(&mac, &expected) => {
                    self.remove(path, &expected)? == Swap::Done
                }
                _ => false,
            };
            if gone {
                self.out.deleted = self.out.deleted.saturating_add(1);
                self.record(path, "delete", Left::Missing);
            }
        }
        self.disk.remove_dir(top).map_err(|error| io_failure(&error))
    }
}
