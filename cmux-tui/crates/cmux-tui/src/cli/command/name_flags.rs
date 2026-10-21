//! `tab rename` and `workspace rename` name flags: `--name`, and the name
//! provenance tabs and workspaces share (`--source`, `--expected-generation`,
//! `--expected-name-revision`, hq#1957). `workspace rename --release-to-auto`
//! hands the current name back to the automatic namer, so it takes no name.

use cmux_tui_core::resource::ResourceOperation;
use serde_json::{Map, Value};

use super::{Flags, UsageError, insert_optional_string, validate_decimal, validate_one_of};

pub(super) fn rename_params(
    operation: ResourceOperation,
    flags: &mut Flags,
) -> Result<Map<String, Value>, UsageError> {
    let mut params = Map::new();
    let release =
        operation == ResourceOperation::WorkspaceRename && flags.boolean("release-to-auto");
    if release {
        if flags.values.contains_key("name") {
            return Err(UsageError::new("--release-to-auto keeps the current name; drop --name"));
        }
        params.insert("source".into(), Value::String("auto".into()));
        params.insert("release".into(), Value::Bool(true));
    } else {
        params.insert("name".into(), Value::String(flags.required("name")?));
    }
    if matches!(operation, ResourceOperation::TabRename | ResourceOperation::WorkspaceRename) {
        if let Some(source) = flags.take("source") {
            validate_one_of("--source", &source, &["user", "auto"])?;
            if release && source != "auto" {
                return Err(UsageError::new("--release-to-auto hands the name to --source auto"));
            }
            params.insert("source".into(), Value::String(source));
        }
        insert_optional_string(&mut params, flags, "expected-generation", "expected_generation");
        if let Some(revision) = flags.take("expected-name-revision") {
            validate_decimal("--expected-name-revision", &revision)?;
            params.insert("expected_name_revision".into(), Value::String(revision));
        }
    }
    Ok(params)
}
