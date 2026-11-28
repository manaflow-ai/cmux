#[test]
fn new_tab_prefetch_dispatches_through_the_json_channel() {
    let request = br#"{"parked":{"width":1000,"height":800},"splits":[{"width":500,"height":800}],"cached":[]}"#;
    let reply = crate::respond_op_module(b"new_tab_prefetch", request).unwrap().unwrap();
    let sizes: serde_json::Value = serde_json::from_slice(&reply).unwrap();
    assert_eq!(sizes[0]["width"], 500.0);
    assert_eq!(sizes[1]["width"], 1000.0);
}
