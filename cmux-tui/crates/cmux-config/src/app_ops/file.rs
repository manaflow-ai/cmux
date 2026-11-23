//! `file.prepare_launch`: the app's first launch makes cmux-next.json (Swift
//! `CmuxConfigFile.prepareLaunchFile`), on [`crate::prepare_launch_file`].

use std::path::Path;

use serde_json::{Value, json};

use super::{OpError, string};

/// `{next, classic?}` to `{created_empty}` (whether this launch wrote a new
/// empty file, a fresh install's one sign) or `{error}`. With no `classic`
/// (a file `CMUX_NEXT_CONFIG_FILE` names) nothing is made.
pub fn prepare_launch(request: &Value) -> Result<Value, OpError> {
    let next = string(request, "next")?;
    let classic = match request.get("classic") {
        None | Some(Value::Null) => None,
        Some(_) => Some(Path::new(string(request, "classic")?)),
    };
    Ok(match crate::prepare_launch_file(Path::new(next), classic) {
        Ok(created_empty) => json!({ "created_empty": created_empty }),
        Err(error) => json!({ "error": error.to_string() }),
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_fresh_file_is_reported_once_and_bad_requests_are_refused() {
        let dir = std::env::temp_dir().join(format!("cmux-config-file-op-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&dir);
        let request =
            json!({ "next": dir.join("cmux-next.json"), "classic": dir.join("cmux.json") });
        assert_eq!(prepare_launch(&request), Ok(json!({ "created_empty": true })));
        assert_eq!(prepare_launch(&request), Ok(json!({ "created_empty": false })));
        assert!(prepare_launch(&json!({})).is_err());
        assert!(prepare_launch(&json!({ "next": "x", "classic": 1 })).is_err());
        let _ = std::fs::remove_dir_all(&dir);
    }
}
