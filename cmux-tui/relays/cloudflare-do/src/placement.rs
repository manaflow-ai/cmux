//! Durable Object placement near the registered side (RFD 0127 cut 5).
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

/// The internal path the slot sends a new circuit to create it. The Worker never routes it (it
/// routes only `/v1/circuits/{id}` WebSocket upgrades), so only the slot can send it.
pub(crate) const PLACE_PATH: &str = "/internal/v1/place";

/// Middle East countries, which Cloudflare places under `me` rather than Asia or Africa.
const MIDDLE_EAST: &[&str] = &[
    "AE", "BH", "EG", "IL", "IQ", "IR", "JO", "KW", "LB", "OM", "PS", "QA", "SA", "SY", "TR", "YE",
];

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
