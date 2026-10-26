//! In-place changes: `update VM` (name, labels, limits) and
//! `snapshot update SNAP` (also `snapshot rename`: name, labels, retention).
//!
//! Labels replace the whole set, as the API does. Clearing a value (a name,
//! a snapshot's ttl) means sending `null`, and clearing every label means
//! sending `{}`; the generated request types drop both, so those requests are
//! checked against the generated type first and then sent as JSON through the
//! same authenticated HTTP client.

use std::path::{Path, PathBuf};

use clap::{ArgGroup, Args};
use cmux_vm_client::raw::{Client, ClientInfo, types};
use serde_json::{Map, Value, json};

use crate::error::CliError;
use crate::output::Printer;
use crate::{fetch_body, request_body};

#[derive(Args, Debug)]
#[command(group(
    ArgGroup::new("change")
        .required(true)
        .multiple(true)
        .args(["name", "clear_name", "labels", "labels_file", "clear_labels", "idle", "max_run", "auto_delete"])
))]
pub(crate) struct UpdateArgs {
    /// VM id (vm_...)
    vm_id: String,
    /// New display name
    #[arg(long, conflicts_with = "clear_name")]
    name: Option<String>,
    /// Remove the display name
    #[arg(long)]
    clear_name: bool,
    /// Label KEY=VALUE; repeat for several. Labels REPLACE the VM's whole set
    /// (pass every label to keep); `cmux.` labels cannot be changed
    #[arg(long = "label", value_name = "KEY=VALUE")]
    labels: Vec<String>,
    /// JSON object of labels; replaces the whole set like --label (merged with --label)
    #[arg(long, value_name = "FILE")]
    labels_file: Option<PathBuf>,
    /// Remove every label (an empty set)
    #[arg(long, conflicts_with_all = ["labels", "labels_file"])]
    clear_labels: bool,
    /// Seconds without network activity before the VM pauses; -1 removes the limit
    /// (dev/test teams must stay between 1 and 300)
    #[arg(long, value_name = "SECONDS", allow_negative_numbers = true)]
    idle: Option<i64>,
    /// Seconds the VM may run before it stops; -1 removes the limit
    #[arg(long, value_name = "SECONDS", allow_negative_numbers = true)]
    max_run: Option<i64>,
    /// Seconds after which the VM is deleted; -1 removes the deadline
    #[arg(long, value_name = "SECONDS", allow_negative_numbers = true)]
    auto_delete: Option<i64>,
}

#[derive(Args, Debug)]
#[command(group(
    ArgGroup::new("change")
        .required(true)
        .multiple(true)
        .args(["name", "clear_name", "labels", "labels_file", "clear_labels", "ttl", "no_ttl", "auto_delete", "no_auto_delete"])
))]
pub(crate) struct SnapshotUpdateArgs {
    /// Snapshot id (snap_...)
    snapshot_id: String,
    /// New display name
    #[arg(long, conflicts_with = "clear_name")]
    name: Option<String>,
    /// Remove the display name
    #[arg(long)]
    clear_name: bool,
    /// Label KEY=VALUE; repeat for several. Labels REPLACE the snapshot's whole
    /// set (pass every label to keep); `cmux.` labels cannot be changed
    #[arg(long = "label", value_name = "KEY=VALUE")]
    labels: Vec<String>,
    /// JSON object of labels; replaces the whole set like --label (merged with --label)
    #[arg(long, value_name = "FILE")]
    labels_file: Option<PathBuf>,
    /// Remove every label (an empty set)
    #[arg(long, conflicts_with_all = ["labels", "labels_file"])]
    clear_labels: bool,
    /// Delete the snapshot this many seconds after it was taken (60-31536000)
    #[arg(long, value_name = "SECONDS", conflicts_with = "no_ttl")]
    ttl: Option<i64>,
    /// Remove the ttl deadline
    #[arg(long)]
    no_ttl: bool,
    /// Delete the snapshot once this many seconds pass without a VM created from it
    #[arg(long, value_name = "SECONDS", conflicts_with = "no_auto_delete")]
    auto_delete: Option<i64>,
    /// Remove the unused-snapshot deletion window
    #[arg(long)]
    no_auto_delete: bool,
}

