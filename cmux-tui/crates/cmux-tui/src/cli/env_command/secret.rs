//! `cmux env set-secret`: the one place a secret's value exists in `cmux env`.

use serde_json::{Value, json};

use super::daemon::{Daemon, wipe};
use super::ops::{Failure, Local};

/// The platform's limit on a secret's value (cmux-platform `CloudEnvironments.ts` `Value`).
const MAX_VALUE_BYTES: usize = 32 * 1024;

/// Sets secret `key` of environment `id`, sent only to `hosts` (in `header`, else the platform's
/// default), and answers the saved environment as the daemon returned it (without values: its
/// `redact` drops them, and the caller prints only [`super::ops::public`]).
///
/// The value comes from `local.secret_value`: a no-echo prompt, or stdin. It is never an argument
/// (no `Command` has a field for it). It lives in a zeroizing buffer, is copied once into the one
/// `update` request, whose strings are wiped after the call, and is scrubbed from a refusal's
/// message, so no output, error or log line carries it.
pub(super) fn set(
    daemon: &mut dyn Daemon,
    local: &dyn Local,
    id: &str,
    key: &str,
    hosts: &[String],
    header: Option<Value>,
) -> Result<Value, Failure> {
    // The platform refuses a secret with no host (cloud_environment.secret_needs_host); so do we,
    // before asking for the value.
    if hosts.is_empty() {
        return Err(Failure::new(
            "cloud_environment.secret_needs_host",
            "a secret needs --host HOST",
            2,
        ));
    }
    let value = local.secret_value(key)?;
    if value.is_empty() || value.len() > MAX_VALUE_BYTES {
        return Err(Failure::new(
            "env.secret_size",
            format!("a secret's value is 1 to {} KiB", MAX_VALUE_BYTES / 1024),
            1,
        ));
    }
    let mut entry = json!({"name": key, "value": value.as_str(), "hosts": hosts});
    if let Some(header) = header {
        entry["header"] = header;
    }
    let mut params = json!({"id": id, "patch": {"set_secrets": [entry]}});
    let saved = daemon.call("update", &params);
    wipe(&mut params);
    saved.map_err(|mut failure| {
        failure.message = failure.message.replace(value.as_str(), "[redacted]");
        failure
    })
}
