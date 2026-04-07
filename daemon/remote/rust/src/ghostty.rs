use std::ffi::c_void;
use std::ptr::NonNull;

#[repr(C)]
struct CaptureBuffer {
    ptr: *mut u8,
    len: usize,
}

unsafe extern "C" {
    fn cmux_ghostty_new(cols: u16, rows: u16, max_scrollback: usize) -> *mut c_void;
    fn cmux_ghostty_free(handle: *mut c_void);
    fn cmux_ghostty_feed(handle: *mut c_void, data_ptr: *const u8, data_len: usize) -> bool;
    fn cmux_ghostty_resize(handle: *mut c_void, cols: u16, rows: u16) -> bool;
    fn cmux_ghostty_capture_json(
        handle: *mut c_void,
        include_history: bool,
        out: *mut CaptureBuffer,
    ) -> bool;
    fn cmux_ghostty_buffer_free(ptr: *mut u8, len: usize);
}

#[derive(Debug, serde::Deserialize)]
struct GhosttyCaptureJson {
    cols: u16,
    rows: u16,
    cursor_x: u16,
    cursor_y: u16,
    history: String,
    visible: String,
}

#[derive(Debug, Clone)]
pub struct GhosttyCapture {
    pub cols: u16,
    pub rows: u16,
    pub cursor_x: u16,
    pub cursor_y: u16,
    pub history: String,
    pub visible: String,
}

pub struct GhosttyTerminal {
    raw: NonNull<c_void>,
}

impl GhosttyTerminal {
    pub fn new(cols: u16, rows: u16, max_scrollback: usize) -> Result<Self, String> {
        let raw = unsafe { cmux_ghostty_new(cols, rows, max_scrollback) };
        let raw = NonNull::new(raw).ok_or_else(|| "failed to initialize Ghostty VT".to_string())?;
        Ok(Self { raw })
    }

    pub fn feed(&mut self, data: &[u8]) -> Result<(), String> {
        if unsafe { cmux_ghostty_feed(self.raw.as_ptr(), data.as_ptr(), data.len()) } {
            Ok(())
        } else {
            Err("failed to feed Ghostty VT".to_string())
        }
    }

    pub fn resize(&mut self, cols: u16, rows: u16) -> Result<(), String> {
        if unsafe { cmux_ghostty_resize(self.raw.as_ptr(), cols, rows) } {
            Ok(())
        } else {
            Err("failed to resize Ghostty VT".to_string())
        }
    }

    pub fn capture(&self, include_history: bool) -> Result<GhosttyCapture, String> {
        let mut buffer = CaptureBuffer {
            ptr: std::ptr::null_mut(),
            len: 0,
        };
        if !unsafe { cmux_ghostty_capture_json(self.raw.as_ptr(), include_history, &mut buffer) } {
            return Err("failed to capture Ghostty VT state".to_string());
        }

        let bytes = if buffer.len == 0 {
            Vec::new()
        } else {
            unsafe { std::slice::from_raw_parts(buffer.ptr, buffer.len).to_vec() }
        };
        unsafe { cmux_ghostty_buffer_free(buffer.ptr, buffer.len) };

        let decoded: GhosttyCaptureJson = serde_json::from_slice(&bytes)
            .map_err(|err| format!("invalid Ghostty capture JSON: {err}"))?;
        Ok(GhosttyCapture {
            cols: decoded.cols,
            rows: decoded.rows,
            cursor_x: decoded.cursor_x,
            cursor_y: decoded.cursor_y,
            history: decoded.history,
            visible: decoded.visible,
        })
    }
}

impl Drop for GhosttyTerminal {
    fn drop(&mut self) {
        unsafe { cmux_ghostty_free(self.raw.as_ptr()) };
    }
}
