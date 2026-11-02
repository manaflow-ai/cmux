//! The sidebar row face (`cmux_layout_reducer::sidebar_face`) over a typed
//! C ABI: fixed-size request structs with byte ranges into one UTF-8
//! buffer, a reply the handle owns, no JSON. One call maps every row the
//! app's row feed marked changed in a frame, so it costs O(changed rows)
//! and never O(session).

use cmux_layout_reducer::sidebar_face::{
    self as rules, AgentState, Context, Entry, Kind, ListedKind, Notice, Pane, ProgressState,
    RowKind, Tab, TabKind, TerminalProgress, Unread, Workspace,
};
use std::panic::{AssertUnwindSafe, catch_unwind};

/// No index or no string.
pub const NONE: u32 = u32::MAX;
/// No progress value (`CTab::progress_value`).
pub const NO_VALUE: i32 = i32::MIN;

pub const TAB_NAMED: u32 = 1;
pub const TAB_CHAT: u32 = 2;
pub const TAB_COMMAND_RUNNING: u32 = 4;
pub const TAB_TITLE_ACTIVITY: u32 = 8;
pub const TAB_PAGE: u32 = 16;
pub const TAB_APP: u32 = 32;
pub const TAB_NEW_TAB_PAGE: u32 = 64;
pub const TAB_BRANDED: u32 = 128;
pub const TAB_HAS_UNREAD: u32 = 256;
pub const TAB_MARKED_UNREAD: u32 = 512;
pub const TAB_ATTENTION: u32 = 1024;

pub const WORKSPACE_LOCAL: u32 = 1;
pub const WORKSPACE_MARKED_UNREAD: u32 = 2;
pub const WORKSPACE_REPORTED_PROGRESS: u32 = 4;

pub const LISTED_TITLE_CHANGED: u8 = 1;
pub const LISTED_BLANK: u8 = 2;

/// A byte range of a buffer; `offset` [`NONE`] is absent.
#[repr(C)]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct CRange {
    pub offset: u32,
    pub len: u32,
}

impl CRange {
    pub const ABSENT: Self = Self { offset: NONE, len: 0 };
}

#[repr(C)]
#[derive(Debug, Clone, Copy)]
pub struct CTab {
    pub title: CRange,
    pub list_title: CRange,
    pub cwd: CRange,
    pub flags: u32,
    /// 0 pty 1 browser 2 remote terminal 3 conversation 4 other.
    pub kind: u8,
    /// 0 none 1 working 2 blocked 3 other.
    pub agent: u8,
    /// 0 none 1 normal 2 error 3 indeterminate 4 paused.
    pub progress_state: u8,
    pub reserved: u8,
    /// 0...100; [`NO_VALUE`] for no value.
    pub progress_value: i32,
    pub reserved2: u32,
    pub notification: u64,
    /// Read only with [`TAB_ATTENTION`].
    pub attention_at_ms: u64,
    pub agent_updated_ms: u64,
    pub notification_created_ms: u64,
}

#[repr(C)]
#[derive(Debug, Clone, Copy)]
pub struct CPane {
    pub focused_at: u64,
    pub default_tab: i64,
    pub tab_count: u32,
    /// The window's selected tab among the pane's tabs; [`NONE`] for the
    /// daemon's default tab.
    pub selected: u32,
}

#[repr(C)]
#[derive(Debug, Clone, Copy)]
pub struct CEntry {
    pub key: CRange,
    pub text: CRange,
}

#[repr(C)]
#[derive(Debug, Clone, Copy)]
pub struct CWorkspace {
    /// The workspace's panes, tabs and entries are runs of the request's.
    pub pane_start: u32,
    pub pane_count: u32,
    pub tab_start: u32,
    pub tab_count: u32,
    pub entry_start: u32,
    pub entry_count: u32,
    pub flags: u32,
    pub reserved: u32,
    pub unread_count: u64,
    /// 0...1, NaN while indeterminate; read only with
    /// [`WORKSPACE_REPORTED_PROGRESS`].
    pub reported_progress: f64,
    /// The hooks' status line.
    pub status: CRange,
}

