use super::*;

#[test]
fn scancode_input_is_available_on_windows() {
    let _ = send_input_scancode as fn(u16, bool) -> Res<()>;
}
