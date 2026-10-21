//! Running-binary release facts, independent of any installed server state.

use serde::Serialize;
use serde_json::json;
use sha2::{Digest, Sha256};

use super::{Context, Output};

#[derive(Serialize)]
struct ReleaseKey<'a> {
    id: &'a str,
    sha256: String,
}

pub(super) fn status(ctx: &Context<'_>) -> Output {
    let mut keys: Vec<_> = ctx
        .keys
        .iter()
        .map(|key| ReleaseKey {
            id: &key.id,
            sha256: crate::host::hex(&Sha256::digest(key.public_key)),
        })
        .collect();
    keys.sort_by(|left, right| left.id.cmp(right.id));
    let value = json!({
        "schema": 1,
        "kind": "cmux.server.binary",
        "version": ctx.running_cmux,
        "target": crate::host::TARGET,
        "release_keys": keys,
    });
    let human = format!("{value}\n");
    Output::new(value, human)
}
