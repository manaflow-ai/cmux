//! The secret store item a harness secret lives in (`cli::harness_secret`, which stores it, and
//! `byo_endpoint`, which reads it back): service `cmux-harness`, account `<id>/<KEY>`.

/// The secret store service every harness secret uses.
pub const SERVICE: &str = "cmux-harness";

/// The reference a profile writes for the secret of `id`/`key`.
pub fn reference(id: &str, key: &str) -> String {
    format!("{SERVICE}/{id}/{key}")
}
