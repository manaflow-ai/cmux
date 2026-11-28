use core::fmt;

use crate::config::ASSEMBLER_MAX_SEGMENT_COUNT;

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct TooManyHolesError;

impl fmt::Display for TooManyHolesError {
    fn fmt(&self, f: &mut fmt::Formatter) -> fmt::Result {
        write!(f, "too many holes")
    }
}

impl core::error::Error for TooManyHolesError {}

/// A contiguous chunk of absent data, followed by a contiguous chunk of present data.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
struct Contig {
    hole_size: usize,
    data_size: usize,
}

impl fmt::Display for Contig {
    fn fmt(&self, f: &mut fmt::Formatter) -> fmt::Result {
        if self.has_hole() {
            write!(f, "({})", self.hole_size)?;
        }
        if self.has_hole() && self.has_data() {
            write!(f, " ")?;
        }
        if self.has_data() {
            write!(f, "{}", self.data_size)?;
        }
        Ok(())
    }
}

#[cfg(feature = "defmt")]
impl defmt::Format for Contig {
    fn format(&self, fmt: defmt::Formatter) {
        if self.has_hole() {
            defmt::write!(fmt, "({})", self.hole_size);
        }
        if self.has_hole() && self.has_data() {
            defmt::write!(fmt, " ");
        }
        if self.has_data() {
            defmt::write!(fmt, "{}", self.data_size);
        }
    }
}

impl Contig {
    const fn empty() -> Contig {
        Contig {
            hole_size: 0,
            data_size: 0,
        }
    }

    fn hole_and_data(hole_size: usize, data_size: usize) -> Contig {
        Contig {
            hole_size,
            data_size,
        }
    }

    fn has_hole(&self) -> bool {
        self.hole_size != 0
    }

    fn has_data(&self) -> bool {
        self.data_size != 0
    }

    fn total_size(&self) -> usize {
        self.hole_size + self.data_size
    }

    fn shrink_hole_by(&mut self, size: usize) {
        self.hole_size -= size;
    }

    fn shrink_hole_to(&mut self, size: usize) {
        debug_assert!(self.hole_size >= size);

        let total_size = self.total_size();
        self.hole_size = size;
        self.data_size = total_size - size;
    }
}

/// A buffer (re)assembler.
///
/// Currently, up to a hardcoded limit of 4 or 32 holes can be tracked in the buffer.
#[derive(Debug, PartialEq, Eq, Clone)]
pub struct Assembler {
    contigs: [Contig; ASSEMBLER_MAX_SEGMENT_COUNT],
}

impl fmt::Display for Assembler {
    fn fmt(&self, f: &mut fmt::Formatter) -> fmt::Result {
        write!(f, "[ ")?;
        for contig in self.contigs.iter() {
            if !contig.has_data() {
                break;
            }
            write!(f, "{contig} ")?;
        }
        write!(f, "]")?;
        Ok(())
    }
}

#[cfg(feature = "defmt")]
impl defmt::Format for Assembler {
    fn format(&self, fmt: defmt::Formatter) {
        defmt::write!(fmt, "[ ");
        for contig in self.contigs.iter() {
            if !contig.has_data() {
                break;
            }
            defmt::write!(fmt, "{} ", contig);
        }
        defmt::write!(fmt, "]");
    }
}

// Invariant on Assembler::contigs:
// - There's an index `i` where all contigs before have data, and all contigs after don't (are unused).
// - All contigs with data must have hole_size != 0, except the first.

impl Assembler {
    /// Create a new buffer assembler.
    pub const fn new() -> Assembler {
        const EMPTY: Contig = Contig::empty();
        Assembler {
            contigs: [EMPTY; ASSEMBLER_MAX_SEGMENT_COUNT],
        }
    }

    pub fn clear(&mut self) {
        self.contigs.fill(Contig::empty());
    }

    fn front(&self) -> Contig {
        self.contigs[0]
    }

    /// Return length of the front contiguous range without removing it from the assembler
    pub fn peek_front(&self) -> usize {
        let front = self.front();
        if front.has_hole() { 0 } else { front.data_size }
    }

    fn back(&self) -> Contig {
        self.contigs[self.contigs.len() - 1]
    }

    /// Return whether the assembler contains no data.
    pub fn is_empty(&self) -> bool {
        !self.front().has_data()
    }

    /// Remove a contig at the given index.
    fn remove_contig_at(&mut self, at: usize) {
        debug_assert!(self.contigs[at].has_data());

        for i in at..self.contigs.len() - 1 {
            if !self.contigs[i].has_data() {
                return;
            }
            self.contigs[i] = self.contigs[i + 1];
        }

        // Removing the last one.
        self.contigs[self.contigs.len() - 1] = Contig::empty();
    }

