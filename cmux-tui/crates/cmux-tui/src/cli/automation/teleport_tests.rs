use super::*;

#[test]
fn teleport_every_maps_to_cron_only_on_whole_steps() {
    // 2026-10-30 09:07 UTC.
    let anchor = 1_793_350_800 - 3_600 + 7 * 60 + 3_600;
    assert_eq!(every_as_cron(1_800, anchor).as_deref(), Some("7,37 * * * *"));
    assert_eq!(every_as_cron(3_600, anchor).as_deref(), Some("7 * * * *"));
    assert_eq!(every_as_cron(6 * 3_600, anchor).as_deref(), Some("7 3,9,15,21 * * *"));
    assert_eq!(every_as_cron(86_400, anchor).as_deref(), Some("7 9 * * *"));
    assert_eq!(every_as_cron(7 * 60, anchor), None);
    assert_eq!(every_as_cron(5 * 3_600, anchor), None);
    assert_eq!(every_as_cron(1_800, anchor + 30), None);
}

#[test]
fn teleport_cron_keeps_its_zone_and_never_turns_a_named_one_into_utc() {
    let tz = |zone: &str| {
        let t = Trigger::Cron { expr: "0 9 * * 1-5".into(), tz: zone.into() };
        let Ok(triggers) = cloud_triggers(&t) else { panic!("{zone}: no Cloud trigger") };
        triggers[0]["tz"].as_str().unwrap_or_default().to_string()
    };
    assert_eq!(tz("Europe/Berlin"), "Europe/Berlin", "a named zone goes as it is");
    assert_eq!(tz("utc"), "UTC");
    assert_eq!(tz("local"), cloud::local_zone_name());
}
