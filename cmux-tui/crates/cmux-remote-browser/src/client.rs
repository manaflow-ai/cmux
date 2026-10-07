//! The viewer's reducer for one remote tab (`cmux.rb/1`, remote-tab r2
//! client). It turns host control messages and the person's local answers
//! into effects for the pane (native menus, sheets, cursor, page state) and
//! messages for the host. The viewer answers only the menu or dialog that is
//! open, never acts on viewer-to-host messages, and closes open UI when the
//! session crashes or closes. Vectors: `schemas/remote-tab/client.json`.

use crate::proto::{Control, CursorShape, Dialog, Menu, MenuChoice, Rect, ScreenInfo, SessionState};
use serde::{Deserialize, Serialize};

/// One input to the client reducer.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(tag = "op", rename_all = "snake_case")]
pub enum ClientInput {
    /// A control message from the host.
    Host { message: Control },
    /// The person picked from the native menu (or dismissed it: `cancel`).
    MenuChosen { token: u64, choice: MenuChoice },
    /// The person answered the dialog sheet.
    DialogAnswered { token: u64, accept: bool, text: Option<String> },
    /// The pane's page size or scale changed.
    Resize { screen: ScreenInfo },
}

/// What the viewer does after one input, in order.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(tag = "effect", rename_all = "snake_case")]
pub enum ClientEffect {
    /// Send this control message to the host.
    Send { message: Control },
    ShowMenu { token: u64, menu: Menu },
    CloseMenu { token: u64 },
    ShowDialog { token: u64, dialog: Dialog },
    CloseDialog { token: u64 },
    SetCursor { cursor: CursorShape },
    /// Page state for the local chrome (omnibar, back and forward).
    Page { url: String, title: String, loading: bool, can_go_back: bool, can_go_forward: bool },
    /// IME and caret geometry for the input view (surface CSS pixels).
    TextInput { input_type: String, composition_rects: Vec<Rect>, caret: Option<Rect> },
    /// The host applied the newest screen: frames now have this pixel size.
    ScreenApplied { pixel_width: u32, pixel_height: u32, scale: f64 },
    Session { state: SessionState },
}

/// Inputs that change nothing, and why.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ClientNote {
    /// An answer for a menu or dialog that is no longer open.
    StaleAnswer,
    /// The host cancelled a menu that is no longer open.
    StaleCancel,
    /// A menu or dialog token that does not increase.
    StaleShow,
    /// `rb.screen_applied` for an older `rb.screen`.
    StaleScreen,
    /// A host message a later step handles.
    Unhandled,
}

/// Inputs refused as protocol errors (the state does not change).
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ClientReject {
    /// A viewer-to-host message arrived from the host.
    WrongDirection,
    /// `rb.screen_applied` for a seq this viewer never sent.
    UnknownScreenSeq,
}

#[derive(Debug, Clone, PartialEq, Default)]
pub struct ClientOutcome {
    pub effects: Vec<ClientEffect>,
    pub note: Option<ClientNote>,
}

/// Viewer state of one remote tab.
#[derive(Debug, Clone, PartialEq, Default)]
pub struct Client {
    pub open_menu: Option<u64>,
    pub open_dialog: Option<u64>,
    /// The seq of the last `rb.screen` sent.
    pub screen_seq: u32,
    last_menu: u64,
    last_dialog: u64,
}

impl Client {
    pub fn apply(&mut self, _input: ClientInput) -> Result<ClientOutcome, ClientReject> {
        Ok(ClientOutcome::default())
    }
}
