//! A hung thread's stack as the hang record carries it: return addresses mapped to an image UUID and
//! an offset, the form Sentry symbolicates (`instruction_addr` = image address + offset, and one
//! `debug_meta.images` entry per UUID). The macOS sampler (`sample_macos`) fills it; Linux
//! and Windows record no stack.

use std::fmt::Write as _;

/// One frame, innermost first.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct StackFrame {
    /// The program counter (frame 0) or a return address, with any pointer-authentication bits
    /// removed.
    pub address: u64,
    /// The index of the frame's image in [`Stack::images`], when the address is in a loaded image.
    pub image: Option<u32>,
}

/// One loaded image a frame points into.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct StackImage {
    /// The image's `LC_UUID` (the Sentry debug id).
    pub uuid: [u8; 16],
    /// Where its Mach-O header is mapped.
    pub load_address: u64,
    /// The size of its `__TEXT` segment.
    pub size: u64,
    /// The image's file name, without its directory (a directory can hold the person's name).
    pub name: String,
}

impl StackImage {
    /// The UUID as Sentry's debug id: lowercase, hyphenated 8-4-4-4-12.
    pub fn debug_id(&self) -> String {
        let mut id = String::with_capacity(36);
        for (index, byte) in self.uuid.iter().enumerate() {
            if matches!(index, 4 | 6 | 8 | 10) {
                id.push('-');
            }
            let _ = write!(id, "{byte:02x}");
        }
        id
    }

    pub fn contains(&self, address: u64) -> bool {
        address >= self.load_address && address - self.load_address < self.size
    }
}

/// A sampled stack.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Stack {
    pub frames: Vec<StackFrame>,
    /// Each image a frame points into, once.
    pub images: Vec<StackImage>,
    /// The walk stopped at the frame cap, not at the stack's base.
    pub truncated: bool,
}

impl Stack {
    /// The frame's offset into its image, when it has one.
    pub fn offset(&self, frame: &StackFrame) -> Option<u64> {
        let image = self.images.get(usize::try_from(frame.image?).ok()?)?;
        Some(frame.address - image.load_address)
    }

    /// The `"stack":{...}` member of a hang line, comma first.
    pub(crate) fn push_json(&self, out: &mut String) {
        let _ = write!(out, ",\"stack\":{{\"truncated\":{},\"frames\":[", self.truncated);
        for (index, frame) in self.frames.iter().enumerate() {
            if index > 0 {
                out.push(',');
            }
            let _ = write!(out, "{{\"addr\":{}", frame.address);
            if let (Some(image), Some(offset)) = (frame.image, self.offset(frame)) {
                let _ = write!(out, ",\"image\":{image},\"offset\":{offset}");
            }
            out.push('}');
        }
        out.push_str("],\"images\":[");
        for (index, image) in self.images.iter().enumerate() {
            if index > 0 {
                out.push(',');
            }
            let _ = write!(
                out,
                "{{\"uuid\":\"{}\",\"addr\":{},\"size\":{},\"name\":",
                image.debug_id(),
                image.load_address,
                image.size,
            );
            crate::push_json_string(out, &image.name);
            out.push('}');
        }
        out.push_str("]}");
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn image() -> StackImage {
        StackImage {
            uuid: [
                0x01, 0x23, 0x45, 0x67, 0x89, 0xab, 0xcd, 0xef, 0x10, 0x32, 0x54, 0x76, 0x98, 0xba,
                0xdc, 0xfe,
            ],
            load_address: 0x1000,
            size: 0x100,
            name: "cmux-tui".into(),
        }
    }

    #[test]
    fn debug_id_is_hyphenated_lowercase() {
        assert_eq!(image().debug_id(), "01234567-89ab-cdef-1032-547698badcfe");
    }

    #[test]
    fn stack_json_maps_frames_to_image_offsets() {
        let stack = Stack {
            frames: vec![
                StackFrame { address: 0x1010, image: Some(0) },
                StackFrame { address: 0x9000, image: None },
            ],
            images: vec![image()],
            truncated: false,
        };
        assert!(stack.images[0].contains(0x10ff));
        assert!(!stack.images[0].contains(0x1100));
        assert_eq!(stack.offset(&stack.frames[0]), Some(0x10));
        let mut json = String::new();
        stack.push_json(&mut json);
        assert_eq!(
            json,
            ",\"stack\":{\"truncated\":false,\"frames\":[{\"addr\":4112,\"image\":0,\"offset\":16},\
             {\"addr\":36864}],\"images\":[{\"uuid\":\"01234567-89ab-cdef-1032-547698badcfe\",\
             \"addr\":4096,\"size\":256,\"name\":\"cmux-tui\"}]}"
        );
    }
}
