use super::*;
use serde_json::Value;

#[test]
fn every_vector_picks_the_daemon_the_rule_names() {
    let vectors: Value =
        serde_json::from_str(include_str!("../../../../../schemas/chief-cmux-target/vectors.json"))
            .unwrap();
    let env = vectors["case_environment"].as_object().unwrap();
    for case in vectors["cases"].as_array().unwrap() {
        let exists: Vec<&str> =
            case["sockets"].as_array().unwrap().iter().filter_map(Value::as_str).collect();
        let got = daemon_socket(
            |key| env.get(key).and_then(Value::as_str).map(str::to_owned),
            |path| exists.iter().any(|name| path == Path::new(name)),
        );
        assert_eq!(
            got.as_deref(),
            case["expect"]["daemon"].as_str().map(Path::new),
            "{}",
            case["name"]
        );
    }
}

#[test]
fn outside_a_chief_env_the_usual_resolution_applies() {
    let env = |key: &str| (key == APP_DAEMON_KEY).then(|| "/x/app-daemon.sock".to_owned());
    assert_eq!(daemon_socket(env, |_| true), None);
}
