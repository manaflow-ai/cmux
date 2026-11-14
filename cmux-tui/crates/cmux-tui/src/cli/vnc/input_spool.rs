//! Deferred terminal input while the socket writer is backpressured.
//!
//! Keep reading local viewer commands without retaining an unbounded queue of
//! paste strings. Only the current event is resident; the FIFO lives in an
//! anonymous temporary file which disappears on drain, cancellation or drop.

use std::fs::File;
use std::io::{self, BufReader, BufWriter, Read, Seek, SeekFrom, Write};

use crossterm::event::Event;

const BUFFER_BYTES: usize = 16 * 1024;

/// Events and mode changes share one order. A mode change must not silently
/// suppress input which was accepted before the command arrived.
#[derive(Debug, PartialEq, Eq, serde::Serialize, serde::Deserialize)]
pub(super) enum DeferredInput {
    Event(Event),
    ToggleViewOnly,
    SendEscape,
}

#[derive(Default)]
pub(super) struct InputSpool {
    file: Option<File>,
    read_at: u64,
    write_at: u64,
}

impl InputSpool {
    pub fn is_empty(&self) -> bool {
        self.read_at == self.write_at
    }

    /// Stream an event into the FIFO without a second encoded paste allocation.
    /// The length prefix is filled in only after serialization succeeds.
    pub fn push(&mut self, event: &DeferredInput) -> io::Result<()> {
        if self.file.is_none() {
            self.file = Some(tempfile::tempfile()?);
        }
        let Some(file) = &mut self.file else {
            return Err(io::Error::other("terminal input spool is unavailable"));
        };
        match append(file, self.write_at, event) {
            Ok(end) => {
                self.write_at = end;
                Ok(())
            }
            Err(error) => {
                // Leave already accepted events readable after an append error.
                file.set_len(self.write_at)?;
                Err(error)
            }
        }
    }

    pub fn pop(&mut self) -> io::Result<Option<DeferredInput>> {
        if self.is_empty() {
            return Ok(None);
        }
        let Some(file) = &mut self.file else {
            return Err(io::Error::other("terminal input spool is unavailable"));
        };
        file.seek(SeekFrom::Start(self.read_at))?;
        let mut length = [0; 8];
        file.read_exact(&mut length)?;
        let length = u64::from_le_bytes(length);
        let body_at = file.stream_position()?;
        if length > self.write_at.saturating_sub(body_at) {
            return Err(io::Error::new(io::ErrorKind::InvalidData, "incomplete terminal input"));
        }
        let event = serde_json::from_reader(BufReader::with_capacity(
            BUFFER_BYTES,
            (&mut *file).take(length),
        ))?;
        self.read_at = file.stream_position()?;
        if self.is_empty() {
            self.clear();
        }
        Ok(Some(event))
    }

    pub fn clear(&mut self) {
        self.file = None;
        self.read_at = 0;
        self.write_at = 0;
    }
}

fn append(file: &mut File, start: u64, event: &DeferredInput) -> io::Result<u64> {
    file.seek(SeekFrom::Start(start))?;
    file.write_all(&0u64.to_le_bytes())?;
    let body_at = file.stream_position()?;
    {
        let mut writer = BufWriter::with_capacity(BUFFER_BYTES, &mut *file);
        serde_json::to_writer(&mut writer, event)?;
        writer.flush()?;
    }
    let end = file.stream_position()?;
    file.seek(SeekFrom::Start(start))?;
    file.write_all(&end.saturating_sub(body_at).to_le_bytes())?;
    Ok(end)
}

#[cfg(test)]
mod tests;
