//! Where a circuit's Durable Object is created (RFD 0049, RFD 0163 pick 6).
//!
//! A Durable Object is created near the first caller that reaches it and stays there. A circuit's two ends
//! are the viewer (the client) and the daemon; the slot sits next to the daemon, which always touches it
//! first. The router reads the viewer's `request.cf`, maps it to a Cloudflare location hint, and hands it to
//! the slot in `VIEWER_REGION_HEADER`; the slot signs it into both join tickets as the `region` claim; the
//! router then creates the circuit object with that hint, whichever end joins first.

/// Set by the router on a client's slot request, from `request.cf`; always removed from what the caller sent.
pub(crate) const VIEWER_REGION_HEADER: &str = "x-cmux-viewer-region";

/// Cloudflare's Durable Object location hints.
const REGIONS: [&str; 9] = ["wnam", "enam", "sam", "weur", "eeur", "apac", "oc", "afr", "me"];

/// Countries of Asia that Cloudflare's `me` hint covers.
const MIDDLE_EAST: [&str; 13] =
    ["AE", "BH", "IL", "IQ", "IR", "JO", "KW", "LB", "OM", "QA", "SA", "SY", "YE"];

/// Whether `region` is one of the hints this relay hands out. Anything else in a ticket is ignored.
pub(crate) fn is_region(region: &str) -> bool {
    REGIONS.contains(&region)
}

/// The hint for a viewer from the continent, longitude and country of its request; the same mapping as
/// `locationHintFor` in `cmux-next-ios/backend/src/index.ts`.
pub(crate) fn location_hint_for(
    continent: Option<&str>,
    longitude: Option<f64>,
    country: Option<&str>,
) -> Option<&'static str> {
    let lon = longitude.filter(|value| value.is_finite());
    match continent? {
        "NA" => Some(if lon.is_some_and(|lon| lon < -100.0) { "wnam" } else { "enam" }),
        "SA" => Some("sam"),
        "EU" => Some(if lon.is_some_and(|lon| lon > 20.0) { "eeur" } else { "weur" }),
        "AF" => Some("afr"),
        "OC" => Some("oc"),
        "AS" => Some(if country.is_some_and(|code| MIDDLE_EAST.contains(&code)) { "me" } else { "apac" }),
        _ => None,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn viewers_map_to_the_hint_the_mobile_backend_gives_them() {
        // San Jose, Ashburn, Frankfurt, Warsaw, Sao Paulo, Tokyo, Dubai, Sydney, Johannesburg.
        assert_eq!(location_hint_for(Some("NA"), Some(-121.9), Some("US")), Some("wnam"));
        assert_eq!(location_hint_for(Some("NA"), Some(-77.5), Some("US")), Some("enam"));
        assert_eq!(location_hint_for(Some("EU"), Some(8.7), Some("DE")), Some("weur"));
        assert_eq!(location_hint_for(Some("EU"), Some(21.0), Some("PL")), Some("eeur"));
        assert_eq!(location_hint_for(Some("SA"), Some(-46.6), Some("BR")), Some("sam"));
        assert_eq!(location_hint_for(Some("AS"), Some(139.7), Some("JP")), Some("apac"));
        assert_eq!(location_hint_for(Some("AS"), Some(55.3), Some("AE")), Some("me"));
        assert_eq!(location_hint_for(Some("OC"), Some(151.2), Some("AU")), Some("oc"));
        assert_eq!(location_hint_for(Some("AF"), Some(28.0), Some("ZA")), Some("afr"));
    }

    #[test]
    fn an_unknown_viewer_gets_no_hint_and_a_missing_longitude_falls_to_the_east_or_west_default() {
        assert_eq!(location_hint_for(None, Some(0.0), None), None);
        assert_eq!(location_hint_for(Some("AN"), None, None), None);
        assert_eq!(location_hint_for(Some("T1"), None, None), None);
        assert_eq!(location_hint_for(Some("NA"), None, None), Some("enam"));
        assert_eq!(location_hint_for(Some("NA"), Some(f64::NAN), None), Some("enam"));
        assert_eq!(location_hint_for(Some("EU"), None, None), Some("weur"));
    }

    #[test]
    fn every_hint_this_maps_to_is_one_the_relay_accepts() {
        for continent in ["NA", "SA", "EU", "AF", "OC", "AS"] {
            for lon in [-150.0, -50.0, 5.0, 40.0, 120.0] {
                for country in ["US", "AE", "JP"] {
                    let hint = location_hint_for(Some(continent), Some(lon), Some(country)).unwrap();
                    assert!(is_region(hint));
                }
            }
        }
        assert!(!is_region("weur\nextra"));
        assert!(!is_region(""));
    }
}
