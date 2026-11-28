//! Replays three placements over a fleet registry's lane host classes, ranked today's way
//! (`lane_place.placement_preference`, then the cheaper machine type only on a load tie) and by
//! the cost: `cargo run -p cmux-place-cost --example replay -- REGISTRY.json`. One host per
//! class, so names stay out of the output.

use cmux_place_cost::{Node, Prices, Work, rank};
use serde_json::Value;
use std::collections::BTreeMap;

/// The fleet's measured cold start for an acpmux lane: a fleet Linux job restored its source in
/// 8 s and built `cargo test -p acpmux` in 389 s on a shared target cache (2026-11-27).
const COLD_S: f64 = 397.0;

fn main() {
    let path = std::env::args().nth(1).expect("REGISTRY.json");
    let reg: Value = serde_json::from_str(&std::fs::read_to_string(path).unwrap()).unwrap();
    let prices = &reg["lane_place"]["hourly_usd"];
    let mut classes: BTreeMap<String, (usize, Option<f64>)> = BTreeMap::new();
    for m in reg["machines"].as_object().unwrap().values() {
        if m.get("retired").is_some() || !m.get("lanes").is_some_and(Value::is_object) {
            continue;
        }
        let kind = m.pointer("/gcp/machine_type").or_else(|| m.pointer("/lanes/machine_type"));
        let (class, rent) =
            match (kind.and_then(Value::as_str), m.get("provider").and_then(Value::as_str)) {
                (Some(k), _) => (format!("gcp {k}"), prices.get(k).and_then(Value::as_f64)),
                (None, Some(p)) => (p.to_owned(), None),
                (None, None) if m.get("cloud").is_some() => ("freestyle".into(), None),
                (None, None) => ("owned".into(), Some(0.0)),
            };
        classes.entry(class).or_insert((0, rent)).0 += 1;
    }
    let nodes = |warm: &str| -> Vec<Node> {
        classes
            .iter()
            .map(|(c, (_, rent))| Node {
                name: c.clone(),
                rent_usd_per_hour: *rent,
                warm: c == warm,
                cold_start_s: Some(COLD_S),
                rtt_ms: Some(if c == "owned" { 2.0 } else { 25.0 }),
                account: None,
            })
            .collect()
    };
    for (c, (n, rent)) in &classes {
        println!(
            "{n:3} x {c:22} rent {}",
            rent.map_or("unpriced".into(), |r| format!("${r:.3}/h"))
        );
    }
    let p = Prices::LANE;
    let cases = [
        ("new 2 h lane", Work { expected_run_s: 7200.0, turns: 200, ..Work::default() }, ""),
        (
            "resumed lane, warm on gcp c4d-standard-16",
            Work { expected_run_s: 7200.0, turns: 200, ..Work::default() },
            "gcp c4d-standard-16",
        ),
        (
            "10 min fix, warm on gcp c4d-standard-16",
            Work { expected_run_s: 600.0, turns: 20, ..Work::default() },
            "gcp c4d-standard-16",
        ),
    ];
    for (what, work, warm) in cases {
        println!("\n{what}:");
        for (n, c) in rank(&nodes(warm), &work, &p) {
            println!(
                "  {:22} ${:.3} (rent {:.3}, cold {:.0} s, rtt {:.1} s){}",
                n.name,
                c.total_usd(&p),
                c.rent_usd,
                c.cold_start_s,
                c.rtt_s,
                if c.unknown.is_empty() {
                    String::new()
                } else {
                    format!(" unknown {:?}", c.unknown)
                }
            );
        }
    }
}
