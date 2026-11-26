use serde_json::{Value, json};

struct Home(std::path::PathBuf);
impl Drop for Home {
    fn drop(&mut self) {
        let _ = std::fs::remove_dir_all(&self.0);
    }
}

fn home(name: &str) -> Home {
    let path =
        std::env::temp_dir().join(format!("cmux-launch-cloud-env-{name}-{}", std::process::id()));
    let _ = std::fs::remove_dir_all(&path);
    std::fs::create_dir_all(&path).unwrap();
    Home(path)
}

fn launch(home: &Home, arguments: &[&str], environment: &[(&str, &str)]) -> Value {
    let request = json!({
        "bundleId": "com.cmuxterm.app.debug.cloud-env-test",
        "home": home.0.display().to_string(),
        "arguments": arguments,
        "environment": environment.iter().map(|(k, v)| ((*k).to_owned(), json!(v)))
            .collect::<serde_json::Map<_, _>>(),
    });
    crate::ops::call("cloud_environment_launch_read", &request).unwrap()
}

#[test]
fn a_known_deployment_answers_in_process() {
    let home = home("known");
    let reply = launch(&home, &["cmux"], &[]);
    assert_eq!(reply["selection"]["name"], "dev", "{reply}");
    assert_eq!(reply["selection"]["config_source"], "known_origin_fallback", "{reply}");
    assert_eq!(reply["selection"]["bundle_id"], "com.cmuxterm.app.debug.cloud-env-test");
    let staging =
        launch(&home, &["cmux", "--cloud-backend", "staging"], &[("CMUX_NEXT_CLOUD_ENV", "prod")]);
    assert_eq!(staging["selection"]["name"], "staging", "the arguments come first: {staging}");
    let prod = launch(&home, &["cmux"], &[("CMUX_NEXT_CLOUD_ENV", "prod")]);
    assert_eq!(prod["selection"]["name"], "prod", "{prod}");
}

#[test]
fn a_custom_origin_with_no_cache_goes_to_the_cli_and_a_bad_seed_fails() {
    let home = home("custom");
    assert_eq!(launch(&home, &["cmux", "--cloud-backend=http://127.0.0.1:9"], &[]), json!("fetch"));
    let bad = launch(&home, &["cmux", "--cloud-backend"], &[]);
    assert!(bad["error"].as_str().is_some_and(|m| m.contains("--cloud-backend")), "{bad}");
    let refused = launch(&home, &["cmux"], &[("CMUX_NEXT_CLOUD_BACKEND", "https://example.com")]);
    assert!(refused["error"].is_string(), "{refused}");
}

#[test]
fn a_request_with_no_bundle_or_home_is_refused() {
    assert!(crate::ops::call("cloud_environment_launch_read", &json!({})).is_err());
}