    /// Add a contig at the given index, and return a pointer to it.
    fn add_contig_at(&mut self, at: usize) -> Result<&mut Contig, TooManyHolesError> {
        if self.back().has_data() {
            return Err(TooManyHolesError);
        }

        for i in (at + 1..self.contigs.len()).rev() {
            self.contigs[i] = self.contigs[i - 1];
        }

        self.contigs[at] = Contig::empty();
        Ok(&mut self.contigs[at])
    }

    /// Add a new contiguous range to the assembler,
    /// or return `Err(TooManyHolesError)` if too many discontinuities are already recorded.
    pub fn add(&mut self, mut offset: usize, size: usize) -> Result<(), TooManyHolesError> {
        if size == 0 {
            return Ok(());
        }

        let mut i = 0;

        // Find index of the contig containing the start of the range.
        loop {
            if i == self.contigs.len() {
                // The new range is after all the previous ranges, but there/s no space to add it.
                return Err(TooManyHolesError);
            }
            let contig = &mut self.contigs[i];
            if !contig.has_data() {
                // The new range is after all the previous ranges. Add it.
                *contig = Contig::hole_and_data(offset, size);
                return Ok(());
            }
            if offset <= contig.total_size() {
                break;
            }
            offset -= contig.total_size();
            i += 1;
        }

        let contig = &mut self.contigs[i];
        if offset < contig.hole_size {
            // Range starts within the hole.

            if offset + size < contig.hole_size {
                // Range also ends within the hole.
                let new_contig = self.add_contig_at(i)?;
                new_contig.hole_size = offset;
                new_contig.data_size = size;

                // Previous contigs[index] got moved to contigs[index+1]
                self.contigs[i + 1].shrink_hole_by(offset + size);
                return Ok(());
            }

            // The range being added covers both a part of the hole and a part of the data
            // in this contig, shrink the hole in this contig.
            contig.shrink_hole_to(offset);
        }

        // coalesce contigs to the right.
        let mut j = i + 1;
        while j < self.contigs.len()
            && self.contigs[j].has_data()
            && offset + size >= self.contigs[i].total_size() + self.contigs[j].hole_size
        {
            self.contigs[i].data_size += self.contigs[j].total_size();
            j += 1;
        }
        let shift = j - i - 1;
        if shift != 0 {
            for x in i + 1..self.contigs.len() {
                if !self.contigs[x].has_data() {
                    break;
                }

                self.contigs[x] = self
                    .contigs
                    .get(x + shift)
                    .copied()
                    .unwrap_or_else(Contig::empty);
            }
        }

        if offset + size > self.contigs[i].total_size() {
            // The added range still extends beyond the current contig. Increase data size.
            let left = offset + size - self.contigs[i].total_size();
            self.contigs[i].data_size += left;

            // Decrease hole size of the next, if any.
            if i + 1 < self.contigs.len() && self.contigs[i + 1].has_data() {
                self.contigs[i + 1].hole_size -= left;
            }
        }

        Ok(())
    }

    /// Remove a contiguous range from the front of the assembler.
    /// If no such range, return 0.
    pub fn remove_front(&mut self) -> usize {
        let front = self.front();
        if front.has_hole() || !front.has_data() {
            0
        } else {
            self.remove_contig_at(0);
            debug_assert!(front.data_size > 0);
            front.data_size
        }
    }

    /// Add a segment, then remove_front.
    ///
    /// This is equivalent to calling `add` then `remove_front` individually,
    /// except it's guaranteed to not fail when offset = 0.
    /// This is required for TCP: we must never drop the next expected segment, or
    /// the protocol might get stuck.
    pub fn add_then_remove_front(
        &mut self,
        offset: usize,
        size: usize,
    ) -> Result<usize, TooManyHolesError> {
        // This is the only case where a segment at offset=0 would cause the
        // total amount of contigs to rise (and therefore can potentially cause
        // a TooManyHolesError). Handle it in a way that is guaranteed to succeed.
        if offset == 0 && size < self.contigs[0].hole_size {
            self.contigs[0].hole_size -= size;
            return Ok(size);
        }

        self.add(offset, size)?;
        Ok(self.remove_front())
    }

    /// Iterate over all of the contiguous data ranges.
    ///
    /// Returns `(offset, size)` tuples for each contiguous data range, where
    /// offset is relative to the start of the assembler.
    ///
    ///    Data        Hole        Data
    /// |--- 100 ---|--- 200 ---|--- 100 ---|
    ///
    /// Would return the ranges: ``(0, 100), (300, 400)``
    pub fn iter_data(&self) -> impl Iterator<Item = (usize, usize)> + '_ {
        let mut offset = 0;
        self.contigs.iter().filter_map(move |contig| {
            offset += contig.hole_size;
            let left = offset;
            offset += contig.data_size;
            let right = offset;
            if left < right {
                Some((left, right))
            } else {
                None
            }
        })
    }
}

#[cfg(test)]
#[path = "assembler_test_tests.rs"]
mod test;
