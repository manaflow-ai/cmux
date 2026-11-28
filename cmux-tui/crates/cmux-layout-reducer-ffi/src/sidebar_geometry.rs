//! The sidebar drag's drop geometry over the JSON channel (ops `sidebar_geometry_*`,
//! `cmux_layout_reducer::sidebar_drop_geometry`). The app sends the slots it drew and the
//! acceptance table once per drag (`sidebar_geometry_new`, which answers an id), then asks
//! that geometry on every mouse move with only a point (`_hit`, `_beside`, `_edge_y`), so a
//! move costs the same at any number of rows. The few live geometries are kept here, the
//! oldest dropped past [`KEEP`]; a question about one that is gone answers `{"gone": true}`
//! and the app sends its slots again.

use crate::ERR_INVALID;
use cmux_layout_reducer::sidebar_drop_geometry::{
    Acceptance, Edge, Geometry, Outline, Slot, base_y,
};
use serde::Deserialize;
use serde_json::json;
use std::collections::{HashMap, VecDeque};
use std::sync::{Arc, Mutex, PoisonError};

/// How many drag geometries stay live at once (one drag at a time per window).
pub const KEEP: usize = 8;

struct Store {
    next: u64,
    live: VecDeque<(u64, Arc<Geometry>)>,
}

static STORE: Mutex<Store> = Mutex::new(Store { next: 1, live: VecDeque::new() });

pub(crate) fn handles(operation: &[u8]) -> bool {
    operation.starts_with(b"sidebar_geometry_")
}

#[derive(Deserialize)]
struct New {
    slots: Vec<Slot>,
    #[serde(default)]
    acceptance: HashMap<String, Acceptance>,
    #[serde(default)]
    outline: Option<Outline>,
}

#[derive(Deserialize)]
struct Point {
    id: u64,
    x: f64,
    y: f64,
}

#[derive(Deserialize)]
struct Beside {
    id: u64,
    key: String,
    after: bool,
}

#[derive(Deserialize)]
struct EdgeRequest {
    id: u64,
    #[serde(flatten)]
    edge: Edge,
}

#[derive(Deserialize)]
struct Id {
    id: u64,
}

#[derive(Deserialize)]
struct BaseY {
    y: f64,
    #[serde(default)]
    gap_y: Option<f64>,
    #[serde(default)]
    gap_height: f64,
}

fn store() -> std::sync::MutexGuard<'static, Store> {
    STORE.lock().unwrap_or_else(PoisonError::into_inner)
}

fn keep(geometry: Geometry) -> u64 {
    let mut store = store();
    let id = store.next;
    store.next = store.next.wrapping_add(1).max(1);
    store.live.push_back((id, Arc::new(geometry)));
    while store.live.len() > KEEP {
        store.live.pop_front();
    }
    id
}

fn geometry(id: u64) -> Option<Arc<Geometry>> {
    store().live.iter().find(|(live, _)| *live == id).map(|(_, geometry)| Arc::clone(geometry))
}

fn parse<'a, T: Deserialize<'a>>(request: &'a [u8]) -> Result<T, i32> {
    serde_json::from_slice(request).map_err(|_| ERR_INVALID)
}

pub(crate) fn respond(operation: &[u8], request: &[u8]) -> Result<Vec<u8>, i32> {
    let gone = || json!({ "gone": true });
    let reply = match operation {
        b"sidebar_geometry_new" => {
            let New { slots, acceptance, outline } = parse(request)?;
            json!({ "id": keep(Geometry::new(slots, acceptance).with_outline(outline)) })
        }
        b"sidebar_geometry_hit" => {
            let Point { id, x, y } = parse(request)?;
            match geometry(id) {
                Some(geometry) => json!({ "hit": geometry.hit(x, y) }),
                None => gone(),
            }
        }
        b"sidebar_geometry_beside" => {
            let Beside { id, key, after } = parse(request)?;
            match geometry(id) {
                Some(geometry) => json!({ "hit": geometry.beside(&key, after) }),
                None => gone(),
            }
        }
        b"sidebar_geometry_edge_y" => {
            let EdgeRequest { id, edge } = parse(request)?;
            match geometry(id) {
                Some(geometry) => json!({ "y": geometry.edge_y(&edge) }),
                None => gone(),
            }
        }
        b"sidebar_geometry_free" => {
            let Id { id } = parse(request)?;
            store().live.retain(|(live, _)| *live != id);
            json!({})
        }
        b"sidebar_geometry_base_y" => {
            let BaseY { y, gap_y, gap_height } = parse(request)?;
            json!({ "y": base_y(y, gap_y, gap_height) })
        }
        _ => return Err(ERR_INVALID),
    };
    serde_json::to_vec(&reply).map_err(|_| ERR_INVALID)
}
