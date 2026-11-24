use super::launch_identities;

#[test]
fn every_spelling_of_a_program_is_one_identity() {
    for id in ["cmd", "CMD.EXE", "C:\\Windows\\System32\\cmd.exe", "\\\\host\\share\\Cmd.exe"] {
        assert_eq!(launch_identities(id).unwrap(), vec!["cmd.exe".to_string()], "{id}");
    }
    assert!(launch_identities("ms-settings:privacy").is_err());
}