/// `--label` flags over a `--labels-file` object; `None` when neither is given.
pub(crate) fn labels(
    flags: &[String],
    file: Option<&Path>,
    clear: bool,
) -> Result<Option<Value>, CliError> {
    if clear {
        return Ok(Some(Value::Object(Map::new())));
    }
    if flags.is_empty() && file.is_none() {
        return Ok(None);
    }
    let mut set = Map::new();
    if let Some(file) = file {
        match crate::network::read_json_file(file, "labels file")? {
            Value::Object(fields) => {
                for (key, value) in fields {
                    if !value.is_string() {
                        return Err(CliError::usage(
                            "label values in the labels file must be strings",
                        ));
                    }
                    set.insert(key, value);
                }
            }
            _ => return Err(CliError::usage("the labels file must be a JSON object")),
        }
    }
    for flag in flags {
        match flag.split_once('=') {
            Some((key, value)) if !key.is_empty() => {
                set.insert(key.to_owned(), Value::String(value.to_owned()));
            }
            _ => return Err(CliError::usage("--label takes KEY=VALUE")),
        }
    }
    Ok(Some(Value::Object(set)))
}

/// Whether a request body holds a value the generated type would drop: a
/// `null` (clear) or an empty label set.
pub(crate) fn needs_plain_json(body: &Value) -> bool {
    body.as_object().is_some_and(|fields| {
        fields.iter().any(|(key, value)| {
            value.is_null() || (key == "labels" && value.as_object().is_some_and(Map::is_empty))
        })
    })
}

/// The update body: unset fields omitted, cleared fields `null`.
pub(crate) fn vm_body(args: &UpdateArgs) -> Result<Value, CliError> {
    let mut body = Map::new();
    if let Some(name) = &args.name {
        body.insert("displayName".into(), json!(name));
    } else if args.clear_name {
        body.insert("displayName".into(), Value::Null);
    }
    if let Some(labels) = labels(&args.labels, args.labels_file.as_deref(), args.clear_labels)? {
        body.insert("labels".into(), labels);
    }
    for (key, value) in [
        ("idleTimeoutSeconds", args.idle),
        ("maxRunSeconds", args.max_run),
        ("autoDeleteSeconds", args.auto_delete),
    ] {
        if let Some(value) = value {
            body.insert(key.into(), json!(value));
        }
    }
    Ok(Value::Object(body))
}

pub(crate) fn snapshot_body(args: &SnapshotUpdateArgs) -> Result<Value, CliError> {
    let mut body = Map::new();
    if let Some(name) = &args.name {
        body.insert("displayName".into(), json!(name));
    } else if args.clear_name {
        body.insert("displayName".into(), Value::Null);
    }
    if let Some(labels) = labels(&args.labels, args.labels_file.as_deref(), args.clear_labels)? {
        body.insert("labels".into(), labels);
    }
    if let Some(ttl) = args.ttl {
        body.insert("ttlSeconds".into(), json!(ttl));
    } else if args.no_ttl {
        body.insert("ttlSeconds".into(), Value::Null);
    }
    if let Some(window) = args.auto_delete {
        body.insert("autoDeleteSeconds".into(), json!(window));
    } else if args.no_auto_delete {
        body.insert("autoDeleteSeconds".into(), Value::Null);
    }
    Ok(Value::Object(body))
}

pub(crate) async fn update_vm(
    client: &Client,
    args: UpdateArgs,
    mut out: Printer<'_>,
) -> Result<(), CliError> {
    let id = crate::files::vm_id(&args.vm_id)?;
    let value = vm_body(&args)?;
    let typed: types::UpdateVmRequest = request_body(value.clone())?;
    let body = if needs_plain_json(&value) {
        send_json(
            client,
            reqwest::Method::PATCH,
            &format!("/v1/vms/{}", id.as_str()),
            &value,
        )
        .await?
    } else {
        fetch_body(client.vms_update_vm(id.as_str(), None, &typed)).await?
    };
    out.vm(&body)?;
    out.name_and_labels(&body)
}

