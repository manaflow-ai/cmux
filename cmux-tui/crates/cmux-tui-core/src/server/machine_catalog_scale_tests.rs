//! The remote machine catalog at scale: one machine's change, and one machine's
//! read, cost the same with 10 machines listed as with the full catalog.
//!
//! - a publication where one machine flips status (a flapping link) is admitted
//!   at every size, and its cost is bounded by an absolute budget (the catalog
//!   is a whole-list replacement capped at 256 rows, so it is O(rows) by design;
//!   the budget fails if that turns superlinear);
//! - `machine.get` of one machine stays within 3x of its 10-machine cost: a
//!   read of one row must not re-serialize every row;
//! - `machine.list` is bounded by the same absolute budget;
//! - a catalog over the cap is refused whole and leaves the last good list.
//!
//! Run (from `cmux-tui/`):
//! `cargo test -p cmux-tui-core --lib machine_catalog_scale -- --nocapture`.

use super::{ClientTransport, Publisher, ResourceOperation, dispatch, mux};
use serde_json::{Value, json};
use std::time::{Duration, Instant};

const SIZES: [usize; 3] = [10, 100, 256];
const ROUNDS: usize = 200;
/// Debug-build budget for one whole-catalog step at the 256-row cap.
const WHOLE_CATALOG_BUDGET: Duration = Duration::from_millis(20);

fn machine(index: usize, status: &str) -> Value {
    json!({"id":format!("machine_{index:032x}"),"name":format!("remote {index}"),
           "origin":if index.is_multiple_of(2) { "cloud" } else { "ssh" },"status":status,
           "platform":{"os":"linux","arch":"x86_64"},"capabilities":["terminal"]})
}

fn catalog(size: usize, flapping: usize, round: usize) -> Value {
    let statuses = ["running", "connecting", "unavailable"];
    Value::Array(
        (0..size)
            .map(|index| {
                machine(index, if index == flapping { statuses[round % 3] } else { "running" })
            })
            .collect(),
    )
}

struct Costs {
    p50: Duration,
    p95: Duration,
}

fn costs(mut samples: Vec<Duration>) -> Costs {
    samples.sort();
    Costs { p50: samples[samples.len() / 2], p95: samples[samples.len() * 95 / 100] }
}

fn measure(mut step: impl FnMut(usize)) -> Costs {
    for round in 0..10 {
        step(round);
    }
    costs(
        (0..ROUNDS)
            .map(|round| {
                let start = Instant::now();
                step(round);
                start.elapsed()
            })
            .collect(),
    )
}

#[test]
fn machine_catalog_scale_one_change_and_one_read_stay_bounded() {
    let mut table = Vec::new();
    for size in SIZES {
        let mux = mux();
        let publisher = Publisher::new(&mux, ClientTransport::Unix, true);
        let mut sequence = 0;
        let publish = measure(|round| {
            sequence += 1;
            let reply = publisher.send(&mux, sequence, catalog(size, size / 2, round));
            assert_eq!(reply["ok"], true, "{size} machines: {reply}");
        });
        let last = format!("machine_{:032x}", size - 1);
        let get = measure(|_| {
            let record = dispatch(&mux, ResourceOperation::MachineGet, Some(&last)).unwrap();
            assert_eq!(record["id"], json!(last));
        });
        let list = measure(|_| {
            let listed = dispatch(&mux, ResourceOperation::MachineList, None).unwrap();
            assert_eq!(listed.as_array().unwrap().len(), size + 1);
        });
        table.push((size, publish, get, list));
    }
    eprintln!("machine catalog | N | publish one change p50/p95 | get p50/p95 | list p50/p95");
    for (size, publish, get, list) in &table {
        eprintln!(
            "machine catalog | {size} | {:?}/{:?} | {:?}/{:?} | {:?}/{:?}",
            publish.p50, publish.p95, get.p50, get.p95, list.p50, list.p95
        );
    }
    let (_, _, small_get, _) = &table[0];
    for (size, publish, get, list) in &table {
        assert!(
            publish.p95 <= WHOLE_CATALOG_BUDGET && list.p95 <= WHOLE_CATALOG_BUDGET,
            "{size} machines: one change costs {:?}, a list {:?}, over {WHOLE_CATALOG_BUDGET:?}",
            publish.p95,
            list.p95
        );
        let bound = (small_get.p95 * 3).max(small_get.p95 + Duration::from_micros(200));
        assert!(
            get.p95 <= bound,
            "{size} machines: reading one machine costs {:?} at p95, over {bound:?} \
             (3x its {:?} with {} machines): a read of one row grows with the catalog",
            get.p95,
            small_get.p95,
            SIZES[0]
        );
    }
}

#[test]
fn machine_catalog_scale_over_the_cap_keeps_the_last_good_list() {
    let mux = mux();
    let publisher = Publisher::new(&mux, ClientTransport::Unix, true);
    assert_eq!(publisher.send(&mux, 1, catalog(256, 0, 0))["ok"], true);
    for size in [257, 1000] {
        let reply = publisher.send(&mux, 2, catalog(size, 0, 1));
        assert_eq!(reply["error_code"], "machine_catalog.bad_request", "{size}: {reply}");
    }
    let listed = dispatch(&mux, ResourceOperation::MachineList, None).unwrap();
    assert_eq!(listed.as_array().unwrap().len(), 257);
}
