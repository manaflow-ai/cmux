use super::*;

fn registry() -> Value {
    json!({
        "lane_place": {"hourly_usd": {"about": "x", "c4d-standard-16": 0.756, "e2-standard-8": 0.268}},
        "machines": {
            "gcp-lane-a": {"gcp": {"machine_type": "c4d-standard-16"}},
            "gcp-lane-b": {"aliases": ["b"], "lanes": {"machine_type": "e2-standard-8"}},
            "studio": {"lanes": {}},
            "fs-lane": {"provider": "freestyle"},
        }
    })
}

#[test]
fn rent_reads_the_machine_type_price_and_owned_machines_are_free() {
    let r = registry();
    assert_eq!(rent(Some(&r), "gcp-lane-a"), Some(0.756));
    assert_eq!(rent(Some(&r), "B.local"), Some(0.268), "by alias, canonical");
    assert_eq!(rent(Some(&r), "studio"), Some(0.0));
    assert_eq!(rent(Some(&r), "fs-lane"), None, "a provider host with no price is unknown");
    assert_eq!(rent(Some(&r), "nowhere"), None);
    assert_eq!(rent(None, "studio"), None);
}

#[test]
fn a_host_row_cost_prices_a_lanes_two_hours() {
    let r = registry();
    let c = host_cost(Some(&r), "gcp-lane-a", false, Work::Agent);
    assert!((c["rentUsd"].as_f64().unwrap() - 1.512).abs() < 1e-9, "{c}");
    assert_eq!(c["unknown"], json!(["cold_start", "rtt"]));
    let local = host_cost(Some(&r), "studio", true, Work::Agent);
    assert_eq!(local["totalUsd"], json!(0.0));
    assert_eq!(local["unknown"], json!(["cold_start"]));
}
