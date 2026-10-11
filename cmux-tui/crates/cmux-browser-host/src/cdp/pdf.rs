//! `tab.pdf` (`Page.printToPDF`), with Playwright's `page.pdf` options:
//! `format`, `width`, `height`, `landscape`, `printBackground`, `margin`.

use super::driver::Inner;
use crate::protocol::{DriverError, timeout_of};
use serde_json::{Value, json};
use std::time::Instant;

/// Paper sizes in inches (Playwright's `format` names).
const FORMATS: &[(&str, f64, f64)] = &[
    ("letter", 8.5, 11.0),
    ("legal", 8.5, 14.0),
    ("tabloid", 11.0, 17.0),
    ("ledger", 17.0, 11.0),
    ("a0", 33.1, 46.8),
    ("a1", 23.4, 33.1),
    ("a2", 16.54, 23.4),
    ("a3", 11.7, 16.54),
    ("a4", 8.27, 11.7),
    ("a5", 5.83, 8.27),
    ("a6", 4.13, 5.83),
];

/// A length in inches: a number is CSS pixels (96 per inch); a string may
/// end in px, in, cm or mm (Playwright's units).
pub(super) fn inches(value: &Value, name: &str) -> Result<Option<f64>, DriverError> {
    let invalid = || {
        DriverError::invalid(format!(
            "{name}: expected a number or a length such as \"1in\", \"2cm\", \"10mm\" or \"96px\""
        ))
    };
    let inches = match value {
        Value::Null => return Ok(None),
        Value::Number(n) => n.as_f64().ok_or_else(invalid)? / 96.0,
        Value::String(text) => {
            let text = text.trim().to_ascii_lowercase();
            let (number, per_inch) = if let Some(n) = text.strip_suffix("px") {
                (n, 96.0)
            } else if let Some(n) = text.strip_suffix("in") {
                (n, 1.0)
            } else if let Some(n) = text.strip_suffix("cm") {
                (n, 2.54)
            } else if let Some(n) = text.strip_suffix("mm") {
                (n, 25.4)
            } else {
                (text.as_str(), 96.0)
            };
            number.trim().parse::<f64>().map_err(|_| invalid())? / per_inch
        }
        _ => return Err(invalid()),
    };
    if !inches.is_finite() || inches < 0.0 {
        return Err(invalid());
    }
    Ok(Some(inches))
}

/// `Page.printToPDF` arguments for the protocol's `tab.pdf` params.
pub(super) fn print_args(params: &Value) -> Result<Value, DriverError> {
    let (mut width, mut height) = (8.5, 11.0);
    if let Some(format) = params.get("format").and_then(Value::as_str) {
        let lower = format.to_ascii_lowercase();
        let (_, w, h) = FORMATS.iter().find(|(name, _, _)| *name == lower).ok_or_else(|| {
            DriverError::invalid(format!(
                "format: expected Letter, Legal, Tabloid, Ledger or A0 to A6, got {format:?}"
            ))
        })?;
        (width, height) = (*w, *h);
    }
    let null = Value::Null;
    if let Some(w) = inches(params.get("width").unwrap_or(&null), "width")? {
        width = w;
    }
    if let Some(h) = inches(params.get("height").unwrap_or(&null), "height")? {
        height = h;
    }
    let mut args = json!({
        "paperWidth": width,
        "paperHeight": height,
        "landscape": params.get("landscape").and_then(Value::as_bool).unwrap_or(false),
        "printBackground": params.get("printBackground").and_then(Value::as_bool).unwrap_or(false),
        "transferMode": "ReturnAsBase64",
    });
    let margin = params.get("margin").unwrap_or(&null);
    for (side, key) in [
        ("top", "marginTop"),
        ("right", "marginRight"),
        ("bottom", "marginBottom"),
        ("left", "marginLeft"),
    ] {
        let value = margin.get(side).unwrap_or(&null);
        args[key] = json!(inches(value, &format!("margin.{side}"))?.unwrap_or(0.0));
    }
    Ok(args)
}

impl Inner {
    pub(super) fn pdf(&self, params: &Value) -> Result<Value, DriverError> {
        let session = self.session(params)?;
        let deadline = Instant::now() + timeout_of(params);
        let args = print_args(params)?;
        // Printing changes the page's media while it runs: one capture of
        // the tab at a time (`capture.rs`).
        let _turn = self.capture_turn(&session.target_id, deadline)?;
        let printed = self.send_until(&session, "Page.printToPDF", args, deadline)?;
        let data = printed["data"]
            .as_str()
            .ok_or_else(|| DriverError::invalid("Page.printToPDF returned no data"))?;
        Ok(json!({"base64": data}))
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn options_map_to_inches() {
        let args = print_args(&json!({})).unwrap();
        assert_eq!(
            (args["paperWidth"].as_f64(), args["paperHeight"].as_f64()),
            (Some(8.5), Some(11.0))
        );
        let args = print_args(&json!({"format": "A4", "landscape": true, "printBackground": true,
            "margin": {"top": "1in", "left": "2.54cm", "bottom": "25.4mm", "right": 96}}))
        .unwrap();
        assert_eq!(
            (args["paperWidth"].as_f64(), args["paperHeight"].as_f64()),
            (Some(8.27), Some(11.7))
        );
        assert_eq!(
            (args["landscape"].as_bool(), args["printBackground"].as_bool()),
            (Some(true), Some(true))
        );
        for key in ["marginTop", "marginLeft", "marginBottom", "marginRight"] {
            assert!((args[key].as_f64().unwrap() - 1.0).abs() < 1e-9, "{key}: {args}");
        }
        let args = print_args(&json!({"width": "480px", "height": "5in"})).unwrap();
        assert_eq!(
            (args["paperWidth"].as_f64(), args["paperHeight"].as_f64()),
            (Some(5.0), Some(5.0))
        );
        assert!(print_args(&json!({"format": "B5"})).is_err());
        assert!(print_args(&json!({"width": "wide"})).is_err());
        assert!(print_args(&json!({"margin": {"top": "-1in"}})).is_err());
    }
}
