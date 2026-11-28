//! Sharing one X window: the top-level windows a viewer may pick (`_NET_CLIENT_LIST`, else the
//! root's mapped children when no EWMH window manager runs), each window's rect in root
//! coordinates, and how a shared window's moves and resizes change the [`View`] a session
//! streams. Capture still reads the root window, so a window stacked over the shared one shows
//! in the picture (no Composite redirect).

use crate::capture::Rect;
use crate::x11_view::View;
use crate::Res;
use x11rb::connection::Connection;
use x11rb::protocol::xproto::{AtomEnum, ConnectionExt as _, MapState, Window, WindowClass};

/// A window's rect on the root, in pixels; it may reach past the screen's edges.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct WinRect {
    pub x: i32,
    pub y: i32,
    pub w: u32,
    pub h: u32,
}

/// One window the viewer may pick.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct WindowInfo {
    pub id: u32,
    pub title: String,
    pub rect: WinRect,
}

/// What the lister read about one candidate window.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct Candidate {
    pub id: u32,
    pub title: Option<String>,
    pub rect: WinRect,
    /// Mapped and its ancestors mapped (`IsViewable`).
    pub viewable: bool,
    /// InputOutput (an InputOnly window draws nothing).
    pub draws: bool,
    pub override_redirect: bool,
}

/// The part of `r` on a screen of `screen` size, even-aligned for 4:2:0; None when too little
/// of it is on screen to stream (off screen, or under 2x2 pixels).
pub fn on_screen(r: WinRect, screen: (u32, u32)) -> Option<Rect> {
    let x0 = i64::from(r.x).max(0);
    let y0 = i64::from(r.y).max(0);
    let x1 = (i64::from(r.x) + i64::from(r.w)).min(i64::from(screen.0));
    let y1 = (i64::from(r.y) + i64::from(r.h)).min(i64::from(screen.1));
    // Round the start up and the end down to even, so the rect never shows past the window.
    let (x0, y0) = ((x0 + 1) & !1, (y0 + 1) & !1);
    let (x1, y1) = (x1 & !1, y1 & !1);
    (x1 - x0 >= 2 && y1 - y0 >= 2).then(|| Rect {
        x: x0 as u32,
        y: y0 as u32,
        w: (x1 - x0) as u32,
        h: (y1 - y0) as u32,
    })
}

/// The windows a viewer may pick, in the window manager's order: viewable, drawing,
/// with some part on screen. Without a window manager's client list (`from_client_list`
/// false: the root's children) override-redirect windows (menus, tooltips) and untitled ones
/// are left out too; the client list names only managed windows already.
pub fn filter(
    candidates: &[Candidate],
    screen: (u32, u32),
    from_client_list: bool,
) -> Vec<WindowInfo> {
    candidates
        .iter()
        .filter(|c| c.viewable && c.draws && c.rect.w > 0 && c.rect.h > 0)
        .filter(|c| from_client_list || (!c.override_redirect && c.title.is_some()))
        .filter(|c| on_screen(c.rect, screen).is_some())
        .map(|c| WindowInfo { id: c.id, title: c.title.clone().unwrap_or_default(), rect: c.rect })
        .collect()
}

/// A shared window, followed through moves.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Followed {
    /// The window's rect when the share started; a different size ends the share.
    pub start: WinRect,
    /// Where the streamed rect sits inside the window (the part on screen at the start).
    pub offset: (u32, u32),
}

/// What a shared window's new rect means for the session.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Change {
    /// Nothing to do (same rect).
    Same,
    /// The window moved: stream this source rect (same size, so the encoder keeps its size).
    Moved(Rect),
    /// The window changed size: the encoder's picture cannot follow, the share ends.
    Resized { from: (u32, u32), to: (u32, u32) },
}

impl Followed {
    /// The view of `window` on a screen of `screen` size, fitted into `max_width`, and how to
    /// follow it. Err when no part of it is on screen.
    pub fn start(
        id: u32,
        window: WinRect,
        screen: (u32, u32),
        max_width: Option<u32>,
    ) -> Result<(Followed, View), String> {
        let src = on_screen(window, screen).ok_or_else(|| {
            format!(
                "window {id:#x} is not on the screen ({}x{} at {},{})",
                window.w, window.h, window.x, window.y
            )
        })?;
        let offset = (
            (i64::from(src.x) - i64::from(window.x)) as u32,
            (i64::from(src.y) - i64::from(window.y)) as u32,
        );
        Ok((Followed { start: window, offset }, View::new(src, max_width)))
    }

