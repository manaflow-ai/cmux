//! Page facts the viewer shows outside the frames (`rb.page`, `rb.cursor`)
//! and the CEF enum values the shim reports for them. Pure.

use cmux_remote_browser::proto::{Control, CursorShape, Disposition};

/// A page fact the shim reported (`rb.page` carries all of them).
#[derive(Debug, Clone, PartialEq)]
pub enum PageChange {
    Url(String),
    Title(String),
    Loading { loading: bool, can_go_back: bool, can_go_forward: bool },
}

/// The facts of `rb.page`, as last sent.
#[derive(Debug, Clone, Default, PartialEq)]
pub struct PageState {
    url: String,
    title: String,
    loading: bool,
    can_go_back: bool,
    can_go_forward: bool,
    /// The shim reported at least one fact.
    known: bool,
}

impl PageState {
    /// Applies one fact: `rb.page` when it changed anything.
    pub fn apply(&mut self, change: PageChange) -> Option<Control> {
        let before = self.clone();
        match change {
            PageChange::Url(url) => self.url = url,
            PageChange::Title(title) => self.title = title,
            PageChange::Loading { loading, can_go_back, can_go_forward } => {
                self.loading = loading;
                self.can_go_back = can_go_back;
                self.can_go_forward = can_go_forward;
            }
        }
        self.known = true;
        (*self != before).then(|| self.message())
    }

    /// `rb.page` for a viewer that opens now (`None` before any fact).
    pub fn snapshot(&self) -> Option<Control> {
        self.known.then(|| self.message())
    }

    fn message(&self) -> Control {
        Control::Page {
            url: self.url.clone(),
            title: self.title.clone(),
            loading: self.loading,
            can_go_back: self.can_go_back,
            can_go_forward: self.can_go_forward,
        }
    }
}

/// CSS cursor names in `cef_cursor_type_t` order (CT_POINTER = 0 through
/// CT_DND_LINK; include/internal/cef_types.h). CT_CUSTOM has no image yet
/// (`rb.cursor_image`), so it shows the default arrow.
const CSS_CURSORS: [&str; 52] = [
    "default",       // CT_POINTER
    "crosshair",     // CT_CROSS
    "pointer",       // CT_HAND
    "text",          // CT_IBEAM
    "wait",          // CT_WAIT
    "help",          // CT_HELP
    "e-resize",      // CT_EASTRESIZE
    "n-resize",      // CT_NORTHRESIZE
    "ne-resize",     // CT_NORTHEASTRESIZE
    "nw-resize",     // CT_NORTHWESTRESIZE
    "s-resize",      // CT_SOUTHRESIZE
    "se-resize",     // CT_SOUTHEASTRESIZE
    "sw-resize",     // CT_SOUTHWESTRESIZE
    "w-resize",      // CT_WESTRESIZE
    "ns-resize",     // CT_NORTHSOUTHRESIZE
    "ew-resize",     // CT_EASTWESTRESIZE
    "nesw-resize",   // CT_NORTHEASTSOUTHWESTRESIZE
    "nwse-resize",   // CT_NORTHWESTSOUTHEASTRESIZE
    "col-resize",    // CT_COLUMNRESIZE
    "row-resize",    // CT_ROWRESIZE
    "all-scroll",    // CT_MIDDLEPANNING
    "e-resize",      // CT_EASTPANNING
    "n-resize",      // CT_NORTHPANNING
    "ne-resize",     // CT_NORTHEASTPANNING
    "nw-resize",     // CT_NORTHWESTPANNING
    "s-resize",      // CT_SOUTHPANNING
    "se-resize",     // CT_SOUTHEASTPANNING
    "sw-resize",     // CT_SOUTHWESTPANNING
    "w-resize",      // CT_WESTPANNING
    "move",          // CT_MOVE
    "vertical-text", // CT_VERTICALTEXT
    "cell",          // CT_CELL
    "context-menu",  // CT_CONTEXTMENU
    "alias",         // CT_ALIAS
    "progress",      // CT_PROGRESS
    "no-drop",       // CT_NODROP
    "copy",          // CT_COPY
    "none",          // CT_NONE
    "not-allowed",   // CT_NOTALLOWED
    "zoom-in",       // CT_ZOOMIN
    "zoom-out",      // CT_ZOOMOUT
    "grab",          // CT_GRAB
    "grabbing",      // CT_GRABBING
    "ns-resize",     // CT_MIDDLE_PANNING_VERTICAL
    "ew-resize",     // CT_MIDDLE_PANNING_HORIZONTAL
    "default",       // CT_CUSTOM
    "no-drop",       // CT_DND_NONE
    "move",          // CT_DND_MOVE
    "copy",          // CT_DND_COPY
    "alias",         // CT_DND_LINK
    "default",       // (spare: CT_NUM_VALUES is not a cursor)
    "default",       // (spare)
];

/// The CSS name of a `cef_cursor_type_t` value; `None` for an unknown value.
pub fn css_cursor(cef_type: i32) -> Option<&'static str> {
    // The table has two spare entries past CT_DND_LINK (49).
    let index = usize::try_from(cef_type).ok().filter(|&i| i < 50)?;
    CSS_CURSORS.get(index).copied()
}

/// `rb.cursor` for a CSS cursor name.
pub fn cursor_message(kind: &str) -> Control {
    Control::Cursor { cursor: CursorShape { kind: kind.to_string(), hash: None } }
}

/// The `rb.open_tab` disposition of a `cef_window_open_disposition_t`
/// value; `None` for one that opens no tab (save to disk, ignore).
pub fn disposition(cef_disposition: i32) -> Option<Disposition> {
    match cef_disposition {
        // CEF_WOD_NEW_BACKGROUND_TAB
        4 => Some(Disposition::BackgroundTab),
        // CEF_WOD_NEW_POPUP
        5 => Some(Disposition::Popup),
        // CEF_WOD_NEW_WINDOW
        6 => Some(Disposition::NewWindow),
        // CEF_WOD_SAVE_TO_DISK, CEF_WOD_IGNORE_ACTION
        7 | 9 => None,
        // Unknown, current, singleton, foreground, off the record, switch to
        // tab, picture in picture, split view: a foreground tab in the App.
        _ => Some(Disposition::ForegroundTab),
    }
}
