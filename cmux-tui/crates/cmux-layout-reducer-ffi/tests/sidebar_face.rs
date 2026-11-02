//! The sidebar row face through its C ABI, as the app calls it: typed
//! structs and one string buffer in, a reply the handle owns out.

use cmux_layout_reducer_ffi::sidebar_face::*;
use std::mem::size_of;

/// The request's string buffer.
#[derive(Default)]
struct Strings(Vec<u8>);

impl Strings {
    fn add(&mut self, text: &str) -> CRange {
        let offset = self.0.len() as u32;
        self.0.extend_from_slice(text.as_bytes());
        CRange { offset, len: text.len() as u32 }
    }
}

fn read(reply: &CReply, range: CRange) -> Option<String> {
    if range.offset == NONE {
        return None;
    }
    // SAFETY: the reply's strings hold `strings_len` bytes.
    let bytes = unsafe { std::slice::from_raw_parts(reply.strings, reply.strings_len as usize) };
    let start = range.offset as usize;
    Some(String::from_utf8(bytes[start..start + range.len as usize].to_vec()).unwrap())
}

fn tab(strings: &mut Strings, kind: u8, title: &str, cwd: Option<&str>, flags: u32) -> CTab {
    CTab {
        title: strings.add(title),
        list_title: strings.add(title),
        cwd: cwd.map_or(CRange::ABSENT, |cwd| strings.add(cwd)),
        flags,
        kind,
        agent: 0,
        progress_state: 0,
        reserved: 0,
        progress_value: NO_VALUE,
        reserved2: 0,
        notification: 0,
        attention_at_ms: 0,
        agent_updated_ms: 0,
        notification_created_ms: 0,
    }
}

fn pane(focused_at: u64, tab_count: u32) -> CPane {
    CPane { focused_at, default_tab: 0, tab_count, selected: NONE }
}

fn workspace(
    pane_start: u32,
    pane_count: u32,
    tab_start: u32,
    tab_count: u32,
    flags: u32,
) -> CWorkspace {
    CWorkspace {
        pane_start,
        pane_count,
        tab_start,
        tab_count,
        entry_start: 0,
        entry_count: 0,
        flags,
        reserved: 0,
        unread_count: 0,
        reported_progress: 0.0,
        status: CRange::ABSENT,
    }
}

fn request(
    workspaces: &[CWorkspace],
    panes: &[CPane],
    tabs: &[CTab],
    entries: &[CEntry],
    home: CRange,
) -> CRequest {
    CRequest {
        workspaces: workspaces.as_ptr(),
        panes: panes.as_ptr(),
        tabs: tabs.as_ptr(),
        entries: entries.as_ptr(),
        workspace_count: workspaces.len() as u32,
        pane_count: panes.len() as u32,
        tab_count: tabs.len() as u32,
        entry_count: entries.len() as u32,
        home,
        shows_unread: 1,
        new_tab_titled: 1,
        reserved: [0; 6],
    }
}

/// The layout the C header declares.
#[test]
fn sidebar_face_abi_the_structs_have_the_header_layout() {
    assert_eq!(size_of::<CRange>(), 8);
    assert_eq!(size_of::<CTab>(), 72);
    assert_eq!(size_of::<CPane>(), 24);
    assert_eq!(size_of::<CEntry>(), 16);
    assert_eq!(size_of::<CWorkspace>(), 56);
    assert_eq!(size_of::<CRequest>(), 64);
    assert_eq!(size_of::<CFace>(), 112);
    assert_eq!(size_of::<CListedTab>(), 32);
    assert_eq!(size_of::<CReply>(), 56);
    assert_eq!(size_of::<CText>(), 24);
}

