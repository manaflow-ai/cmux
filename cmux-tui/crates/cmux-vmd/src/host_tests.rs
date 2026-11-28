use super::*;

#[test]
fn names_are_path_safe() {
    assert!(valid_name("ubuntu-24.04"));
    assert!(!valid_name("../etc"));
    assert!(!valid_name("a/b"));
    assert!(!valid_name(".hidden"));
    assert!(!valid_name(""));
}

#[test]
fn mmds_serves_the_machine_id_where_cmux_host_reads_it() {
    let id = new_id("vm");
    let data = mmds_data(&id);
    assert_eq!(data["latest"]["meta-data"]["instance-id"], id.as_str());
    let cfg = mmds_config();
    assert_eq!(cfg["version"], "V2");
    assert_eq!(cfg["network_interfaces"], json!(["eth0"]));
    // cmux-host accepts only [A-Za-z0-9._-]{1,128} as an instance id.
    assert!(id.len() <= 128);
    assert!(id.bytes().all(|b| b.is_ascii_alphanumeric() || matches!(b, b'.' | b'_' | b'-')));
}

#[test]
fn ids_are_path_safe() {
    assert!(valid_name(&new_id("vm")));
}
