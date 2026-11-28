use serde_json::json;

#[test]
fn new_tab_split_layout_dispatch_keeps_the_new_pane_and_final_ratio() {
    let request = json!({"tree": {"split": "s", "axis": "horizontal", "ratio": 0.5,
        "a": {"pane": "a"}, "b": {"pane": "b"}}, "split": "s", "ratio": 0.625});
    let reply =
        crate::respond_op_module(b"new_tab_split_layout", &serde_json::to_vec(&request).unwrap())
            .expect("registered operation")
            .unwrap();
    let value: serde_json::Value = serde_json::from_slice(&reply).unwrap();
    assert_eq!(value["ratio"], 0.625);
    assert_eq!(value["a"]["b"]["pane"], "__new-tab-divider-pane");
    assert_eq!(value["b"]["pane"], "b");
}
