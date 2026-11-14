use super::*;

fn session_id(value: u128) -> SessionPublicId {
    SessionPublicId::parse(format!("session_{value:032x}")).unwrap()
}

#[test]
fn scroll_uses_wire_decimal_offset_and_public_view_id() {
    let id = sidebar_view_id(&session_id(9)).unwrap();
    let value = SidebarRenderClientState::scroll(&id, u64::MAX, false);
    assert_eq!(value["kind"], "scroll");
    assert_eq!(value["sidebar_view_id"], id.as_str());
    assert_eq!(value["scroll"]["offset"], u64::MAX.to_string());
    assert_eq!(value["scroll"]["at_bottom"], false);
}