#[repr(C)]
#[derive(Debug, Clone, Copy)]
pub struct CRequest {
    pub workspaces: *const CWorkspace,
    pub panes: *const CPane,
    pub tabs: *const CTab,
    pub entries: *const CEntry,
    pub workspace_count: u32,
    pub pane_count: u32,
    pub tab_count: u32,
    pub entry_count: u32,
    pub home: CRange,
    pub shows_unread: u8,
    pub new_tab_titled: u8,
    pub reserved: [u8; 6],
}

/// One row's face. Tab fields index the workspace's own tabs; entry fields
/// its own entries. Strings index the reply's bytes.
#[repr(C)]
#[derive(Debug, Clone, Copy)]
pub struct CFace {
    pub front: u32,
    pub label: u32,
    pub face: u32,
    pub chat: u32,
    pub folder_tab: u32,
    pub bucket_tab: u32,
    pub agent: u32,
    pub notice_tab: u32,
    /// 0 terminal 1 browser 2 harness.
    pub kind: u8,
    /// 0 terminal 1 browser 2 agent 3 mixed.
    pub row_kind: u8,
    /// 0 none 1 dot 2 count (the request's unread count).
    pub unread: u8,
    /// 0 none 1 attention (notice_tab's reason) 2 notification (notice_tab's text).
    pub notice: u8,
    /// 0 none 1 a bar.
    pub progress: u8,
    pub progress_error: u8,
    pub reserved: [u8; 2],
    /// The first of this workspace's listed tabs in the reply (one per tab).
    pub listed_start: u32,
    /// This workspace's status block entries in the reply's `kept_entries`.
    pub kept_entry_start: u32,
    pub kept_entry_count: u32,
    pub ports: u32,
    pub pull_request: u32,
    /// The work tab (`workTab`).
    pub work: u32,
    pub directory: CRange,
    pub bucket: CRange,
    pub process: CRange,
    pub status_line: CRange,
    pub last_activity_ms: u64,
    /// 0...1, NaN while indeterminate.
    pub progress_value: f64,
}

#[repr(C)]
#[derive(Debug, Clone, Copy)]
pub struct CListedTab {
    /// Read only with [`LISTED_TITLE_CHANGED`]; else the tab's own list title.
    pub title: CRange,
    pub folder: CRange,
    pub last_activity_ms: u64,
    /// 0 the record's kind 1 new tab 2 agent chat.
    pub kind: u8,
    pub flags: u8,
    pub reserved: [u8; 6],
}

#[repr(C)]
pub struct CReply {
    pub ok: u8,
    pub reserved: [u8; 7],
    pub faces: *const CFace,
    pub listed: *const CListedTab,
    pub kept_entries: *const u32,
    pub strings: *const u8,
    pub face_count: u32,
    pub listed_count: u32,
    pub kept_entry_count: u32,
    pub strings_len: u32,
}

/// One text reply: `bytes[..len]`, UTF-8.
#[repr(C)]
pub struct CText {
    pub ok: u8,
    pub reserved: [u8; 7],
    pub bytes: *const u8,
    pub len: u32,
    pub reserved2: u32,
}

/// A face handle: it owns the buffers of its last reply.
#[derive(Default)]
pub struct Faces {
    faces: Vec<CFace>,
    listed: Vec<CListedTab>,
    kept: Vec<u32>,
    strings: Vec<u8>,
    reply: Option<CReply>,
    text: Option<CText>,
    name: String,
}

/// A request that does not decode: a range out of bounds, bytes that are
/// not UTF-8, or an unknown code.
struct Invalid;

fn text(strings: &[u8], range: CRange) -> Result<Option<&str>, Invalid> {
    if range.offset == NONE {
        return Ok(None);
    }
    let start = range.offset as usize;
    let bytes = strings.get(start..start + range.len as usize).ok_or(Invalid)?;
    std::str::from_utf8(bytes).map(Some).map_err(|_| Invalid)
}

