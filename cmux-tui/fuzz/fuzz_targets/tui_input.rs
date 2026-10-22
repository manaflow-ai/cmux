//! Terminal input bytes (what the host terminal sends cmux-tui on stdin)
//! through the vendored crossterm event parser, the way its reader feeds it:
//! the buffer grows one byte at a time; an event or an error clears it.
#![no_main]

use libfuzzer_sys::fuzz_target;

fuzz_target!(|data: &[u8]| {
    let mut buffer: Vec<u8> = Vec::new();
    for (index, &byte) in data.iter().enumerate() {
        buffer.push(byte);
        let more = index + 1 < data.len();
        match crossterm::event::parse_event_from_bytes(&buffer, more) {
            Ok(Some(_)) | Err(_) => buffer.clear(),
            Ok(None) => {}
        }
        if buffer.len() > 4096 {
            buffer.clear();
        }
    }
    // A pending prefix at the end of input is parsed once more without more bytes.
    let _ = crossterm::event::parse_event_from_bytes(&buffer, false);
});
