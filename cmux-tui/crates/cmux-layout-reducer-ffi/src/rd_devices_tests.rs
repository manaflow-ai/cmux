use super::*;

#[test]
fn the_channel_serves_rd_devices_ops() {
    assert!(handles(b"rd_devices_setup_row") && !handles(b"tab_discard_plan"));
    let reply = respond(b"rd_devices_duration_text", br#"{"seconds": 1347}"#).unwrap();
    assert_eq!(reply, br#""22m 27s""#);
    assert_eq!(respond(b"rd_devices_nope", b"{}"), Err(ERR_INVALID));
}
