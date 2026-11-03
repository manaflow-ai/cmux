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
mod tests {
    use super::*;
    use crossterm::event::{KeyCode, KeyEvent, KeyModifiers};

    #[test]
    fn large_pastes_and_thousands_of_events_replay_in_order() {
        let mut spool = InputSpool::default();
        let text = "λ🙂\r\n\"".repeat(1_048_577);
        assert!(text.len() > 9 * 1024 * 1024);
        spool.push(&DeferredInput::Event(Event::Paste(text.clone()))).unwrap();
        spool.push(&DeferredInput::ToggleViewOnly).unwrap();
        for index in 0..4097 {
            spool.push(&DeferredInput::Event(Event::Resize(index, index + 1))).unwrap();
        }
        let key = DeferredInput::Event(Event::Key(KeyEvent::new(
            KeyCode::Char('z'),
            KeyModifiers::CONTROL,
        )));
        spool.push(&key).unwrap();
        assert!(!spool.is_empty());
        assert!(spool.write_at > text.len() as u64);
        assert_eq!(spool.pop().unwrap(), Some(DeferredInput::Event(Event::Paste(text))));
        assert_eq!(spool.pop().unwrap(), Some(DeferredInput::ToggleViewOnly));
        for index in 0..4097 {
            assert_eq!(
                spool.pop().unwrap(),
                Some(DeferredInput::Event(Event::Resize(index, index + 1)))
            );
        }
        assert_eq!(spool.pop().unwrap(), Some(key));
        assert!(spool.is_empty());
        assert!(spool.file.is_none(), "drain releases the temporary file");
        assert_eq!(spool.pop().unwrap(), None);
    }

    #[test]
    fn append_after_partial_replay_and_cancel_release_the_fifo() {
        let mut spool = InputSpool::default();
        spool.push(&DeferredInput::Event(Event::FocusLost)).unwrap();
        spool.push(&DeferredInput::Event(Event::FocusGained)).unwrap();
        assert_eq!(spool.pop().unwrap(), Some(DeferredInput::Event(Event::FocusLost)));
        spool.push(&DeferredInput::Event(Event::Resize(80, 24))).unwrap();
        assert_eq!(spool.pop().unwrap(), Some(DeferredInput::Event(Event::FocusGained)));
        assert_eq!(spool.pop().unwrap(), Some(DeferredInput::Event(Event::Resize(80, 24))));
        spool.push(&DeferredInput::Event(Event::Paste("cancelled".into()))).unwrap();
        spool.clear();
        assert!(spool.file.is_none());
        assert_eq!(spool.pop().unwrap(), None);
        spool.push(&DeferredInput::Event(Event::FocusGained)).unwrap();
        assert_eq!(spool.pop().unwrap(), Some(DeferredInput::Event(Event::FocusGained)));
    }
}
