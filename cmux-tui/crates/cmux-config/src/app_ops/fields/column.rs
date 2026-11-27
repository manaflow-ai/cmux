//! Swift `ColumnLayoutSettings`: the `layout.*` column and split defaults. A bad value is the default
//! plus a diagnostic (a number out of range is refused, not clamped).

use serde_json::{Value, json};

use super::reader::{default_of, invalid, range_of, value_at};

struct Ctx<'a> {
    root: &'a Value,
    diags: Vec<Value>,
}

impl Ctx<'_> {
    fn choice(&mut self, path: &[&str], key: &str, allowed: &[&str]) -> Value {
        let default = default_of(key);
        let Some(value) = value_at(self.root, path) else { return default };
        match value.as_str().filter(|text| allowed.contains(text)) {
            Some(_) => value.clone(),
            None => {
                let list =
                    allowed.iter().map(|c| format!("\"{c}\"")).collect::<Vec<_>>().join(", ");
                self.diags.push(invalid(path.join("."), format!("expected one of {list}")));
                default
            }
        }
    }

    fn number(&mut self, key: &str) -> Value {
        let path: Vec<&str> = key.split('.').collect();
        let default = default_of(key);
        let Some(value) = value_at(self.root, &path) else { return default };
        let (lo, hi) = range_of(key);
        match value.as_f64().filter(|n| (lo..=hi).contains(n)) {
            Some(_) => value.clone(),
            None => {
                self.diags.push(invalid(
                    key,
                    format!("expected points from {} to {}", lo as i64, hi as i64),
                ));
                default
            }
        }
    }

    fn bool(&mut self, key: &str) -> Value {
        let path: Vec<&str> = key.split('.').collect();
        let default = default_of(key);
        match value_at(self.root, &path) {
            None => default,
            Some(value) if value.is_boolean() => value.clone(),
            Some(_) => {
                self.diags.push(invalid(key, "expected true or false"));
                default
            }
        }
    }

    /// `path`, or `legacy` when only the old key is set (R87).
    fn pick<'p>(&self, path: &'p [&'p str], legacy: &'p [&'p str]) -> &'p [&'p str] {
        if value_at(self.root, path).is_none() && value_at(self.root, legacy).is_some() {
            legacy
        } else {
            path
        }
    }
}

pub(super) fn column_layout(root: &Value) -> (Value, Vec<Value>) {
    let mut cx = Ctx { root, diags: vec![] };
    let split = cx.choice(&["layout", "splitSizing"], "layout.splitSizing", &["even", "halve"]);
    let modes = ["matchCurrent", "fitScreen", "fixed"];
    let (mode, fixed) = match value_at(root, &["layout", "newColumnWidth"]).and_then(Value::as_f64)
    {
        Some(number) => {
            let (lo, hi) = range_of("layout.defaultColumnWidth");
            if (lo..=hi).contains(&number) {
                (json!("fixed"), json!(number))
            } else {
                cx.diags.push(invalid(
                    "layout.newColumnWidth",
                    "expected \"matchCurrent\", \"fitScreen\", \"fixed\" or a share from 0.1 to 1.0",
                ));
                (default_of("layout.newColumnWidth"), Value::Null)
            }
        }
        None => {
            (cx.choice(&["layout", "newColumnWidth"], "layout.newColumnWidth", &modes), Value::Null)
        }
    };
    let edge_path = cx.pick(&["layout", "dockColumnEdge"], &["layout", "stickyColumnEdge"]);
    let edge = cx.choice(
        edge_path,
        "layout.dockColumnEdge",
        &["nearest", "left", "right", "top", "bottom"],
    );
    let mode_path = cx.pick(&["layout", "dockColumnMode"], &["layout", "stickyColumnMode"]);
    // "floating" is the UI name of `overlay`; both are accepted.
    let dock_mode = if value_at(root, mode_path).and_then(Value::as_str) == Some("floating") {
        json!("overlay")
    } else {
        cx.choice(mode_path, "layout.dockColumnMode", &["docked", "overlay"])
    };
    let orientation = cx.choice(
        &["layout", "frameOrientation"],
        "layout.frameOrientation",
        &["columnMajor", "rowMajor"],
    );
    let modifier =
        cx.choice(&["layout", "scrollModifier"], "layout.scrollModifier", &["command", "none"]);
    let width = cx.number("layout.minimumPaneWidth");
    let height = cx.number("layout.minimumPaneHeight");
    let rows = cx.bool("layout.rows");
    let follows = cx.bool("layout.focusFollowsMouse");
    let areas = cx.bool("layout.scrollAreas");
    let pages = cx.bool("layout.pagesHandleCommandScroll");
    let values = json!({
        "splitSizing": split, "newColumnWidth": {"mode": mode, "fixed": fixed},
        "dockColumnEdge": edge, "dockColumnMode": dock_mode, "frameOrientation": orientation,
        "scrollModifier": modifier, "minimumPaneWidth": width, "minimumPaneHeight": height,
        "rows": rows, "focusFollowsMouse": follows, "scrollAreas": areas, "pagesHandleCommandScroll": pages,
    });
    (json!({"values": values}), cx.diags)
}
