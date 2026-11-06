//! Linux desktops (placeholder; replaced by the Linux backend).
use std::sync::Arc;

use crate::desktop::Desktop;

pub mod x11;

pub fn open() -> Result<Arc<dyn Desktop>, String> {
    Ok(Arc::new(x11::X11Desktop::new(None)))
}

pub fn person_activity() -> Arc<dyn crate::engine::PersonActivity> {
    Arc::new(crate::engine::NoTakeover)
}

pub fn cursor_overlay() -> Arc<dyn crate::cursor::CursorSink> {
    Arc::new(crate::cursor::NoCursor)
}