/// Two rows in one call: an idle shell at home beside a chat (the chat names
/// the row), and a Cloud shell untitled at its home (its tab lists as `~`).
#[test]
fn sidebar_face_abi_one_call_maps_every_changed_row() {
    let mut strings = Strings::default();
    let home = strings.add("/Users/me");
    let mut tabs = vec![
        tab(&mut strings, 0, "zsh", Some("/Users/me"), 0),
        tab(&mut strings, 3, "about:blank", None, TAB_CHAT | TAB_BRANDED),
        tab(&mut strings, 0, "/home/cmux", Some("/home/cmux"), 0),
    ];
    tabs[1].attention_at_ms = 9;
    tabs[1].flags |= TAB_ATTENTION;
    let panes = [pane(2, 1), pane(1, 1), pane(1, 1)];
    let entries = [
        CEntry { key: strings.add("ports"), text: strings.add("3000") },
        CEntry { key: strings.add("build"), text: strings.add("ok") },
    ];
    let mut chat_row = workspace(0, 2, 0, 2, WORKSPACE_LOCAL);
    chat_row.entry_count = 2;
    let cloud_row = workspace(2, 1, 2, 1, 0);
    let workspaces = [chat_row, cloud_row];
    let request = request(&workspaces, &panes, &tabs, &entries, home);
    let faces = cmux_sidebar_face_new();
    // SAFETY: a live handle and a request whose arrays hold their counts.
    let reply =
        unsafe { &*cmux_sidebar_face_rows(faces, &request, strings.0.as_ptr(), strings.0.len()) };
    assert_eq!(reply.ok, 1);
    assert_eq!(reply.face_count, 2);
    // SAFETY: the reply's arrays hold their counts.
    let (rows, listed, kept) = unsafe {
        (
            std::slice::from_raw_parts(reply.faces, 2),
            std::slice::from_raw_parts(reply.listed, reply.listed_count as usize),
            std::slice::from_raw_parts(reply.kept_entries, reply.kept_entry_count as usize),
        )
    };
    let chat = rows[0];
    assert_eq!((chat.front, chat.label, chat.face, chat.agent), (0, 1, 1, 1));
    assert_eq!(chat.work, 0, "the shell is the newest work");
    assert_eq!(chat.kind, 2, "harness");
    assert_eq!(chat.row_kind, 3, "mixed");
    assert_eq!(read(reply, chat.directory), None, "the idle shell's ~ does not label the row");
    assert_eq!(read(reply, chat.bucket).as_deref(), Some("~"));
    assert_eq!(read(reply, chat.status_line).as_deref(), Some("ok"));
    assert_eq!(chat.ports, 0);
    assert_eq!(chat.pull_request, NONE);
    assert_eq!(&kept[chat.kept_entry_start as usize..][..chat.kept_entry_count as usize], &[1]);
    assert_eq!((chat.unread, chat.notice, chat.notice_tab), (1, 1, 1));
    assert_eq!(chat.listed_start, 0);
    assert_eq!(listed[1].kind, 2, "agent chat");
    let cloud = rows[1];
    assert_eq!(cloud.listed_start, 2);
    assert_eq!(listed[2].flags & LISTED_TITLE_CHANGED, LISTED_TITLE_CHANGED);
    assert_eq!(read(reply, listed[2].title).as_deref(), Some("~"));
    assert_eq!(read(reply, listed[2].folder).as_deref(), Some("~"));
    assert_eq!(listed[0].flags & LISTED_TITLE_CHANGED, 0, "an unchanged title is not copied");
    assert!(cloud.progress_value.is_nan());
    // SAFETY: freed once.
    unsafe { cmux_sidebar_face_free(faces) };
}

#[test]
fn sidebar_face_abi_a_request_that_does_not_decode_answers_no_faces() {
    let mut strings = Strings::default();
    let home = strings.add("/Users/me");
    let tabs = [tab(&mut strings, 0, "zsh", None, 0)];
    let panes = [pane(1, 2)];
    let workspaces = [workspace(0, 1, 0, 1, WORKSPACE_LOCAL)];
    let faces = cmux_sidebar_face_new();
    for (panes, kind) in [(&panes[..], 0u8), (&[pane(1, 1)][..], 9)] {
        let mut tabs = tabs;
        tabs[0].kind = kind;
        let request = request(&workspaces, panes, &tabs, &[], home);
        // SAFETY: a live handle and a request whose arrays hold their counts.
        let reply = unsafe {
            &*cmux_sidebar_face_rows(faces, &request, strings.0.as_ptr(), strings.0.len())
        };
        assert_eq!(
            (reply.ok, reply.face_count),
            (0, 0),
            "pane tab counts that miss the tabs, or kind {kind}"
        );
    }
    let one = [pane(1, 1)];
    let mut bad = request(&workspaces, &one, &tabs, &[], CRange { offset: 1000, len: 1 });
    // SAFETY: as above.
    let reply =
        unsafe { &*cmux_sidebar_face_rows(faces, &bad, strings.0.as_ptr(), strings.0.len()) };
    assert_eq!(reply.ok, 0, "a range out of bounds");
    bad.workspaces = std::ptr::null();
    // SAFETY: as above; a null array with a count does not decode.
    let reply =
        unsafe { &*cmux_sidebar_face_rows(faces, &bad, strings.0.as_ptr(), strings.0.len()) };
    assert_eq!(reply.ok, 0);
    // SAFETY: null handles answer null.
    assert!(
        unsafe { cmux_sidebar_face_rows(std::ptr::null_mut(), &bad, std::ptr::null(), 0) }
            .is_null()
    );
    // SAFETY: freed once.
    unsafe { cmux_sidebar_face_free(faces) };
}

#[test]
fn sidebar_face_abi_the_default_name_counts_listed_and_reserved_names() {
    let mut strings = Strings::default();
    let names = [strings.add("workspace-1"), strings.add("shell"), strings.add("workspace-3")];
    let faces = cmux_sidebar_face_new();
    // SAFETY: a live handle and `names` holds its count.
    let text = unsafe {
        &*cmux_sidebar_face_default_name(
            faces,
            names.as_ptr(),
            3,
            2,
            strings.0.as_ptr(),
            strings.0.len(),
        )
    };
    assert_eq!(text.ok, 1);
    // SAFETY: the reply holds `len` bytes.
    let name = unsafe { std::slice::from_raw_parts(text.bytes, text.len as usize) };
    assert_eq!(name, b"workspace-4");
    // SAFETY: as above; more listed names than names does not decode.
    let text = unsafe {
        &*cmux_sidebar_face_default_name(
            faces,
            names.as_ptr(),
            3,
            4,
            strings.0.as_ptr(),
            strings.0.len(),
        )
    };
    assert_eq!(text.ok, 0);
    // SAFETY: freed once.
    unsafe { cmux_sidebar_face_free(faces) };
}
