//! A panic on any server thread lands in `<CMUX_APP_DATA_DIR>/panics.jsonl`
//! as one `cmux-panic-log` line labeled `cmux-cloud`.

use cmux_cloud::app_env::AppEnv;
use cmux_cloud::panic_log;

#[test]
fn a_thread_panic_writes_one_line_in_the_data_folder() {
    let data = std::env::temp_dir().join(format!("cmux-cloud-panic-{}", std::process::id()));
    std::fs::create_dir_all(&data).unwrap();
    let env = AppEnv::from_vars([("CMUX_APP_DATA_DIR", data.as_os_str())]);
    let path = panic_log::log_path(&env).unwrap();
    assert_eq!(path, data.join("panics.jsonl"));
    let _ = std::fs::remove_file(&path);
    // The same install as `main`.
    cmux_panic_log::install(path.clone(), panic_log::fields(), |_| false);

    let joined = std::thread::Builder::new()
        .name("cloud-worker".into())
        // crash-allow: the panic under test
        .spawn(|| panic!("cloud test panic"))
        .unwrap()
        .join();
    assert!(joined.is_err());

    let text = std::fs::read_to_string(&path).unwrap();
    let lines: Vec<serde_json::Value> =
        text.lines().map(|line| serde_json::from_str(line).unwrap()).collect();
    assert_eq!(lines.len(), 1, "{text}");
    assert_eq!(lines[0]["process"], "cmux-cloud");
    assert_eq!(lines[0]["message"], "cloud test panic");
    assert_eq!(lines[0]["thread"], "cloud-worker");
    assert_eq!(lines[0]["test"], false);
    let _ = std::fs::remove_dir_all(&data);
}

#[test]
fn no_data_folder_means_no_log() {
    let env = AppEnv::from_vars(std::iter::empty::<(&str, &str)>());
    assert_eq!(panic_log::log_path(&env), None);
}
