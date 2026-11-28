use serde_json::json;
use std::path::Path;

use super::*;

#[test]
fn the_policy_wins_over_every_list() {
    let folder = Path::new("/Users/me/work/app");
    for policy in
        [json!({"projection.syncBack": false}), json!({"projection": {"syncBack": false}})]
    {
        assert_eq!(refused(Some(&policy), "", "", folder), Some("policy"));
    }
    for policy in [json!({"projection.readOnly": true}), json!({"projection": {"readOnly": true}})]
    {
        assert_eq!(read_only(Some(&policy), "", folder), Some("policy"));
        assert_eq!(refused(Some(&policy), "", "", folder), Some("read_only"));
    }
    let open = json!({"projection": {"syncBack": true, "readOnly": false}});
    assert_eq!(refused(Some(&open), "", "", folder), None);
    assert_eq!(read_only(Some(&open), "", folder), None);
}

#[test]
fn a_listed_folder_and_the_folders_inside_it_are_off() {
    let list = "/Users/me/work\n\n";
    assert_eq!(refused(None, list, "", Path::new("/Users/me/work/app")), Some("folder"));
    assert_eq!(refused(None, list, "", Path::new("/Users/me/work")), Some("folder"));
    assert_eq!(refused(None, list, "", Path::new("/Users/me/workshop")), None);
    assert_eq!(refused(None, "", list, Path::new("/Users/me/work/app")), Some("read_only"));
    assert_eq!(read_only(None, list, Path::new("/Users/me/work/app")), Some("folder"));
    assert_eq!(read_only(None, list, Path::new("/Users/me/other")), None);
}
