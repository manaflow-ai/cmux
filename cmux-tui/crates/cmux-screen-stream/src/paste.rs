//! Paste an image from the viewer into the Mac. The viewer sends the image's bytes as ordered
//! `paste-image` messages on the input channel; the Mac puts the image on its pasteboard, presses
//! Command-V and answers with one `paste-image` host message. Only a host whose `caps` lists
//! `paste-image` takes it, and never in a view-only session.
//!
//! One message: `{"t":"paste-image","id":"...","i":0,"n":12,"f":"public.png","s":"<base64>"}`.

use crate::wire::{
    PASTE_IMAGE_CAPABILITY, PASTE_IMAGE_TYPE, PasteImageOutcome, ScreenHostMessage, ScreenInput,
};
use base64::Engine;
use base64::engine::general_purpose::STANDARD;

/// Raw bytes per chunk: 16 KB as base64, the data channel's message size.
pub const CHUNK_BYTES: usize = 12 * 1024;
/// The largest image the host takes (bytes before base64).
pub const MAXIMUM_BYTES: usize = 20 << 20;
/// The image types the host puts on its pasteboard (uniform type identifiers).
pub const TYPES: [&str; 4] = ["public.png", "public.jpeg", "public.heic", "public.tiff"];
const MAXIMUM_CHUNKS: i64 = MAXIMUM_BYTES.div_ceil(CHUNK_BYTES) as i64;

/// The messages for one image (empty when it is empty, too large or of another type).
pub fn chunks(data: &[u8], image_type: &str, id: &str) -> Vec<ScreenInput> {
    if data.is_empty() || data.len() > MAXIMUM_BYTES || !TYPES.contains(&image_type) {
        return Vec::new();
    }
    let count = data.len().div_ceil(CHUNK_BYTES) as i64;
    data.chunks(CHUNK_BYTES)
        .enumerate()
        .map(|(index, chunk)| ScreenInput {
            s: Some(STANDARD.encode(chunk)),
            i: Some(index as i64),
            n: Some(count),
            id: Some(id.to_owned()),
            f: Some(image_type.to_owned()),
            ..ScreenInput::new(PASTE_IMAGE_TYPE)
        })
        .collect()
}

/// What one chunk did.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Step {
    /// Kept; more to come.
    Partial,
    /// The last chunk: the whole image.
    Complete { data: Vec<u8>, image_type: String, id: String },
    /// Dropped (the answer to send, about the image `id`).
    Failed { outcome: PasteImageOutcome, id: Option<String> },
    /// A later chunk of an image already answered as failed: no second answer.
    Ignored,
}

/// The host's side of an image paste: collects one image's chunks in order. A chunk out of order,
/// or from another image, drops what it had.
#[derive(Clone, Debug, Default)]
pub struct Assembler {
    id: Option<String>,
    failed_id: Option<String>,
    image_type: String,
    expected: i64,
    count: i64,
    data: Vec<u8>,
}

impl Assembler {
    pub fn new() -> Self {
        Self::default()
    }

    pub fn take(&mut self, input: &ScreenInput) -> Step {
        if let Some(failed) = &self.failed_id
            && input.id.as_ref() == Some(failed)
            && input.i != Some(0)
        {
            return Step::Ignored;
        }
        let (Some(id), Some(index), Some(count), Some(image_type), Some(chunk)) = (
            input.id.clone(),
            input.i,
            input.n,
            input.f.clone(),
            input.s.as_deref().and_then(|s| STANDARD.decode(s).ok()),
        ) else {
            return self.fail(PasteImageOutcome::Incomplete, input.id.clone());
        };
        if !TYPES.contains(&image_type.as_str())
            || !(1..=MAXIMUM_CHUNKS).contains(&count)
            || chunk.len() > CHUNK_BYTES
        {
            return self.fail(PasteImageOutcome::Refused, Some(id));
        }
        if index == 0 {
            self.failed_id = None;
            self.id = Some(id.clone());
            self.image_type.clone_from(&image_type);
            self.count = count;
            self.expected = 0;
            self.data = Vec::new();
        }
        if self.id.as_ref() != Some(&id)
            || index != self.expected
            || count != self.count
            || image_type != self.image_type
        {
            return self.fail(PasteImageOutcome::Incomplete, Some(id));
        }
        self.data.extend_from_slice(&chunk);
        if self.data.len() > MAXIMUM_BYTES {
            return self.fail(PasteImageOutcome::Refused, Some(id));
        }
        self.expected += 1;
        if self.expected != count {
            return Step::Partial;
        }
        let data = std::mem::take(&mut self.data);
        self.reset();
        Step::Complete { data, image_type, id }
    }

    fn fail(&mut self, outcome: PasteImageOutcome, id: Option<String>) -> Step {
        self.reset();
        self.failed_id.clone_from(&id);
        Step::Failed { outcome, id }
    }

    fn reset(&mut self) {
        self.id = None;
        self.image_type.clear();
        self.expected = 0;
        self.count = 0;
        self.data = Vec::new();
    }
}

