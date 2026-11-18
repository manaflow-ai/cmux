//! Who owns each projected folder on this machine (`projfs-v1`): the principal of the link that
//! mounted it. Only that principal may take or answer its batches (`projfs.next`,
//! `projfs.answer`), read its upper layer (`projfs.upper`), unmount it (`projfs.unmount`) or see
//! it in `projfs.status`; any other gets the answer a folder that does not exist gets.
//!
//! `projfs.mount` records its principal for the mount id and for the `state` and `at` folders
//! it was given; another principal's mount of the same id or folders is refused. A successful
//! `projfs.unmount` lets the folders go. The table is in memory and bounded
//! ([`MAX_OWNED`], the oldest record forgotten past it). A mount id or folder with no record
//! (this daemon restarted while the helper kept serving, or its record was forgotten) is the
//! first principal's that uses it: the record is made then.

use std::collections::VecDeque;
use std::sync::{Mutex, MutexGuard, PoisonError};

/// Records one daemon keeps; past it the oldest is forgotten.
pub const MAX_OWNED: usize = 1024;

/// One owned projected folder: its mount id, its folders, or both.
#[derive(Debug)]
struct Owned {
    principal: String,
    mount: Option<String>,
    places: Vec<String>,
}

impl Owned {
    fn has_mount(&self, mount: &str) -> bool {
        self.mount.as_deref() == Some(mount)
    }

    fn has_place(&self, place: &str) -> bool {
        self.places.iter().any(|held| held == place)
    }
}

/// The owners of this machine's projected folders.
#[derive(Debug, Default)]
pub struct Owners {
    table: Mutex<VecDeque<Owned>>,
}

impl Owners {
    #[must_use]
    pub fn new() -> Self {
        Self::default()
    }

    fn table(&self) -> MutexGuard<'_, VecDeque<Owned>> {
        self.table.lock().unwrap_or_else(PoisonError::into_inner)
    }

    /// `projfs.mount` by `principal`: records it as the owner of `mount` and of `places` (its
    /// `state` and `at`), unless another principal owns any of them (then false).
    pub fn claim(&self, principal: &str, mount: &str, places: &[&str]) -> bool {
        let mut table = self.table();
        let taken = |owned: &Owned| {
            owned.has_mount(mount) || places.iter().any(|place| owned.has_place(place))
        };
        if table.iter().any(|owned| taken(owned) && owned.principal != principal) {
            return false;
        }
        table.retain(|owned| !taken(owned));
        let places = places.iter().map(|place| (*place).to_owned()).collect();
        push(
            &mut table,
            Owned { principal: principal.to_owned(), mount: Some(mount.to_owned()), places },
        );
        true
    }

    /// Whether `principal` may use mount `mount`: it owns it, or nobody does (then it does now).
    pub fn may_use_mount(&self, principal: &str, mount: &str) -> bool {
        let mut table = self.table();
        if let Some(owned) = table.iter().find(|owned| owned.has_mount(mount)) {
            return owned.principal == principal;
        }
        let owned = Owned {
            principal: principal.to_owned(),
            mount: Some(mount.to_owned()),
            places: Vec::new(),
        };
        push(&mut table, owned);
        true
    }

    /// Whether `principal` may use the folder `place` (a `state` or `at`): it owns it, or nobody
    /// does (then it does now).
    pub fn may_use_place(&self, principal: &str, place: &str) -> bool {
        let mut table = self.table();
        if let Some(owned) = table.iter().find(|owned| owned.has_place(place)) {
            return owned.principal == principal;
        }
        let owned =
            Owned { principal: principal.to_owned(), mount: None, places: vec![place.to_owned()] };
        push(&mut table, owned);
        true
    }

    /// Whether `principal` owns mount `mount` now (no record is made).
    pub fn owns_mount(&self, principal: &str, mount: &str) -> bool {
        self.table().iter().any(|owned| owned.has_mount(mount) && owned.principal == principal)
    }

    /// `principal`'s folder `place` was unmounted (or its mount failed): its records holding
    /// `place` go.
    pub fn release(&self, principal: &str, place: &str) {
        self.table().retain(|owned| !(owned.principal == principal && owned.has_place(place)));
    }
}

fn push(table: &mut VecDeque<Owned>, owned: Owned) {
    table.push_back(owned);
    while table.len() > MAX_OWNED {
        table.pop_front();
    }
}
