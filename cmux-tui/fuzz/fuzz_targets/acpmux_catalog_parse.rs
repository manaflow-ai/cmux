//! The model catalog body (`catalog::schema::parse`): the document acpmux
//! fetches from `GET /api/models/v1` and keeps as its current copy.
//!
//! Invariant past "no panic": a catalog that parses writes a body that parses
//! again with the same harnesses and models, so a stored copy reads back.
//! Costs are f64: they are not compared, a JSON float may move one ULP.
#![no_main]

use acpmux::catalog::schema::{Catalog, parse};
use libfuzzer_sys::fuzz_target;

fn shape(catalog: &Catalog) -> (Vec<(&str, Vec<&str>)>, Vec<&str>) {
    let harnesses = catalog
        .harnesses
        .iter()
        .map(|h| (h.id.as_str(), h.models.iter().map(|m| m.id.as_str()).collect()))
        .collect();
    (harnesses, catalog.models.keys().map(String::as_str).collect())
}

fuzz_target!(|data: &[u8]| {
    let Ok(catalog) = parse(data) else { return };
    let body = serde_json::to_vec(&catalog).expect("a catalog serializes");
    let again = parse(&body).expect("a catalog acpmux accepted reads back");
    assert_eq!(shape(&catalog), shape(&again), "a catalog changes when read back");
});