/// What the host does with one `paste-image` chunk before the backend pastes.
#[derive(Clone, Debug, PartialEq)]
pub enum ChunkAnswer {
    /// Nothing to send yet.
    Wait,
    /// Send this answer.
    Answer(ScreenHostMessage),
    /// The whole image: paste it, then answer `pasted` or `refused` about `id`.
    Paste { data: Vec<u8>, image_type: String, id: String },
}

/// One chunk: a view-only session, or a backend that does not paste images, refuses every image
/// (once, at chunk 0); otherwise the assembler's step.
pub fn take_chunk(
    assembler: &mut Assembler,
    input: &ScreenInput,
    view_only: bool,
    backend_capabilities: &[String],
) -> ChunkAnswer {
    if view_only || !backend_capabilities.iter().any(|c| c == PASTE_IMAGE_CAPABILITY) {
        return if input.i == Some(0) {
            ChunkAnswer::Answer(ScreenHostMessage::paste_image(
                PasteImageOutcome::Refused,
                input.id.clone(),
            ))
        } else {
            ChunkAnswer::Wait
        };
    }
    match assembler.take(input) {
        Step::Partial | Step::Ignored => ChunkAnswer::Wait,
        Step::Failed { outcome, id } => {
            ChunkAnswer::Answer(ScreenHostMessage::paste_image(outcome, id))
        }
        Step::Complete { data, image_type, id } => ChunkAnswer::Paste { data, image_type, id },
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn chunks_round_trip_through_the_assembler() {
        let image: Vec<u8> = (0..(CHUNK_BYTES * 2 + 5)).map(|i| (i % 251) as u8).collect();
        let messages = chunks(&image, "public.png", "img");
        assert_eq!(messages.len(), 3);
        assert_eq!(messages[2].n, Some(3));
        let mut a = Assembler::new();
        assert_eq!(a.take(&messages[0]), Step::Partial);
        assert_eq!(a.take(&messages[1]), Step::Partial);
        assert_eq!(
            a.take(&messages[2]),
            Step::Complete { data: image, image_type: "public.png".into(), id: "img".into() }
        );
    }

    #[test]
    fn chunks_refuse_empty_large_or_unknown_images() {
        assert!(chunks(&[], "public.png", "a").is_empty());
        assert!(chunks(&[1], "public.gif", "a").is_empty());
        assert!(chunks(&vec![0; MAXIMUM_BYTES + 1], "public.png", "a").is_empty());
    }

    #[test]
    fn a_missing_chunk_fails_once_and_ignores_the_rest() {
        let image = vec![7u8; CHUNK_BYTES * 3];
        let messages = chunks(&image, "public.jpeg", "x");
        let mut a = Assembler::new();
        assert_eq!(a.take(&messages[0]), Step::Partial);
        assert_eq!(
            a.take(&messages[2]),
            Step::Failed { outcome: PasteImageOutcome::Incomplete, id: Some("x".into()) }
        );
        assert_eq!(a.take(&messages[1]), Step::Ignored);
        // A restart at chunk 0 takes it again.
        assert_eq!(a.take(&messages[0]), Step::Partial);
    }

    #[test]
    fn bad_type_or_count_is_refused_and_a_missing_field_incomplete() {
        let mut m = chunks(&[1, 2, 3], "public.png", "y").remove(0);
        m.f = Some("public.gif".into());
        let mut a = Assembler::new();
        assert_eq!(
            a.take(&m),
            Step::Failed { outcome: PasteImageOutcome::Refused, id: Some("y".into()) }
        );
        m.f = Some("public.png".into());
        m.n = Some(MAXIMUM_CHUNKS + 1);
        assert_eq!(
            a.take(&m),
            Step::Failed { outcome: PasteImageOutcome::Refused, id: Some("y".into()) }
        );
        m.n = Some(1);
        m.s = Some("not base64!".into());
        assert_eq!(
            a.take(&m),
            Step::Failed { outcome: PasteImageOutcome::Incomplete, id: Some("y".into()) }
        );
    }

    #[test]
    fn a_view_only_or_incapable_host_refuses_at_chunk_zero_only() {
        let messages = chunks(&vec![1; CHUNK_BYTES + 1], "public.png", "z");
        let mut a = Assembler::new();
        let caps = vec![PASTE_IMAGE_CAPABILITY.to_owned()];
        let refused = ChunkAnswer::Answer(ScreenHostMessage::paste_image(
            PasteImageOutcome::Refused,
            Some("z".into()),
        ));
        assert_eq!(take_chunk(&mut a, &messages[0], true, &caps), refused);
        assert_eq!(take_chunk(&mut a, &messages[1], true, &caps), ChunkAnswer::Wait);
        assert_eq!(take_chunk(&mut a, &messages[0], false, &[]), refused);
        assert_eq!(take_chunk(&mut a, &messages[0], false, &caps), ChunkAnswer::Wait);
        assert!(matches!(
            take_chunk(&mut a, &messages[1], false, &caps),
            ChunkAnswer::Paste { .. }
        ));
    }
}
