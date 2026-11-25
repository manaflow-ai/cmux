use std::collections::HashSet;
use std::sync::{Arc, Mutex, PoisonError};

use crate::Mux;

#[derive(Clone, Copy, PartialEq, Eq, Hash, Debug)]
pub(in crate::server) enum Site {
    Reader,
    Dispatch,
}

type Key = (usize, u64, Site);

static ARMED: Mutex<Option<HashSet<Key>>> = Mutex::new(None);

fn key(mux: &Arc<Mux>, client: u64, site: Site) -> Key {
    (Arc::as_ptr(mux) as usize, client, site)
}

pub(in crate::server) fn arm(mux: &Arc<Mux>, client: u64, site: Site) {
    ARMED
        .lock()
        .unwrap_or_else(PoisonError::into_inner)
        .get_or_insert_default()
        .insert(key(mux, client, site));
}

pub(in crate::server) fn check(mux: &Arc<Mux>, client: u64, site: Site) {
    let armed = ARMED
        .lock()
        .unwrap_or_else(PoisonError::into_inner)
        .as_mut()
        .is_some_and(|armed| armed.remove(&key(mux, client, site)));
    if armed {
        // crash-allow: a test-only fault injected by the panic seam.
        panic!("injected request handler panic ({site:?}) on connection {client}");
    }
}