fn required(strings: &[u8], range: CRange) -> Result<&str, Invalid> {
    Ok(text(strings, range)?.unwrap_or(""))
}

fn run<T>(items: &[T], start: u32, count: u32) -> Result<&[T], Invalid> {
    let start = start as usize;
    items.get(start..start + count as usize).ok_or(Invalid)
}

/// # Safety
///
/// `pointer` is null with `count` 0, or points to `count` readable items.
unsafe fn slice<'a, T>(pointer: *const T, count: u32) -> Result<&'a [T], Invalid> {
    if count == 0 {
        return Ok(&[]);
    }
    if pointer.is_null() {
        return Err(Invalid);
    }
    // SAFETY: guaranteed by the C caller.
    Ok(unsafe { std::slice::from_raw_parts(pointer, count as usize) })
}

fn tab<'a>(strings: &'a [u8], tab: &CTab) -> Result<Tab<'a>, Invalid> {
    let flag = |bit: u32| tab.flags & bit != 0;
    let kind = match tab.kind {
        0 => TabKind::Pty,
        1 => TabKind::Browser,
        2 => TabKind::RemoteTerminal,
        3 => TabKind::Conversation,
        4 => TabKind::Other,
        _ => return Err(Invalid),
    };
    let agent = match tab.agent {
        0 => None,
        1 => Some(AgentState::Working),
        2 => Some(AgentState::Blocked),
        3 => Some(AgentState::Other),
        _ => return Err(Invalid),
    };
    let state = match tab.progress_state {
        0 => None,
        1 => Some(ProgressState::Normal),
        2 => Some(ProgressState::Error),
        3 => Some(ProgressState::Indeterminate),
        4 => Some(ProgressState::Paused),
        _ => return Err(Invalid),
    };
    let value = (tab.progress_value != NO_VALUE).then_some(i64::from(tab.progress_value));
    Ok(Tab {
        kind,
        title: required(strings, tab.title)?,
        list_title: required(strings, tab.list_title)?,
        cwd: text(strings, tab.cwd)?,
        named: flag(TAB_NAMED),
        chat: flag(TAB_CHAT),
        agent,
        command_running: flag(TAB_COMMAND_RUNNING),
        title_activity: flag(TAB_TITLE_ACTIVITY),
        page: flag(TAB_PAGE),
        app_tab: flag(TAB_APP),
        new_tab_page: flag(TAB_NEW_TAB_PAGE),
        branded: flag(TAB_BRANDED),
        has_unread: flag(TAB_HAS_UNREAD),
        notification: tab.notification,
        marked_unread: flag(TAB_MARKED_UNREAD),
        attention_at_ms: flag(TAB_ATTENTION).then_some(tab.attention_at_ms),
        agent_updated_ms: tab.agent_updated_ms,
        notification_created_ms: tab.notification_created_ms,
        progress: state.map(|state| TerminalProgress { state, value }),
    })
}

fn index(value: Option<usize>) -> u32 {
    value.and_then(|value| u32::try_from(value).ok()).unwrap_or(NONE)
}

impl Faces {
    fn push(&mut self, value: Option<&str>) -> CRange {
        let Some(value) = value else { return CRange::ABSENT };
        let offset = u32::try_from(self.strings.len()).unwrap_or(NONE);
        self.strings.extend_from_slice(value.as_bytes());
        CRange { offset, len: u32::try_from(value.len()).unwrap_or(0) }
    }

