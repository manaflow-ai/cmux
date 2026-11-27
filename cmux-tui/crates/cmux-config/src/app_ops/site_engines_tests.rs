use serde_json::json;

use crate::app_ops::call;

#[test]
fn ops_answer_the_wire_shapes() {
    let root = json!({"browser": {"siteEngines": {"*.Spotify.com/": "webkit", "x.com": "safari"}}});
    let reply = call("site_engines.read", &json!({ "root": root })).unwrap();
    assert_eq!(reply["rules"], json!({"spotify.com": "webkit"}));
    assert_eq!(reply["problems"], json!(["x.com: expected a site and \"chromium\" or \"webkit\""]));
    let reply = call("site_engines.read", &json!({ "root": {} })).unwrap();
    assert_eq!(reply, json!({"rules": null, "problems": []}));
    let reply =
        call("site_engines.normalized", &json!({"rules": {"HTTP://A.com/": "chromium"}})).unwrap();
    assert_eq!(reply, json!({"rules": {"a.com": "chromium"}}));
    let request = json!({"rules": {"spotify.com": "webkit"}, "scheme": "https", "host": "open.spotify.com",
                         "path": "/track"});
    assert_eq!(call("site_engines.engine", &request).unwrap(), json!({"engine": "webkit"}));
    let request =
        json!({"rules": {"spotify.com": "webkit"}, "scheme": "file", "host": "", "path": "/"});
    assert_eq!(call("site_engines.engine", &request).unwrap(), json!({"engine": null}));
    assert!(call("site_engines.engine", &json!({"rules": {}})).is_err());
}
