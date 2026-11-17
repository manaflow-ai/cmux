//! Floating panes: the placement rules.
//!
//! Every pane of a screen is a leaf of the screen's split tree. A floating pane is a leaf the tiled layout leaves out:
//! it is shown above the tiled panes in a frame of its own. A screen's floating panes are one list, back to front: the
//! last entry is the front pane. A build that does not know the list shows every pane tiled and loses none.
//!
//! The rules are pure. The daemon keeps the list on the screen, stores it and puts it in the layout undo; a frontend
//! draws it. Each public free function but `new_frame` takes `panes`, each pane of the screen once, and the list:
//!
//! - **F1, membership.** Every entry names a pane of the screen, and no pane has two entries.
//! - **F2, ground.** A screen keeps at least one tiled pane: [`place`] refuses to float the last one
//!   ([`FloatRefusal::LastTiledPane`]), and when the last tiled pane leaves the screen, the front floating pane becomes
//!   tiled ([`normalized`]).
//! - **F3, frame.** A frame is inside the screen and not smaller than [`MIN_EXTENT`] on either axis
//!   ([`FloatFrame::clamped`]).
//! - **F4, order.** Floating a pane, and giving a floating pane a frame, makes it the front pane. No other rule
//!   changes the order of the entries that stay.
//!
//! A frame is four fractions of the screen's pane area in millionths. Integers make two equal frames compare equal in
//! the daemon, in its store and in a frontend, and keep a frame the same when it comes back from the store.

/// The whole extent of the screen's pane area on one axis, in the unit of a [`FloatFrame`].
pub const UNIT: u32 = 1_000_000;

/// The smallest width and the smallest height of a floating pane: 15 percent of the pane area.
pub const MIN_EXTENT: u32 = 150_000;

/// The width and the height of a new floating pane that brings no frame: 60 percent of the pane area.
pub const NEW_EXTENT: u32 = 600_000;

/// How far a new floating pane sits right of and below the one that holds the place it would take.
pub const CASCADE_STEP: u32 = 30_000;

/// Where a floating pane is: its top left corner and its size, in millionths of the screen's pane area.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub struct FloatFrame {
    pub x: u32,
    pub y: u32,
    pub w: u32,
    pub h: u32,
}

impl FloatFrame {
    /// The frame moved and resized into the screen (F3): the size first, then the corner.
    pub fn clamped(self) -> FloatFrame {
        let w = self.w.clamp(MIN_EXTENT, UNIT);
        let h = self.h.clamp(MIN_EXTENT, UNIT);
        FloatFrame { x: self.x.min(UNIT - w), y: self.y.min(UNIT - h), w, h }
    }

    /// Whether the frame obeys F3 as it is.
    pub fn is_valid(self) -> bool {
        self == self.clamped()
    }

    /// A frame of `w` by `h` in the middle of the screen.
    pub fn centered(w: u32, h: u32) -> FloatFrame {
        let w = w.clamp(MIN_EXTENT, UNIT);
        let h = h.clamp(MIN_EXTENT, UNIT);
        FloatFrame { x: (UNIT - w) / 2, y: (UNIT - h) / 2, w, h }
    }

    /// The frame of four fractions of the pane area (`0.0..=1.0`), clamped. `None` when a value is not finite.
    pub fn from_fractions(x: f64, y: f64, w: f64, h: f64) -> Option<FloatFrame> {
        Some(
            FloatFrame {
                x: millionths(x)?,
                y: millionths(y)?,
                w: millionths(w)?,
                h: millionths(h)?,
            }
            .clamped(),
        )
    }

    /// The frame as four fractions of the pane area: `[x, y, w, h]`.
    pub fn fractions(self) -> [f64; 4] {
        [self.x, self.y, self.w, self.h].map(|value| f64::from(value) / f64::from(UNIT))
    }
}

/// `value` of `0.0..=1.0` in millionths; a value outside is taken to the nearer end. `None` when it is not finite.
fn millionths(value: f64) -> Option<u32> {
    if !value.is_finite() {
        return None;
    }
    // In 0.0..=1_000_000.0 after the clamp, so the cast is exact.
    Some((value.clamp(0.0, 1.0) * f64::from(UNIT)).round() as u32)
}

/// One floating pane of a screen: the pane and its frame.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub struct Floating<P> {
    pub pane: P,
    pub frame: FloatFrame,
}

/// What [`place`] does with the pane.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum FloatMode {
    /// Float a tiled pane; put a floating pane back into the tiled layout.
    Toggle,
    /// Float the pane. A pane that floats already comes to the front, and takes the frame when there is one.
    On,
    /// Put the pane back into the tiled layout. A tiled pane stays as it is.
    Off,
}

impl FloatMode {
    /// The mode of its wire name: `toggle`, `on` or `off`.
    pub fn parse(name: &str) -> Option<FloatMode> {
        match name {
            "toggle" => Some(FloatMode::Toggle),
            "on" => Some(FloatMode::On),
            "off" => Some(FloatMode::Off),
            _ => None,
        }
    }