    /// The window's rect is now `now`; `src` is the source rect streamed so far. A move keeps
    /// the streamed size and the same part of the window, slid back inside the screen where
    /// the window went past an edge (that part of the picture then shows what is beside it).
    pub fn on_change(&self, now: WinRect, src: Rect, screen: (u32, u32)) -> Change {
        if (now.w, now.h) != (self.start.w, self.start.h) {
            return Change::Resized { from: (self.start.w, self.start.h), to: (now.w, now.h) };
        }
        let place = |origin: i32, offset: u32, size: u32, limit: u32| -> u32 {
            let want = i64::from(origin) + i64::from(offset);
            (want.clamp(0, i64::from(limit.saturating_sub(size))) as u32) & !1
        };
        let moved = Rect {
            x: place(now.x, self.offset.0, src.w, screen.0),
            y: place(now.y, self.offset.1, src.h, screen.1),
            w: src.w,
            h: src.h,
        };
        if moved == src {
            Change::Same
        } else {
            Change::Moved(moved)
        }
    }
}

/// `window`'s rect in root coordinates (its own border excluded). Err when it does not exist.
pub fn rect(conn: &impl Connection, root: Window, window: Window) -> Res<WinRect> {
    let geo = conn
        .get_geometry(window)?
        .reply()
        .map_err(|e| format!("window {window:#x} is not on this X display: {e}"))?;
    let at = conn.translate_coordinates(window, root, 0, 0)?.reply()?;
    Ok(WinRect {
        x: i32::from(at.dst_x),
        y: i32::from(at.dst_y),
        w: u32::from(geo.width),
        h: u32::from(geo.height),
    })
}

/// The window's top-level ancestor (the window manager's frame), or itself when its parent is
/// the root. Moves of a reparented window change the frame, not the window.
pub fn frame(conn: &impl Connection, root: Window, window: Window) -> Res<Window> {
    let mut at = window;
    for _ in 0..16 {
        let tree = conn.query_tree(at)?.reply()?;
        if tree.parent == root || tree.parent == 0 {
            return Ok(at);
        }
        at = tree.parent;
    }
    Ok(at)
}

fn atom(conn: &impl Connection, name: &[u8]) -> u32 {
    conn.intern_atom(true, name).ok().and_then(|c| c.reply().ok()).map_or(0, |r| r.atom)
}

/// `_NET_WM_NAME` (UTF-8), else `WM_NAME`; None when neither is set or both are empty.
fn title(conn: &impl Connection, window: Window, net_wm_name: u32, utf8: u32) -> Option<String> {
    let read = |prop: u32, ty: u32| {
        conn.get_property(false, window, prop, ty, 0, 1024)
            .ok()
            .and_then(|c| c.reply().ok())
            .filter(|r| r.type_ != 0 && !r.value.is_empty())
            .map(|r| String::from_utf8_lossy(&r.value).trim_end_matches('\0').to_owned())
    };
    let net = (net_wm_name != 0 && utf8 != 0).then(|| read(net_wm_name, utf8)).flatten();
    net.or_else(|| read(AtomEnum::WM_NAME.into(), AtomEnum::ANY.into())).filter(|t| !t.is_empty())
}

/// The top-level windows on the X screen of `root` (size `screen`) a viewer may pick.
pub fn list(conn: &impl Connection, root: Window, screen: (u32, u32)) -> Vec<WindowInfo> {
    let client_list = atom(conn, b"_NET_CLIENT_LIST");
    let managed = (client_list != 0)
        .then(|| {
            conn.get_property(false, root, client_list, AtomEnum::WINDOW, 0, 4096)
                .ok()
                .and_then(|c| c.reply().ok())
                .filter(|r| r.type_ != 0)
                .and_then(|r| r.value32().map(Iterator::collect::<Vec<u32>>))
        })
        .flatten();
    let from_client_list = managed.is_some();
    let ids = match managed {
        Some(ids) => ids,
        None => conn
            .query_tree(root)
            .ok()
            .and_then(|c| c.reply().ok())
            .map(|t| t.children)
            .unwrap_or_default(),
    };
    let (net_wm_name, utf8) = (atom(conn, b"_NET_WM_NAME"), atom(conn, b"UTF8_STRING"));
    let candidates: Vec<Candidate> = ids
        .into_iter()
        .filter_map(|id| {
            let attrs = conn.get_window_attributes(id).ok()?.reply().ok()?;
            let rect = rect(conn, root, id).ok()?;
            Some(Candidate {
                id,
                title: title(conn, id, net_wm_name, utf8),
                rect,
                viewable: attrs.map_state == MapState::VIEWABLE,
                draws: attrs.class == WindowClass::INPUT_OUTPUT,
                override_redirect: attrs.override_redirect,
            })
        })
        .collect();
    filter(&candidates, screen, from_client_list)
}

#[cfg(test)]
#[path = "x11_window_tests.rs"]
mod tests;
