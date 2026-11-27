//! The customize doctor's app-wide toast (`customize.doctorNotice`, the Mac app's
//! `CustomizeDoctorNotice`) is off unless someone turns it on. Leo 2026-11-25: "did we remove
//! these by default yet", "make it stop showing the customization not applied/reviewd and shit
//! popup tosts". Settings' doctor card shows the findings inline; the toggle stays.

use cmux_config::Schema;
use serde_json::Value;

const KEY: &str = "customize.doctorNotice";

#[test]
fn the_customization_notice_toast_is_off_by_default() {
    let row = Schema::embedded().row(KEY).expect("customize.doctorNotice is a settings row");
    assert_eq!(row.default, Some(Value::Bool(false)), "{KEY} pops no toast unless turned on");
}

#[test]
fn the_customization_notice_toggle_is_still_offered() {
    let row = Schema::embedded().row(KEY).expect("customize.doctorNotice is a settings row");
    assert_eq!(row.kind.name(), "toggle", "the person can still turn the toast on");
}