    /// The wire name.
    pub fn as_str(self) -> &'static str {
        match self {
            FloatMode::Toggle => "toggle",
            FloatMode::On => "on",
            FloatMode::Off => "off",
        }
    }
}

/// Why [`place`] changed nothing.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum FloatRefusal {
    /// The pane is not a pane of the screen.
    UnknownPane,
    /// The pane is the only tiled pane of the screen (F2).
    LastTiledPane,
}

/// The list with F1, F2 and F3 restored: entries of panes that left the screen and second entries of one pane are
/// dropped, frames are clamped, and the front panes become tiled until one pane of the screen is tiled. The order of
/// the entries that stay is unchanged. `panes`: each pane of the screen once.
pub fn normalized<P: Clone + PartialEq>(panes: &[P], list: &[Floating<P>]) -> Vec<Floating<P>> {
    let mut kept: Vec<Floating<P>> = Vec::with_capacity(list.len());
    for entry in list {
        if !panes.contains(&entry.pane) || kept.iter().any(|seen| seen.pane == entry.pane) {
            continue;
        }
        kept.push(Floating { pane: entry.pane.clone(), frame: entry.frame.clamped() });
    }
    while !kept.is_empty() && kept.len() >= panes.len() {
        kept.pop();
    }
    kept
}

/// Whether the list obeys F1, F2 and F3 as it is.
pub fn is_normal<P: Clone + PartialEq>(panes: &[P], list: &[Floating<P>]) -> bool {
    normalized(panes, list).as_slice() == list
}

/// The frame of a new floating pane that brings none: [`NEW_EXTENT`] wide and high in the middle of the screen, moved
/// right and down by [`CASCADE_STEP`] while a floating pane has its corner at that place.
pub fn new_frame<P>(list: &[Floating<P>]) -> FloatFrame {
    let base = FloatFrame::centered(NEW_EXTENT, NEW_EXTENT);
    let steps = (UNIT - NEW_EXTENT) / 2 / CASCADE_STEP;
    for step in 0..=steps {
        let offset = step * CASCADE_STEP;
        let candidate = FloatFrame { x: base.x + offset, y: base.y + offset, ..base }.clamped();
        let taken =
            list.iter().any(|entry| entry.frame.x == candidate.x && entry.frame.y == candidate.y);
        if !taken {
            return candidate;
        }
    }
    base
}

/// Floats `pane`, puts it back, or moves it, by `mode`; the next list, already [`normalized`].
///
/// A pane that becomes floating takes `frame`, or [`new_frame`] when there is none, and is the front pane. A pane
/// that floats already and stays floating ([`FloatMode::On`]) comes to the front and takes `frame` when there is one:
/// this is the move and the resize of a floating pane. A result equal to `list` means nothing changed.
pub fn place<P: Clone + PartialEq>(
    panes: &[P],
    list: &[Floating<P>],
    pane: &P,
    mode: FloatMode,
    frame: Option<FloatFrame>,
) -> Result<Vec<Floating<P>>, FloatRefusal> {
    if !panes.contains(pane) {
        return Err(FloatRefusal::UnknownPane);
    }
    let mut next = normalized(panes, list);
    let at = next.iter().position(|entry| entry.pane == *pane);
    let float = match mode {
        FloatMode::Toggle => at.is_none(),
        FloatMode::On => true,
        FloatMode::Off => false,
    };
    match (at, float) {
        (Some(index), true) => {
            let mut entry = next.remove(index);
            if let Some(frame) = frame {
                entry.frame = frame.clamped();
            }
            next.push(entry);
        }
        (Some(index), false) => {
            next.remove(index);
        }
        (None, true) => {
            if panes.len().saturating_sub(next.len()) <= 1 {
                return Err(FloatRefusal::LastTiledPane);
            }
            let frame = match frame {
                Some(frame) => frame.clamped(),
                None => new_frame(&next),
            };
            next.push(Floating { pane: pane.clone(), frame });
        }
        (None, false) => {}
    }
    Ok(next)
}

/// The list with `pane` as the front pane, [`normalized`]. A pane that does not float changes nothing.
pub fn raised<P: Clone + PartialEq>(
    panes: &[P],
    list: &[Floating<P>],
    pane: &P,
) -> Vec<Floating<P>> {
    let mut next = normalized(panes, list);
    if let Some(index) = next.iter().position(|entry| entry.pane == *pane) {
        let entry = next.remove(index);
        next.push(entry);
    }
    next
}

/// The tiled panes of the screen, in the order of `panes`: the panes the [`normalized`] list does not name.
pub fn tiled<P: Clone + PartialEq>(panes: &[P], list: &[Floating<P>]) -> Vec<P> {
    let floating = normalized(panes, list);
    panes
        .iter()
        .filter(|pane| !floating.iter().any(|entry| entry.pane == **pane))
        .cloned()
        .collect()
}

#[cfg(test)]
#[path = "floating_panes_tests.rs"]
mod tests;
