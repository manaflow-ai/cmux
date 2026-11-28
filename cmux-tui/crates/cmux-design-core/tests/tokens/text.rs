//! Parity tests for `tokens::text`: the Swift cases of ProcessFontSmoothingTests,
//! FontSmoothingSettingTests, TitleRollTests, EmptyLabelMeasureTests and
//! ChromeFontSmoothingLiveTests, plus pins worked by hand from the Swift formulas.

#[path = "text/glyph_mask.rs"]
mod glyph_mask;
#[path = "text/label.rs"]
mod label;
#[path = "text/refresh.rs"]
mod refresh;
#[path = "text/smoothing.rs"]
mod smoothing;
#[path = "text/title.rs"]
mod title;

use cmux_design_core::ops::{OpError, call};
use serde_json::json;

#[test]
fn unknown_text_op_is_unknown() {
    assert_eq!(call("tokens.text_nope", &json!({})), Err(OpError::Unknown));
}

#[test]
fn bad_request_is_invalid() {
    assert!(matches!(
        call("tokens.text_apply_smoothing", &json!({"mode": "bogus"})),
        Err(OpError::Invalid(_))
    ));
}
