//! Interface rules as checks an implementation runs in its own tests.

use crate::backend::{ByteTerminal, Close, Grid, Signal};
use crate::error::BackendError;
use crate::frames::{Direction, End, FrameBody, Lost};

/// Checks the end-after-close rule of [`ByteTerminal::close`] on a terminal
/// whose `close` just answered `Ok`: no frame follows (no `end`), and every
/// later call is refused. Answers the first broken rule.
pub fn check_closed(terminal: &mut dyn ByteTerminal) -> Result<(), String> {
    let frames = terminal.take_frames();
    if !frames.is_empty() {
        return Err(format!("frames after close: {frames:?}"));
    }
    let invalid = |what: &str, answer: Result<(), BackendError>| match answer {
        Err(BackendError::Invalid { .. }) => Ok(()),
        other => Err(format!("{what} after close answered {other:?}, not invalid")),
    };
    let refused = |what: &str, answer: Result<(), BackendError>| match answer {
        Err(BackendError::Invalid { .. } | BackendError::Unsupported) => Ok(()),
        other => Err(format!("{what} after close answered {other:?}, not a refusal")),
    };
    invalid("data", terminal.push(FrameBody::Data { offset: 1, bytes: vec![b'x'] }))?;
    let credit = FrameBody::Credit { direction: Direction::Out, bytes: 1 };
    invalid("out credit", terminal.push(credit))?;
    invalid("end", terminal.push(FrameBody::End(End::Lost(Lost::new("closed", true)))))?;
    refused("resize", terminal.resize(Grid::new(80, 24)))?;
    refused("signal", terminal.signal(Signal::Interrupt))?;
    invalid("a second close", terminal.close(Close::Now))?;
    let late = terminal.take_frames();
    if !late.is_empty() {
        return Err(format!("frames after the refused calls: {late:?}"));
    }
    Ok(())
}
