//! The viewer's reducer for one remote tab (`cmux.rb/1`, remote-tab r2
//! client). It turns host control messages and the person's local answers
//! into effects for the pane (native menus, sheets, cursor, page state) and
//! messages for the host. The viewer answers only the menu or dialog that is
//! open, never acts on viewer-to-host messages, and closes open UI when the
//! session crashes or closes. Vectors: `schemas/remote-tab/client.json`.

use std::collections::BTreeSet;

use crate::menu::OpenMenu;
use crate::proto::{
    Control, CursorShape, Dialog, Disposition, Menu, MenuChoice, Rect, ScreenInfo, SessionState,
};
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
    /// The person typed an address in the local omnibar.
    Navigate { url: String },
    /// The App answered `open_tab` (the new tab's id, or why it refused).
    TabOpened { request: u64, tab: Option<String>, refused: Option<String> },
}

/// What the viewer does after one input, in order.
#[derive(Debug, Clone, PartialEq, Serialize, Deserialize)]
#[serde(tag = "effect", rename_all = "snake_case")]
pub enum ClientEffect {
    /// Send this control message to the host.
    Send {
        message: Control,
    },
    ShowMenu {
        token: u64,
        menu: Menu,
    },
    CloseMenu {
        token: u64,
    },
    ShowDialog {
        token: u64,
        dialog: Dialog,
    },
    CloseDialog {
        token: u64,
    },
    SetCursor {
        cursor: CursorShape,
    },
    /// Page state for the local chrome (omnibar, back and forward).
    Page {
        url: String,
        title: String,
        loading: bool,
        can_go_back: bool,
        can_go_forward: bool,
    },
    /// IME and caret geometry for the input view (surface CSS pixels).
    TextInput {
        input_type: String,
        composition_rects: Vec<Rect>,
        caret: Option<Rect>,
    },
    /// The host applied the newest screen: frames now have this pixel size.
    ScreenApplied {
        pixel_width: u32,
        pixel_height: u32,
        scale: f64,
    },
    Session {
        state: SessionState,
    },
    /// The page did not handle key `input_seq`: the viewer runs what a
    /// local tab runs for an unhandled key.
    KeyUnhandled {
        input_seq: u32,
    },
    /// The page opened a tab (Cmd-click, `target=_blank`, `window.open`):
    /// the App creates a remote tab on the same host and answers with
    /// `tab_opened`.
    OpenTab {
        request: u64,
        url: String,
        disposition: Disposition,
        user_gesture: bool,
    },
}

/// Inputs that change nothing, and why.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum ClientNote {
    /// An answer for a menu or dialog that is no longer open.
    StaleAnswer,
    /// The host cancelled a menu or dialog that is no longer open.
    StaleCancel,
    /// A menu or dialog token that does not increase.
    StaleShow,
    /// `rb.screen_applied` for an older `rb.screen`.
    StaleScreen,
    /// `tab_opened` for a request the host did not make or that was answered.
    UnknownRequest,
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
    /// A menu answer the open menu did not offer (an id it did not show,
    /// a separator or submenu, an index out of range or repeated, several
    /// indices for a single select, or the other menu kind's choice).
    InvalidChoice,
}

#[derive(Debug, Clone, PartialEq, Default)]
pub struct ClientOutcome {
    pub effects: Vec<ClientEffect>,
    pub note: Option<ClientNote>,
}

/// Viewer state of one remote tab for one rb session. Make a new `Client`
/// for each session (each `rb.open`): the host restarts menu and dialog
/// tokens and the screen seq per session, so a reused client would call a
/// new session's first menu stale and refuse its first `rb.screen_applied`.
#[derive(Debug, Clone, PartialEq, Default)]
pub struct Client {
    pub open_menu: Option<u64>,
    pub open_dialog: Option<u64>,
    /// The seq of the last `rb.screen` sent.
    pub screen_seq: u32,
    last_menu: u64,
    last_dialog: u64,
    /// The open menu's answers (checked before a choice is sent).
    shown_menu: Option<OpenMenu>,
    /// `rb.open_tab` requests the App has not answered.
    pending_tabs: BTreeSet<u64>,
}

impl Client {
    pub fn apply(&mut self, input: ClientInput) -> Result<ClientOutcome, ClientReject> {
        match input {
            ClientInput::Host { message } => self.host(message),
            ClientInput::MenuChosen { token, choice } => {
                if self.open_menu != Some(token) {
                    return Ok(note(ClientNote::StaleAnswer));
                }
                if !self.shown_menu.as_ref().is_some_and(|menu| menu.accepts(&choice)) {
                    return Err(ClientReject::InvalidChoice);
                }
                self.open_menu = None;
                self.shown_menu = None;
                Ok(send(Control::MenuResult { token, choice }))
            }
            ClientInput::DialogAnswered { token, accept, text } => {
                Ok(if self.open_dialog == Some(token) {
                    self.open_dialog = None;
                    send(Control::DialogResult { token, accept, text })
                } else {
                    note(ClientNote::StaleAnswer)
                })
            }
            ClientInput::Resize { screen } => {
                self.screen_seq = self.screen_seq.saturating_add(1);
                Ok(send(Control::Screen { seq: self.screen_seq, screen }))
            }
            ClientInput::Navigate { url } => Ok(send(Control::Navigate { request: None, url })),
            ClientInput::TabOpened { request, tab, refused } => {
                Ok(if self.pending_tabs.remove(&request) {
                    send(Control::OpenTabResult { request, tab, refused })
                } else {
                    note(ClientNote::UnknownRequest)
                })
            }
        }
    }

