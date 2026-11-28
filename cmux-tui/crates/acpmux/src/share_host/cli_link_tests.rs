use super::ScreenLink;

#[test]
fn links_are_view_only_unless_asked_and_encode_the_name() {
    let link = ScreenLink {
        device: "D47F285E-d0ba-48b9-a593-508b0b9d1ab4",
        display: Some(17),
        name: Some("gui run #3"),
        control: false,
    };
    assert_eq!(
        link.native(),
        "cmux://mac-screen?device=d47f285e-d0ba-48b9-a593-508b0b9d1ab4&display=17&name=gui%20run%20%233"
    );
    assert!(link.web().starts_with("https://cmux.com/deeplink/screen?device=d47f285e-"));
    let control = ScreenLink { device: "x", display: None, name: None, control: true };
    assert_eq!(control.native(), "cmux://mac-screen?device=x&control=1");
}
