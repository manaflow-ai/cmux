//! The C ABI of the sidebar's per-project caps (`cmux_sidebar_project_rows`, `cmux_sidebar_needs_you`): the
//! answers match the pure rules, the structs have the header's sizes, a short buffer says how much it needs, and a
//! null pointer writes nothing.

use cmux_layout_reducer::sidebar_caps::{self, Active, ProjectCaps};
use cmux_layout_reducer_ffi::sidebar_caps::{
    CmuxSidebarActive, CmuxSidebarCaps, CmuxSidebarProjectTail, TAIL_SHOW_LESS, TAIL_SHOW_MORE, cmux_sidebar_needs_you,
    cmux_sidebar_project_rows,
};
use cmux_layout_reducer_ffi::{ERR_BUFFER, ERR_NULL, OK};
use std::ptr;

fn active(index: u32, flags: u8) -> CmuxSidebarActive {
    CmuxSidebarActive { index, flags, reserved: [0; 3] }
}

#[test]
fn the_structs_have_the_header_sizes() {
    assert_eq!(size_of::<CmuxSidebarActive>(), 8);
    assert_eq!(size_of::<CmuxSidebarCaps>(), 12);
    assert_eq!(size_of::<CmuxSidebarProjectTail>(), 24);
}

#[test]
fn a_project_answers_as_the_rules_do() {
    let entries = [active(8, 4), active(12, 8), active(20, 2), active(30, 1)];
    let caps = CmuxSidebarCaps { cap: 5, revealed: 0, floats: 1, include_working: 0, reserved: [0; 2] };
    let mut out = [0u32; 64];
    let mut tail = CmuxSidebarProjectTail::default();
    let code = unsafe {
        cmux_sidebar_project_rows(40, entries.as_ptr(), entries.len(), &caps, out.as_mut_ptr(), out.len(), &mut tail)
    };
    assert_eq!(code, OK);
    let rules = sidebar_caps::project_rows(
        40,
        &entries.iter().map(|e| Active { index: e.index, flags: e.flags }).collect::<Vec<_>>(),
        &ProjectCaps::default(),
    );
    assert_eq!(&out[..tail.rows as usize], rules.rows.as_slice());
    assert_eq!((tail.kind, tail.hidden, tail.next, tail.floated), (TAIL_SHOW_MORE, 31, 20, 2));
    assert_eq!(tail.revealed_after_press, 20);

    let expanded = CmuxSidebarCaps { revealed: 100, ..caps };
    let code = unsafe {
        cmux_sidebar_project_rows(40, entries.as_ptr(), entries.len(), &expanded, out.as_mut_ptr(), out.len(), &mut tail)
    };
    assert_eq!(code, OK);
    assert_eq!((tail.kind, tail.rows, tail.revealed_after_press), (TAIL_SHOW_LESS, 40, 0));
}

#[test]
fn a_short_buffer_says_what_it_needs_and_nulls_write_nothing() {
    let caps = CmuxSidebarCaps { cap: 5, ..CmuxSidebarCaps::default() };
    let mut out = [0u32; 2];
    let mut tail = CmuxSidebarProjectTail::default();
    let code = unsafe { cmux_sidebar_project_rows(30, ptr::null(), 0, &caps, out.as_mut_ptr(), out.len(), &mut tail) };
    assert_eq!(code, ERR_BUFFER);
    assert_eq!(tail.rows, 5);
    assert_eq!(unsafe { cmux_sidebar_project_rows(30, ptr::null(), 3, &caps, out.as_mut_ptr(), 2, &mut tail) }, ERR_NULL);
    assert_eq!(unsafe { cmux_sidebar_project_rows(30, ptr::null(), 0, ptr::null(), out.as_mut_ptr(), 2, &mut tail) }, ERR_NULL);
}

#[test]
fn needs_you_lists_yellow_then_blue() {
    let rows = [active(1, 4), active(3, 2), active(9, 4), active(11, 2), active(14, 4)];
    let (mut out, mut len, mut more) = ([0u32; 8], 0usize, 0u32);
    let code = unsafe { cmux_sidebar_needs_you(rows.as_ptr(), rows.len(), 0, 0, out.as_mut_ptr(), out.len(), &mut len, &mut more) };
    assert_eq!(code, OK);
    assert_eq!((&out[..len], more), (&[3, 11, 1][..], 2));
    assert_eq!(unsafe { cmux_sidebar_needs_you(rows.as_ptr(), rows.len(), 0, 0, out.as_mut_ptr(), 1, &mut len, &mut more) }, ERR_BUFFER);
    assert_eq!(len, 3);
}