    fn host(&mut self, message: Control) -> Result<ClientOutcome, ClientReject> {
        if viewer_to_host(&message) {
            return Err(ClientReject::WrongDirection);
        }
        Ok(match message {
            Control::MenuShow { token, menu } => {
                if token <= self.last_menu {
                    return Ok(note(ClientNote::StaleShow));
                }
                self.last_menu = token;
                self.shown_menu = Some(OpenMenu::for_menu(token, &menu));
                let mut effects = Vec::new();
                if let Some(old) = self.open_menu.replace(token) {
                    effects.push(ClientEffect::CloseMenu { token: old });
                }
                effects.push(ClientEffect::ShowMenu { token, menu });
                effects_only(effects)
            }
            Control::MenuCancel { token } => {
                if self.open_menu != Some(token) {
                    return Ok(note(ClientNote::StaleCancel));
                }
                self.open_menu = None;
                self.shown_menu = None;
                effects_only(vec![ClientEffect::CloseMenu { token }])
            }
            Control::DialogShow { token, dialog } => {
                if token <= self.last_dialog {
                    return Ok(note(ClientNote::StaleShow));
                }
                self.last_dialog = token;
                let mut effects = Vec::new();
                if let Some(old) = self.open_dialog.replace(token) {
                    effects.push(ClientEffect::CloseDialog { token: old });
                }
                effects.push(ClientEffect::ShowDialog { token, dialog });
                effects_only(effects)
            }
            Control::DialogCancel { token } => {
                if self.open_dialog != Some(token) {
                    return Ok(note(ClientNote::StaleCancel));
                }
                self.open_dialog = None;
                effects_only(vec![ClientEffect::CloseDialog { token }])
            }
            Control::State { state } => self.session(state),
            Control::Closed { .. } => self.session(SessionState::Closed),
            Control::Cursor { cursor } => effects_only(vec![ClientEffect::SetCursor { cursor }]),
            Control::Page { url, title, loading, can_go_back, can_go_forward } => {
                effects_only(vec![ClientEffect::Page {
                    url,
                    title,
                    loading,
                    can_go_back,
                    can_go_forward,
                }])
            }
            Control::TextInput { input_type, composition_rects, caret } => {
                effects_only(vec![ClientEffect::TextInput { input_type, composition_rects, caret }])
            }
            Control::ScreenApplied { seq, pixel_width, pixel_height, scale } => {
                if seq > self.screen_seq {
                    return Err(ClientReject::UnknownScreenSeq);
                }
                if seq < self.screen_seq {
                    return Ok(note(ClientNote::StaleScreen));
                }
                effects_only(vec![ClientEffect::ScreenApplied { pixel_width, pixel_height, scale }])
            }
            Control::KeyUnhandled { input_seq } => {
                effects_only(vec![ClientEffect::KeyUnhandled { input_seq }])
            }
            Control::OpenTab { request, url, disposition, user_gesture } => {
                self.pending_tabs.insert(request);
                effects_only(vec![ClientEffect::OpenTab {
                    request,
                    url,
                    disposition,
                    user_gesture,
                }])
            }
            _ => note(ClientNote::Unhandled),
        })
    }

    /// A crashed or closed session closes the open menu and dialog first
    /// (no answers are sent: the host has nothing waiting for them).
    fn session(&mut self, state: SessionState) -> ClientOutcome {
        let mut effects = Vec::new();
        if matches!(state, SessionState::Crashed | SessionState::Closed) {
            if let Some(token) = self.open_menu.take() {
                self.shown_menu = None;
                effects.push(ClientEffect::CloseMenu { token });
            }
            if let Some(token) = self.open_dialog.take() {
                effects.push(ClientEffect::CloseDialog { token });
            }
        }
        effects.push(ClientEffect::Session { state });
        effects_only(effects)
    }
}

/// Messages only a viewer sends (remote-tab-protocol.md section 4, direction V).
fn viewer_to_host(message: &Control) -> bool {
    matches!(
        message,
        Control::Open { .. }
            | Control::Close
            | Control::Visibility { .. }
            | Control::Screen { .. }
            | Control::Vsync { .. }
            | Control::History { .. }
            | Control::Navigate { .. }
            | Control::MenuResult { .. }
            | Control::DialogResult { .. }
            | Control::FileChooserResult { .. }
            | Control::UploadEnd { .. }
            | Control::DownloadCancel { .. }
            | Control::PermissionResult { .. }
            | Control::ClipboardPush { .. }
            | Control::OpenTabResult { .. }
            | Control::Find { .. }
            | Control::FindStop { .. }
            | Control::ScrollClaim { .. }
            | Control::ScrollUpdate { .. }
            | Control::ScrollRelease { .. }
    )
}

fn send(message: Control) -> ClientOutcome {
    effects_only(vec![ClientEffect::Send { message }])
}

fn effects_only(effects: Vec<ClientEffect>) -> ClientOutcome {
    ClientOutcome { effects, note: None }
}

fn note(note: ClientNote) -> ClientOutcome {
    ClientOutcome { effects: Vec::new(), note: Some(note) }
}
