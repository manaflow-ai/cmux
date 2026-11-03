//! Incremental paste encoding on the session's single ordered writer.

use std::io::{self, Write};

/// Bounds the encoded working buffer, not the logical paste. Each character
/// becomes a key-down/key-up pair (16 bytes), so a pair never straddles batches.
const CHUNK_BYTES: usize = 16 * 1024;

pub(crate) fn write(
    writer: &mut dyn Write,
    text: &str,
    mut refresh: impl FnMut(&mut dyn Write) -> io::Result<()>,
) -> io::Result<()> {
    let mut batch = Vec::with_capacity(CHUNK_BYTES);
    for c in text.chars().filter(|&c| c != '\r') {
        let keysym = crate::keysym::char_keysym(c).to_be_bytes();
        for down in [1, 0] {
            batch.extend_from_slice(&[4, down, 0, 0]);
            batch.extend_from_slice(&keysym);
        }
        if batch.len() == CHUNK_BYTES {
            flush(writer, &mut batch)?;
            // A framebuffer request may pass between complete key pairs; later
            // user input remains behind the logical paste.
            refresh(writer)?;
        }
    }
    flush(writer, &mut batch)?;
    refresh(writer)?;

    // Send keys first: the first text reaches the application without waiting
    // for a complete clipboard transfer or even a scan of the full string.
    // Classic RFB replaces (never appends to) its Latin-1 clipboard, so multiple
    // ClientCutText messages cannot represent a clipboard larger than u32.
    let Ok(length) = u32::try_from(text.chars().count()) else {
        eprintln!("cmux-vnc: full paste typed; text exceeds the RFB clipboard length field");
        return Ok(());
    };
    writer.write_all(&[6, 0, 0, 0])?;
    writer.write_all(&length.to_be_bytes())?;
    for c in text.chars() {
        batch.push(u8::try_from(u32::from(c)).unwrap_or(b'?'));
        if batch.len() == CHUNK_BYTES {
            flush(writer, &mut batch)?;
        }
    }
    flush(writer, &mut batch)
}

fn flush(writer: &mut dyn Write, batch: &mut Vec<u8>) -> io::Result<()> {
    if !batch.is_empty() {
        writer.write_all(batch)?;
        writer.flush()?;
        batch.clear();
    }
    Ok(())
}