pub(crate) async fn update_snapshot(
    client: &Client,
    args: SnapshotUpdateArgs,
    mut out: Printer<'_>,
) -> Result<(), CliError> {
    let id = args
        .snapshot_id
        .parse::<types::SnapshotId>()
        .map_err(|_| CliError::usage("invalid snapshot id"))?;
    let value = snapshot_body(&args)?;
    let typed: types::UpdateSnapshotRequest = request_body(value.clone())?;
    let body = if needs_plain_json(&value) {
        send_json(
            client,
            reqwest::Method::PATCH,
            &format!("/v1/snapshots/{}", id.as_str()),
            &value,
        )
        .await?
    } else {
        fetch_body(client.snapshots_update_snapshot(id.as_str(), None, &typed)).await?
    };
    out.snapshot(&body)?;
    if out.is_json() {
        return Ok(());
    }
    out.labels_line(&body)
}

/// Sends a JSON body the generated client cannot express (an explicit
/// `null` or `{}`) with the client's own HTTP client, so the API key, team
/// header, timeouts and user agent are the same. `path` holds only checked
/// ids.
pub(crate) async fn send_json(
    client: &Client,
    method: reqwest::Method,
    path: &str,
    body: &Value,
) -> Result<Vec<u8>, CliError> {
    let url = format!("{}{path}", client.baseurl());
    let response = client
        .client()
        .request(method, url)
        .header(reqwest::header::ACCEPT, "application/json")
        .json(body)
        .send()
        .await
        .map_err(|e| CliError::network(format!("could not reach the cmux VM API: {e}")))?;
    let status = response.status();
    let bytes = response.bytes().await.map_err(|e| {
        CliError::network(format!(
            "the response from the cmux VM API was cut off: {e}"
        ))
    })?;
    if status.is_success() {
        Ok(bytes.to_vec())
    } else {
        Err(CliError::from_http(status.as_u16(), &bytes))
    }
}

impl Printer<'_> {
    /// The name and labels lines that follow a VM's human output.
    fn name_and_labels(&mut self, body: &[u8]) -> Result<(), CliError> {
        if self.is_json() {
            return Ok(());
        }
        let value: Value = serde_json::from_slice(body).unwrap_or(Value::Null);
        let name = value["displayName"].as_str().unwrap_or("").escape_debug();
        self.line(&format!("{:<11}{name}", "name"))?;
        self.labels_line(body)
    }

    fn labels_line(&mut self, body: &[u8]) -> Result<(), CliError> {
        let value: Value = serde_json::from_slice(body).unwrap_or(Value::Null);
        let labels = value["labels"]
            .as_object()
            .map(|labels| {
                labels
                    .iter()
                    .map(|(k, v)| format!("{k}={}", v.as_str().unwrap_or("")))
                    .collect::<Vec<_>>()
                    .join(", ")
            })
            .unwrap_or_default();
        self.line(&format!("{:<11}{}", "labels", labels.escape_debug()))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn label_flags_override_the_file_and_clear_is_an_empty_set() {
        assert_eq!(labels(&[], None, false).unwrap(), None);
        assert_eq!(
            labels(&["team=a".into(), "x=b=c".into()], None, false).unwrap(),
            Some(json!({"team": "a", "x": "b=c"}))
        );
        assert_eq!(labels(&[], None, true).unwrap(), Some(json!({})));
        assert!(labels(&["novalue".into()], None, false).is_err());
        assert!(labels(&["=v".into()], None, false).is_err());
    }

    #[test]
    fn clears_and_empty_label_sets_need_plain_json() {
        assert!(!needs_plain_json(
            &json!({"displayName": "a", "labels": {"k": "v"}})
        ));
        assert!(needs_plain_json(&json!({"displayName": null})));
        assert!(needs_plain_json(&json!({"labels": {}})));
        assert!(needs_plain_json(&json!({"ttlSeconds": null})));
    }
}
