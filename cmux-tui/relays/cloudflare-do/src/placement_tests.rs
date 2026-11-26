use super::{hint, is_region};

#[test]
fn each_continent_gets_its_region() {
    assert_eq!(hint(Some("NA"), Some("US"), Some(-122.4)), Some("wnam"));
    assert_eq!(hint(Some("NA"), Some("US"), Some(-74.0)), Some("enam"));
    assert_eq!(hint(Some("NA"), Some("US"), None), Some("enam"));
    assert_eq!(hint(Some("SA"), Some("BR"), Some(-46.6)), Some("sam"));
    assert_eq!(hint(Some("EU"), Some("DE"), Some(8.7)), Some("weur"));
    assert_eq!(hint(Some("EU"), Some("PL"), Some(21.0)), Some("eeur"));
    assert_eq!(hint(Some("AS"), Some("JP"), Some(139.7)), Some("apac"));
    assert_eq!(hint(Some("OC"), Some("AU"), Some(151.2)), Some("oc"));
    assert_eq!(hint(Some("AF"), Some("ZA"), Some(28.0)), Some("afr"));
}

#[test]
fn the_middle_east_wins_over_its_continent() {
    assert_eq!(hint(Some("AS"), Some("AE"), Some(55.3)), Some("me"));
    assert_eq!(hint(Some("AF"), Some("EG"), Some(31.2)), Some("me"));
    assert_eq!(hint(None, Some("IL"), None), Some("me"));
}

#[test]
fn no_continent_leaves_placement_to_cloudflare() {
    assert_eq!(hint(None, None, None), None);
    assert_eq!(hint(Some("AN"), None, Some(0.0)), None);
}

#[test]
fn every_hint_this_maps_to_is_one_the_relay_accepts() {
    for continent in ["NA", "SA", "EU", "AF", "OC", "AS"] {
        for lon in [-150.0, -50.0, 5.0, 40.0, 120.0] {
            for country in ["US", "AE", "JP"] {
                let region = hint(Some(continent), Some(country), Some(lon)).unwrap();
                assert!(is_region(region));
            }
        }
    }
    assert_eq!(hint(Some("NA"), Some("US"), Some(f32::NAN)), Some("enam"));
    assert!(!is_region("weur\nextra"));
    assert!(!is_region(""));
}
