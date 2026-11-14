//! Firefox's mozLz4 files (`FirefoxSessionReader.decompress`): the magic `mozLz40\0`, a
//! little-endian uint32 decompressed size, then one raw LZ4 block.
//!
//! The Swift reader decoded the block with Apple's `compression_decode_buffer`
//! (`COMPRESSION_LZ4_RAW`) into a buffer of exactly the stated size and kept the result only when
//! it filled that buffer. [`block`] decodes the same way: it stops once the output is full, and a
//! block that ends early, or a match that points before the output's start, is no result.

const MAGIC: &[u8; 8] = b"mozLz40\0";
/// Files above this decompressed size are not read (a sane upper bound).
pub const MAXIMUM_SIZE: usize = 256 * 1024 * 1024;

/// The JSON inside a mozLz4 file, or `None` when it is not one or does not decode.
pub fn decompress(data: &[u8]) -> Option<Vec<u8>> {
    if data.len() <= 12 || data.get(..8)? != MAGIC {
        return None;
    }
    let size = usize::try_from(crate::pickle::uint32(data, 8)?).ok()?;
    if size == 0 || size > MAXIMUM_SIZE {
        return None;
    }
    block(data.get(12..)?, size)
}

/// An LZ4 length: the token's nibble, plus each following byte while the bytes are 255.
fn length(nibble: u8, input: &[u8], at: &mut usize) -> Option<usize> {
    let mut total = usize::from(nibble);
    if nibble == 15 {
        loop {
            let byte = *input.get(*at)?;
            *at = at.checked_add(1)?;
            total = total.checked_add(usize::from(byte))?;
            if byte != 255 {
                break;
            }
        }
    }
    Some(total)
}

/// Decodes a raw LZ4 block into exactly `size` bytes.
pub fn block(input: &[u8], size: usize) -> Option<Vec<u8>> {
    let mut output: Vec<u8> = Vec::with_capacity(size);
    let mut at = 0usize;
    while output.len() < size {
        let token = *input.get(at)?;
        at = at.checked_add(1)?;
        let literals = length(token >> 4, input, &mut at)?;
        let end = at.checked_add(literals)?;
        let room = size.saturating_sub(output.len());
        match input.get(at..end) {
            Some(run) => output.extend_from_slice(run.get(..room.min(run.len()))?),
            // A cut-off run still fills the output when the output is full first.
            None => {
                let run = input.get(at..)?;
                if run.len() < room {
                    return None;
                }
                output.extend_from_slice(run.get(..room)?);
            }
        }
        at = end;
        if output.len() >= size || at >= input.len() {
            break;
        }
        let offset =
            usize::from(u16::from_le_bytes([*input.get(at)?, *input.get(at.checked_add(1)?)?]));
        at = at.checked_add(2)?;
        let matched = length(token & 0x0F, input, &mut at)?.checked_add(4)?;
        if offset == 0 || offset > output.len() {
            return None;
        }
        let mut from = output.len().checked_sub(offset)?;
        for _ in 0..matched {
            if output.len() >= size {
                break;
            }
            let byte = *output.get(from)?;
            output.push(byte);
            from = from.checked_add(1)?;
        }
    }
    (output.len() == size).then_some(output)
}
