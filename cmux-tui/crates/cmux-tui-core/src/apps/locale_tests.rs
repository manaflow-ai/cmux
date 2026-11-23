use super::bcp47;

#[test]
fn posix_and_apple_locales_become_full_bcp47_tags() {
    for (raw, tag) in [
        ("en_US.UTF-8", Some("en-US")),
        ("en_US", Some("en-US")),
        ("de_CH.UTF-8@euro", Some("de-CH")),
        ("zh_Hans_CN", Some("zh-Hans-CN")),
        ("es_419", Some("es-419")),
        ("en-GB", Some("en-GB")),
        ("en_US@rg=gbzzzz", Some("en-US-u-rg-gbzzzz")),
        ("fr", Some("fr")),
        ("C", None),
        ("POSIX", None),
        ("C.UTF-8", None),
        ("", None),
    ] {
        assert_eq!(bcp47(raw).as_deref(), tag, "{raw}");
    }
}