    fn workspace<'a>(
        strings: &'a [u8],
        request: &Request<'_>,
        workspace: &CWorkspace,
    ) -> Result<Workspace<'a>, Invalid> {
        let panes = run(request.panes, workspace.pane_start, workspace.pane_count)?;
        let tabs = run(request.tabs, workspace.tab_start, workspace.tab_count)?;
        let entries = run(request.entries, workspace.entry_start, workspace.entry_count)?;
        if panes.iter().map(|pane| pane.tab_count as usize).sum::<usize>() != tabs.len() {
            return Err(Invalid);
        }
        let flag = |bit: u32| workspace.flags & bit != 0;
        Ok(Workspace {
            panes: panes
                .iter()
                .map(|pane| Pane {
                    focused_at: pane.focused_at,
                    tabs: pane.tab_count as usize,
                    default_tab: pane.default_tab,
                    selected: (pane.selected != NONE).then_some(pane.selected as usize),
                })
                .collect(),
            tabs: tabs.iter().map(|value| tab(strings, value)).collect::<Result<_, _>>()?,
            local: flag(WORKSPACE_LOCAL),
            unread_count: workspace.unread_count,
            marked_unread: flag(WORKSPACE_MARKED_UNREAD),
            status: text(strings, workspace.status)?,
            entries: entries
                .iter()
                .map(|entry| {
                    Ok(Entry {
                        key: required(strings, entry.key)?,
                        text: required(strings, entry.text)?,
                    })
                })
                .collect::<Result<_, _>>()?,
            reported_progress: flag(WORKSPACE_REPORTED_PROGRESS).then_some(
                (!workspace.reported_progress.is_nan()).then_some(workspace.reported_progress),
            ),
        })
    }

    fn fill(&mut self, request: &Request<'_>, strings: &[u8]) -> Result<(), Invalid> {
        let context = Context {
            home: required(strings, request.home)?,
            shows_unread: request.shows_unread != 0,
            new_tab_titled: request.new_tab_titled != 0,
        };
        for workspace in request.workspaces {
            let model = Self::workspace(strings, request, workspace)?;
            let face = rules::face(&model, &context);
            let listed_start = u32::try_from(self.listed.len()).unwrap_or(NONE);
            for (listed, tab) in face.tabs.iter().zip(&model.tabs) {
                let changed = listed.title != tab.list_title;
                let title =
                    if changed { self.push(Some(listed.title.as_ref())) } else { CRange::ABSENT };
                let folder = self.push(listed.folder.as_deref());
                self.listed.push(CListedTab {
                    title,
                    folder,
                    last_activity_ms: listed.last_activity_ms,
                    kind: match listed.kind {
                        ListedKind::Record => 0,
                        ListedKind::NewTab => 1,
                        ListedKind::AgentChat => 2,
                    },
                    flags: (if changed { LISTED_TITLE_CHANGED } else { 0 })
                        | (if listed.blank { LISTED_BLANK } else { 0 }),
                    reserved: [0; 6],
                });
            }
            let kept_entry_start = u32::try_from(self.kept.len()).unwrap_or(NONE);
            self.kept.extend(face.status_entries.iter().map(|entry| index(Some(*entry))));
            let (notice, notice_tab) = match face.notice {
                None => (0, None),
                Some(Notice::Attention(tab)) => (1, Some(tab)),
                Some(Notice::Notification(tab)) => (2, Some(tab)),
            };
            let directory = self.push(face.directory.as_deref());
            let bucket = self.push(face.bucket.as_deref());
            let process = self.push(face.process);
            let status_line = self.push(face.status_line.as_deref());
            self.faces.push(CFace {
                front: index(face.front),
                label: index(face.label),
                face: index(face.face),
                chat: index(face.chat),
                folder_tab: index(face.folder_tab),
                bucket_tab: index(face.bucket_tab),
                agent: index(face.agent),
                notice_tab: index(notice_tab),
                kind: match face.kind {
                    Kind::Terminal => 0,
                    Kind::Browser => 1,
                    Kind::Harness => 2,
                },
                row_kind: match face.row_kind {
                    RowKind::Terminal => 0,
                    RowKind::Browser => 1,
                    RowKind::Agent => 2,
                    RowKind::Mixed => 3,
                },
                unread: match face.unread {
                    Unread::None => 0,
                    Unread::Dot => 1,
                    Unread::Count(_) => 2,
                },
                notice,
                progress: u8::from(face.progress.is_some()),
                progress_error: u8::from(face.progress.is_some_and(|bar| bar.is_error)),
                reserved: [0; 2],
                listed_start,
                kept_entry_start,
                kept_entry_count: u32::try_from(face.status_entries.len()).unwrap_or(0),
                ports: index(face.ports),
                pull_request: index(face.pull_request),
                work: index(face.work),
                directory,
                bucket,
                process,
                status_line,
                last_activity_ms: face.last_activity_ms,
                progress_value: face.progress.and_then(|bar| bar.value).unwrap_or(f64::NAN),
            });
        }
        Ok(())
    }

    /// The faces of `request`'s workspaces. The reply stays valid until the
    /// next call on this handle.
    pub fn rows(&mut self, request: &Request<'_>, strings: &[u8]) -> *const CReply {
        self.faces.clear();
        self.listed.clear();
        self.kept.clear();
        self.strings.clear();
        let ok =
            catch_unwind(AssertUnwindSafe(|| self.fill(request, strings).is_ok())).unwrap_or(false);
        self.finish(ok)
    }

    /// A reply that answers no faces (`ok` 0): the request did not decode.
    fn fail(&mut self) -> *const CReply {
        self.finish(false)
    }

    /// The reply over the current buffers; with `ok` false the buffers are
    /// emptied first.
    fn finish(&mut self, ok: bool) -> *const CReply {
        if !ok {
            self.faces.clear();
            self.listed.clear();
            self.kept.clear();
            self.strings.clear();
        }
        self.reply.insert(CReply {
            ok: u8::from(ok),
            reserved: [0; 7],
            faces: self.faces.as_ptr(),
            listed: self.listed.as_ptr(),
            kept_entries: self.kept.as_ptr(),
            strings: self.strings.as_ptr(),
            face_count: u32::try_from(self.faces.len()).unwrap_or(0),
            listed_count: u32::try_from(self.listed.len()).unwrap_or(0),
            kept_entry_count: u32::try_from(self.kept.len()).unwrap_or(0),
            strings_len: u32::try_from(self.strings.len()).unwrap_or(0),
        })
    }

    /// The daemon's next default workspace name; `names` are the listed
    /// names, then the reserved ones.
    pub fn default_name(
        &mut self,
        names: &[CRange],
        existing: usize,
        strings: &[u8],
    ) -> *const CText {
        let decoded: Result<Vec<&str>, Invalid> = if existing > names.len() {
            Err(Invalid)
        } else {
            names.iter().map(|name| required(strings, *name)).collect()
        };
        let ok = match decoded {
            Ok(names) => {
                let (listed, reserved) = names.split_at(existing);
                self.name = rules::default_workspace_name(listed, reserved);
                true
            }
            Err(Invalid) => {
                self.name.clear();
                false
            }
        };
        self.text.insert(CText {
            ok: u8::from(ok),
            reserved: [0; 7],
            bytes: self.name.as_ptr(),
            len: u32::try_from(self.name.len()).unwrap_or(0),
            reserved2: 0,
        })
    }
}

