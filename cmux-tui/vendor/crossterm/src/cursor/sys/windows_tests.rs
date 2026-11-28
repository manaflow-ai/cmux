use super::{
    move_down, move_left, move_right, move_to, move_to_column, move_to_next_line,
    move_to_previous_line, move_to_row, move_up, position, restore_position, save_position,
};
use crate::terminal::sys::temp_screen_buffer;
use serial_test::serial;

#[test]
#[serial]
fn test_move_to_winapi() {
    let _test_screen = temp_screen_buffer().unwrap();

    let (saved_x, saved_y) = position().unwrap();

    move_to(saved_x + 1, saved_y + 1).unwrap();
    assert_eq!(position().unwrap(), (saved_x + 1, saved_y + 1));

    move_to(saved_x, saved_y).unwrap();
    assert_eq!(position().unwrap(), (saved_x, saved_y));
}

#[test]
#[serial]
fn test_move_right_winapi() {
    let _test_screen = temp_screen_buffer().unwrap();

    let (saved_x, saved_y) = position().unwrap();
    move_right(1).unwrap();
    assert_eq!(position().unwrap(), (saved_x + 1, saved_y));
}

#[test]
#[serial]
fn test_move_left_winapi() {
    let _test_screen = temp_screen_buffer().unwrap();

    move_to(2, 0).unwrap();

    move_left(2).unwrap();

    assert_eq!(position().unwrap(), (0, 0));
}

#[test]
#[serial]
fn test_move_up_winapi() {
    let _test_screen = temp_screen_buffer().unwrap();

    move_to(0, 2).unwrap();

    move_up(2).unwrap();

    assert_eq!(position().unwrap(), (0, 0));
}

#[test]
#[serial]
fn test_move_to_next_line_winapi() {
    let _test_screen = temp_screen_buffer().unwrap();

    move_to(0, 2).unwrap();

    move_to_next_line(2).unwrap();

    assert_eq!(position().unwrap(), (0, 4));
}

#[test]
#[serial]
fn test_move_to_previous_line_winapi() {
    let _test_screen = temp_screen_buffer().unwrap();

    move_to(0, 2).unwrap();

    move_to_previous_line(2).unwrap();

    assert_eq!(position().unwrap(), (0, 0));
}

#[test]
#[serial]
fn test_move_to_column_winapi() {
    let _test_screen = temp_screen_buffer().unwrap();

    move_to(0, 2).unwrap();

    move_to_column(12).unwrap();

    assert_eq!(position().unwrap(), (12, 2));
}

#[test]
#[serial]
fn test_move_to_row_winapi() {
    let _test_screen = temp_screen_buffer().unwrap();

    move_to(0, 2).unwrap();

    move_to_row(5).unwrap();

    assert_eq!(position().unwrap(), (0, 5));
}

#[test]
#[serial]
fn test_move_down_winapi() {
    let _test_screen = temp_screen_buffer().unwrap();

    move_to(0, 0).unwrap();

    move_down(2).unwrap();

    assert_eq!(position().unwrap(), (0, 2));
}

#[test]
#[serial]
fn test_save_restore_position_winapi() {
    let _test_screen = temp_screen_buffer().unwrap();

    let (saved_x, saved_y) = position().unwrap();

    save_position().unwrap();
    move_to(saved_x + 1, saved_y + 1).unwrap();
    restore_position().unwrap();

    let (x, y) = position().unwrap();

    assert_eq!(x, saved_x);
    assert_eq!(y, saved_y);
}
