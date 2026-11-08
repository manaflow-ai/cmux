//! One character the overlay draws.

/// How far the remote has got with a drawn glyph.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub enum Standing {
    /// Sent to the remote, no echo yet. Draw it as unconfirmed.
    Speculative,
    /// The remote echoed it. Keep drawing until the frame carrying the real
    /// character is on screen, otherwise the cell blanks for one frame.
    Confirmed,
    /// The user deleted this character before the remote erased it. Its
    /// echo may still be on its way or already painted, so the host paints
    /// the cell's background and nothing else until the erase lands;
    /// otherwise the deleted character shows again for a round trip.
    /// `character` is a space.
    Erased,
}

/// One character cmux is drawing that the remote has not put on the screen yet.
///
/// Offsets are cells to the right of the live cursor, which is all the host
/// needs: it reads the cursor cell from the surface and advances by the cell
/// width. A confirmed glyph has a negative offset, because the cursor already
/// moved past the echo it is standing in for.
#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
pub struct PredictedGlyph {
    pub character: char,
    pub offset: i32,
    pub standing: Standing,
}

impl PredictedGlyph {
    pub fn new(character: char, offset: i32, standing: Standing) -> Self {
        Self { character, offset, standing }
    }
}