/// A request's arrays as slices.
pub struct Request<'a> {
    pub workspaces: &'a [CWorkspace],
    pub panes: &'a [CPane],
    pub tabs: &'a [CTab],
    pub entries: &'a [CEntry],
    pub home: CRange,
    pub shows_unread: u8,
    pub new_tab_titled: u8,
}

/// A new face handle. Free it with `cmux_sidebar_face_free`.
#[unsafe(no_mangle)]
pub extern "C" fn cmux_sidebar_face_new() -> *mut Faces {
    Box::into_raw(Box::default())
}

/// # Safety
///
/// `faces` is null or a pointer from `cmux_sidebar_face_new` not freed yet.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_sidebar_face_free(faces: *mut Faces) {
    if !faces.is_null() {
        // SAFETY: the pointer came from Box::into_raw and is freed once.
        drop(unsafe { Box::from_raw(faces) });
    }
}

/// # Safety
///
/// `pointer` is null with `len` 0, or points to `len` readable bytes.
unsafe fn bytes<'a>(pointer: *const u8, len: usize) -> Option<&'a [u8]> {
    if len == 0 {
        return Some(&[]);
    }
    if pointer.is_null() {
        return None;
    }
    // SAFETY: guaranteed by the C caller.
    Some(unsafe { std::slice::from_raw_parts(pointer, len) })
}

