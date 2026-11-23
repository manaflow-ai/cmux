#[test]
fn every_language_has_the_mount_messages() {
    let en = super::server_mount_for_locale("en_US.UTF-8");
    let ja = super::server_mount_for_locale("ja_JP.UTF-8");
    assert!(en.daemon_lifecycle_deprecated.contains("cmux daemon {verb}"));
    assert!(ja.daemon_lifecycle_deprecated.contains("cmux daemon {verb}"));
    assert!(ja.server_global_option_refused.contains("{option}"));
    assert_ne!(en.server_is_machine_server, ja.server_is_machine_server);
    assert!(
        en.pair_needs_code.contains("cmux pair CODE")
            && ja.pair_needs_code.contains("cmux pair CODE")
    );
}
