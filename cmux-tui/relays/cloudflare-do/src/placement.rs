//! Durable Object placement (RFD 0127 cut 5, RFD 0049, RFD 0163 pick 6).
//!
//! A Durable Object is created near the first request that reaches it, and stays there. Two
//! objects sit on a dial's path:
//!
//! - The slot. Its first request could be a client's Connect, from wherever the dialer is. The
//!   daemon's control upgrade (`/v1/slots/{slot}/control`) carries a location hint, the region of
//!   the edge the daemon reached ([`hint`]), so a slot the daemon creates is placed near the
//!   daemon. Cloudflare ignores the hint on an object that already exists.
//! - A circuit the slot allocates when no Standby is free (`slot.rs` `allocate`). Its first request
//!   used to be whichever side's Join came first, usually the dialer's, and the object's wake was
//!   paid on that Join. The slot now sends it one internal request ([`PLACE_PATH`]) as soon as both
//!   sides have their tickets, so it is created near the slot (and so near the daemon) and is awake
//!   before either Join arrives. A Join that still comes first places it as before.
//!
//! With `CMUX_RELAY_VIEWER_CIRCUITS` set to "1" (off by default), a far viewer's circuit is placed
//! near the viewer instead: the router hands the slot each caller's region in [`REGION_HEADER`],
//! the slot signs the viewer's into both join tickets as the `region` claim and creates the circuit
//! with that hint, and the router uses the same hint on a Join that comes first.

/// The internal path the slot sends a new circuit to create it. The Worker never routes it (it
/// routes only `/v1/circuits/{id}` WebSocket upgrades), so only the slot can send it.
pub(crate) const PLACE_PATH: &str = "/internal/v1/place";

/// Set by the router on a slot request from the caller's `request.cf`; what the caller sent under
/// it is dropped.
pub(crate) const REGION_HEADER: &str = "x-cmux-region";

/// Cloudflare's Durable Object location hints.
const REGIONS: [&str; 9] = ["wnam", "enam", "sam", "weur", "eeur", "apac", "oc", "afr", "me"];

/// Middle East countries, which Cloudflare places under `me` rather than Asia or Africa.
const MIDDLE_EAST: &[&str] = &[
    "AE", "BH", "EG", "IL", "IQ", "IR", "JO", "KW", "LB", "OM", "PS", "QA", "SA", "SY", "TR", "YE",
];

/// Whether `region` is one of the hints this relay hands out. Anything else in a ticket or a
/// socket tag is ignored.
pub(crate) fn is_region(region: &str) -> bool {
    REGIONS.contains(&region)
}

/// The Durable Object location hint for a request from `continent` (Cloudflare's two-letter
/// code), `country` (ISO 3166-1 alpha-2) and `longitude`; `None` when none fits (Antarctica, a
/// missing continent), which leaves the placement to Cloudflare.
pub(crate) fn hint(
    continent: Option<&str>,
    country: Option<&str>,
    longitude: Option<f32>,
) -> Option<&'static str> {
    if country.is_some_and(|country| MIDDLE_EAST.contains(&country)) {
        return Some("me");
    }
    let longitude = longitude.filter(|lon| lon.is_finite());
    match continent? {
        // West of the Rockies' line is western North America.
        "NA" => Some(if longitude.is_some_and(|lon| lon < -100.0) { "wnam" } else { "enam" }),
        "SA" => Some("sam"),
        // East of Vienna's meridian is eastern Europe.
        "EU" => Some(if longitude.is_some_and(|lon| lon >= 16.0) { "eeur" } else { "weur" }),
        "AS" => Some("apac"),
        "OC" => Some("oc"),
        "AF" => Some("afr"),
        _ => None,
    }
}

/// [`hint`] for the edge `request` reached; `None` off Cloudflare (no `cf`).
pub(crate) fn hint_of(request: &worker::Request) -> Option<&'static str> {
    let cf = request.cf()?;
    let longitude = cf.coordinates().map(|(_, lon)| lon);
    hint(cf.continent().as_deref(), cf.country().as_deref(), longitude)
}

#[cfg(test)]
#[path = "placement_tests.rs"]
mod tests;