/// The request's arrays and the string buffer as slices.
///
/// # Safety
///
/// The request's arrays hold their counts; `strings` points to
/// `strings_len` readable bytes (or is null with length 0).
unsafe fn decode<'a>(
    request: &'a CRequest,
    strings: *const u8,
    strings_len: usize,
) -> Result<(Request<'a>, &'a [u8]), Invalid> {
    // SAFETY: the caller's arrays hold their counts.
    let request = unsafe {
        Request {
            workspaces: slice(request.workspaces, request.workspace_count)?,
            panes: slice(request.panes, request.pane_count)?,
            tabs: slice(request.tabs, request.tab_count)?,
            entries: slice(request.entries, request.entry_count)?,
            home: request.home,
            shows_unread: request.shows_unread,
            new_tab_titled: request.new_tab_titled,
        }
    };
    // SAFETY: the caller's buffer holds `strings_len` bytes.
    let strings = unsafe { bytes(strings, strings_len) }.ok_or(Invalid)?;
    Ok((request, strings))
}

/// The faces of the request's workspaces, one per workspace in order. Null
/// for a null handle or request; `ok` 0 (no faces) for a request that does
/// not decode.
///
/// # Safety
///
/// `faces` is a live handle used by one thread; `request` points to a
/// readable request whose arrays hold their counts; `strings` points to
/// `strings_len` readable bytes (or is null with length 0). The reply
/// belongs to the handle: read it before the next call on it; never free it.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_sidebar_face_rows(
    faces: *mut Faces,
    request: *const CRequest,
    strings: *const u8,
    strings_len: usize,
) -> *const CReply {
    if faces.is_null() || request.is_null() {
        return std::ptr::null();
    }
    // SAFETY: a live handle, used by one thread; a readable request.
    let (faces, request) = unsafe { (&mut *faces, &*request) };
    // SAFETY: as this function's contract says.
    let decoded = unsafe { decode(request, strings, strings_len) };
    match decoded {
        Ok((request, strings)) => faces.rows(&request, strings),
        Err(Invalid) => faces.fail(),
    }
}

/// The daemon's next default workspace name (`workspace-N`). `names` holds
/// `existing_count` listed names, then the reserved ones (`count` in all).
///
/// # Safety
///
/// `faces` is a live handle used by one thread; `names` points to `count`
/// readable ranges (or is null with count 0); `strings` points to
/// `strings_len` readable bytes (or is null with length 0). The reply
/// belongs to the handle: read it before the next call on it.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn cmux_sidebar_face_default_name(
    faces: *mut Faces,
    names: *const CRange,
    count: u32,
    existing_count: u32,
    strings: *const u8,
    strings_len: usize,
) -> *const CText {
    if faces.is_null() {
        return std::ptr::null();
    }
    // SAFETY: a live handle, used by one thread.
    let faces = unsafe { &mut *faces };
    // SAFETY: the caller's arrays hold their counts.
    let names = unsafe { slice(names, count) };
    // SAFETY: the caller's buffer holds `strings_len` bytes.
    let strings = unsafe { bytes(strings, strings_len) };
    match (names, strings) {
        (Ok(names), Some(strings)) => faces.default_name(names, existing_count as usize, strings),
        _ => faces.default_name(&[], 1, &[]),
    }
}
