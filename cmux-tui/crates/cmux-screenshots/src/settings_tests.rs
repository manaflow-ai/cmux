use super::*;

#[test]
fn settings_file_formats() {
    assert_eq!(
        SettingsFormat::Ini.value("savePath", "[General]\n savePath = /a/b \nother=1"),
        Some("/a/b".into())
    );
    assert_eq!(SettingsFormat::Ini.value("savePath", "savePath="), None);
    assert_eq!(
        SettingsFormat::Json.value("kapturesDir", r#"{"kapturesDir":"/k"}"#),
        Some("/k".into())
    );
    assert_eq!(SettingsFormat::Json.value("kapturesDir", "not json"), None);
}

#[test]
fn ini_edges() {
    assert_eq!(SettingsFormat::Ini.value("k", "k=a=b"), Some("a=b".into()));
    assert_eq!(SettingsFormat::Ini.value("k", "k==b"), Some("=b".into()));
    assert_eq!(SettingsFormat::Ini.value("k", "=k=v"), Some("v".into()));
    assert_eq!(SettingsFormat::Ini.value("k", "k = \r\nk=x\r\n"), None);
    assert_eq!(SettingsFormat::Ini.value("k", "other=1\r\nk=x\r\n"), Some("x".into()));
    assert_eq!(SettingsFormat::Json.value("k", r#"{"k":1}"#), None);
    assert_eq!(SettingsFormat::Json.value("k", r#"["k"]"#), None);
}
