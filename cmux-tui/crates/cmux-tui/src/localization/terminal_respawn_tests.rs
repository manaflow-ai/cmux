#[test]
fn every_language_has_the_respawn_marker() {
    let en = super::text_for(super::super::catalog_for_locale("en_US.UTF-8"));
    let ja = super::text_for(super::super::catalog_for_locale("ja_JP.UTF-8"));
    assert_eq!(en.restored, "\u{2014} session restored (previous process ended) \u{2014}");
    assert!(ja.restored_command.contains("{program}") && en.restored_command.contains("{program}"));
    assert!(ja.restored_agent.contains("{command}") && en.restored_agent.contains("{command}"));
    assert_ne!(en.restored, ja.restored);
    assert_ne!(en.recovered_workspace, ja.recovered_workspace);
    assert!(ja.stopped.contains("{program}") && en.stopped.contains("{program}"));
    assert_ne!(en.stopped, ja.stopped);
}

#[test]
fn every_language_has_the_last_command_marker() {
    let en = super::text_for(super::super::catalog_for_locale("en_US.UTF-8"));
    let ja = super::text_for(super::super::catalog_for_locale("ja_JP.UTF-8"));
    for last in [en.restored_last, ja.restored_last] {
        assert!(last.contains("{command}") && last.contains("{code}"));
    }
    for last in [en.restored_last_no_code, ja.restored_last_no_code] {
        assert!(last.contains("{command}") && !last.contains("{code}"));
    }
    assert_ne!(en.restored_last, ja.restored_last);
}
