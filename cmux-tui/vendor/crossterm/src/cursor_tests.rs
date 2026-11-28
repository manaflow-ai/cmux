use std::io::{self, stdout};

use crate::execute;

use super::{
    sys::position, MoveDown, MoveLeft, MoveRight, MoveTo, MoveUp, RestorePosition, SavePosition,
};

// Test is disabled, because it's failing on Travis
#[test]
#[ignore]
fn test_move_to() {
    let (saved_x, saved_y) = position().unwrap();

    execute!(stdout(), MoveTo(saved_x + 1, saved_y + 1)).unwrap();
    assert_eq!(position().unwrap(), (saved_x + 1, saved_y + 1));

    execute!(stdout(), MoveTo(saved_x, saved_y)).unwrap();
    assert_eq!(position().unwrap(), (saved_x, saved_y));
}

// Test is disabled, because it's failing on Travis
#[test]
#[ignore]
fn test_move_right() {
    let (saved_x, saved_y) = position().unwrap();
    execute!(io::stdout(), MoveRight(1)).unwrap();
    assert_eq!(position().unwrap(), (saved_x + 1, saved_y));
}

// Test is disabled, because it's failing on Travis
#[test]
#[ignore]
fn test_move_left() {
    execute!(stdout(), MoveTo(2, 0), MoveLeft(2)).unwrap();
    assert_eq!(position().unwrap(), (0, 0));
}

// Test is disabled, because it's failing on Travis
#[test]
#[ignore]
fn test_move_up() {
    execute!(stdout(), MoveTo(0, 2), MoveUp(2)).unwrap();
    assert_eq!(position().unwrap(), (0, 0));
}

// Test is disabled, because it's failing on Travis
#[test]
#[ignore]
fn test_move_down() {
    execute!(stdout(), MoveTo(0, 0), MoveDown(2)).unwrap();

    assert_eq!(position().unwrap(), (0, 2));
}

// Test is disabled, because it's failing on Travis
#[test]
#[ignore]
fn test_save_restore_position() {
    let (saved_x, saved_y) = position().unwrap();

    execute!(stdout(), SavePosition, MoveTo(saved_x + 1, saved_y + 1), RestorePosition).unwrap();

    let (x, y) = position().unwrap();

    assert_eq!(x, saved_x);
    assert_eq!(y, saved_y);
}
