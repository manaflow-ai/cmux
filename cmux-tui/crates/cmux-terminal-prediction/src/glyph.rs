//! One character cmux is drawing that the remote has not put on the screen yet.

/// Where a drawn glyph stands against the remote's echo.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
#[repr(u8)]
pub enum Standing {
    /// Sent to the remote, no echo yet. Drawn as unconfirmed (underlined).
    Speculative = 0,
    /// The remote echoed it. Kept until the frame carrying the real character
    /// is on screen, otherwise the cell blanks for one frame.
    Confirmed = 1,
    /// The user deleted this character before the remote erased it. Its echo
    /// may still be on its way or already painted, so the host paints the
    /// cell's background and nothing else until the erase lands; otherwise the
    /// deleted character shows again for a round trip. `character` is a space.
    Erased = 2,
}

/// Offsets are cells to the right of the live cursor, which is all the host
/// needs: it reads the cursor cell from the surface and advances by the cell
/// width. A confirmed glyph has a negative offset, because the cursor already
/// moved past the echo it is standing in for. Only printable ASCII is ever
/// predicted, so a character is one byte.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct PredictedGlyph {
    pub character: u8,
    pub offset: i32,
    pub standing: Standing,
}
