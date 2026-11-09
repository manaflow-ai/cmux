//! Small helpers every part of the start shares.

use serde_json::Value;

/// `value[key]` without indexing: `Null` when absent.
pub(super) fn at<'a>(value: &'a Value, key: &str) -> &'a Value {
    const NULL: &Value = &Value::Null;
    value.get(key).unwrap_or(NULL)
}

/// `list` as owned words, for a step's arguments.
pub(super) fn words(list: &[&str]) -> Vec<String> {
    list.iter().map(|word| (*word).to_owned()).collect()
}
