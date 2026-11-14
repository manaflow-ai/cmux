use super::*;

#[test]
fn every_action_tool_maps_to_a_pool_action_the_pool_parses() {
    let args = json!({"slot": "s1", "x": 3, "y": 4, "text": "hi", "key": "Return",
                          "direction": "down", "url": "http://x", "wait_ms": 5});
    for tool in tools().as_array().unwrap() {
        let name = at(tool, "/name").as_str().unwrap();
        match action_for(name, &args) {
            Some(a) => {
                assert!(a.get("slot").is_none(), "{name}");
                serde_json::from_value::<crate::backend::Action>(a.clone())
                    .unwrap_or_else(|e| panic!("{name}: {a} does not parse: {e}"));
            }
            None => assert!(name == "desktop_lease" || name == "desktop_release", "{name}"),
        }
    }
}
