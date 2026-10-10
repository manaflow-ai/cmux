//! Unit tests for the surface module, split by topic under surface/tests/.
//! This file holds the writers that the input and clear-history topics share.

mod attach_tap;
mod byte_mirror;
mod child_process;
mod clear_history;
mod clear_history_tests;
#[cfg(unix)]
mod clipboard_read;
mod colors;
mod hosted;
mod input;
mod lifecycle;
mod lock_order;
mod render_geometry;
mod stream_progress;
use base64::Engine as _;
use std::sync::mpsc::sync_channel;

use super::*;
use crate::MuxEvent;

#[derive(Clone, Default)]
struct CapturingWriter(Arc<Mutex<Vec<u8>>>);

impl Write for CapturingWriter {
    fn write(&mut self, bytes: &[u8]) -> std::io::Result<usize> {
        self.0.lock().unwrap().extend_from_slice(bytes);
        Ok(bytes.len())
    }

    fn flush(&mut self) -> std::io::Result<()> {
        Ok(())
    }
}

struct TerminalProbeDuringWrite {
    written: Arc<Mutex<Vec<u8>>>,
    surface: Weak<Surface>,
}

impl Write for TerminalProbeDuringWrite {
    fn write(&mut self, bytes: &[u8]) -> std::io::Result<usize> {
        let Some(surface) = self.surface.upgrade() else {
            return Err(std::io::Error::new(std::io::ErrorKind::BrokenPipe, "surface was dropped"));
        };
        surface.with_terminal(|_| ());
        self.written.lock().unwrap().extend_from_slice(bytes);
        Ok(bytes.len())
    }

    fn flush(&mut self) -> std::io::Result<()> {
        Ok(())
    }
}

fn replace_local_writer(surface: &Surface, replacement: Box<dyn Write + Send>) {
    let pty = surface.as_pty().unwrap();
    let mut runtime = pty.runtime.lock().unwrap();
    let PtyRuntime::Local { writer, .. } = &mut *runtime else {
        panic!("test surface unexpectedly uses a terminal host");
    };
    *writer = replacement;
}
