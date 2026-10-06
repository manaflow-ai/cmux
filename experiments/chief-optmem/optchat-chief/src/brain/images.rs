//! Images of a turn (chief-done.md item 12: "a Chief sees the images of its
//! turn, and its OptChat log keeps a reference and a description").
//!
//! A human message's `attachment` parts with an image type are read from the
//! conversation owner (`conversation-attachment-read`) and go to the turn's
//! agent as ACP `image` blocks next to the message text. The OptChat log
//! keeps the user line's text plus one reference per image (its SHA-256,
//! name, size and type), never the bytes; a description of each image,
//! written by the compactor's deny-all model, follows as a `note` line that
//! names the same hash, so the compactor summarizes the image from words.

use cmux_conversation::{Message, Part};
use serde_json::{Value, json};

use crate::daemon::ConversationPort;

/// Image types every vision model the Chief runs on reads.
const VIEWABLE: [&str; 4] = ["image/jpeg", "image/png", "image/gif", "image/webp"];
/// Largest original sent as is: the Messages API takes at most 5 MB of
/// base64 per image (3.75 MB of bytes), and one owner read is at most 4 MiB.
pub const MAX_ORIGINAL_BYTES: u64 = 3_750_000;

/// One image of a turn, its bytes already base64 (as the owner sends them).
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct TurnImage {
    pub hash: String,
    pub name: String,
    /// The type of the bytes in `data` (a preview is JPEG or WebP).
    pub mime_type: String,
    pub width: Option<u32>,
    pub height: Option<u32>,
    /// None when the image could not be read; the log still names it.
    pub data: Option<String>,
}

impl TurnImage {
    /// The log's reference: `[image sha256:<12 hex> "name" WxH type]`.
    pub fn reference(&self) -> String {
        let size = match (self.width, self.height) {
            (Some(w), Some(h)) => format!(" {w}x{h}"),
            _ => String::new(),
        };
        let unread = if self.data.is_none() {
            ", not readable"
        } else {
            ""
        };
        format!(
            "[image sha256:{} \"{}\"{size} {}{unread}]",
            short(&self.hash),
            self.name,
            self.mime_type
        )
    }

    /// The ACP prompt block (acpmux turns it into an Anthropic image).
    pub fn block(&self) -> Option<Value> {
        let data = self.data.as_ref()?;
        Some(json!({"type": "image", "mimeType": self.mime_type, "data": data}))
    }
}

/// The first 12 hex characters of a hash.
pub fn short(hash: &str) -> &str {
    &hash[..hash.len().min(12)]
}

/// The image parts of `message`, read from the owner: the original when the
/// model reads its type and size, else the image's preview (a JPEG of at
/// most 1024 px and 512 KB), else a reference without bytes.
pub fn read_images(port: &mut dyn ConversationPort, message: &Message) -> Vec<TurnImage> {
    let mut images = Vec::new();
    for part in &message.parts {
        let Part::Attachment {
            hash,
            name,
            mime_type,
            byte_count,
            width,
            height,
            preview,
            ..
        } = part
        else {
            continue;
        };
        if !mime_type.starts_with("image/") {
            continue;
        }
        let mut data = None;
        let mut mime = mime_type.clone();
        if VIEWABLE.contains(&mime_type.as_str()) && *byte_count <= MAX_ORIGINAL_BYTES {
            data = port
                .attachment(&message.conversation, hash, "original", *byte_count)
                .ok();
        }
        if data.is_none()
            && let Some(preview) = preview
        {
            data = port
                .attachment(&message.conversation, hash, "preview", preview.byte_count)
                .ok();
            if data.is_some() {
                mime = preview.mime_type.clone();
            }
        }
        images.push(TurnImage {
            hash: hash.clone(),
            name: name.clone(),
            mime_type: mime,
            width: *width,
            height: *height,
            data,
        });
    }
    images
}

/// The user line of a message with images: its text, then one reference
/// per image on its own line.
pub fn logged_text(text: &str, images: &[TurnImage]) -> String {
    let references: Vec<String> = images.iter().map(TurnImage::reference).collect();
    match (text.trim().is_empty(), references.is_empty()) {
        (_, true) => text.to_owned(),
        (true, false) => references.join("\n"),
        (false, false) => format!("{text}\n{}", references.join("\n")),
    }
}

/// The note line that describes an image, naming the same hash as its reference.
pub fn description_line(image: &TurnImage, description: Result<&str, &str>) -> String {
    match description {
        Ok(text) => format!(
            "image sha256:{} \"{}\" shows: {}",
            short(&image.hash),
            image.name,
            text.trim()
        ),
        Err(error) => format!(
            "image sha256:{} \"{}\": no description ({error})",
            short(&image.hash),
            image.name
        ),
    }
}

/// The prompt of a description call: the image, then the instruction.
pub fn describe_blocks(image: &TurnImage) -> Option<Vec<Value>> {
    Some(vec![
        image.block()?,
        json!({"type": "text", "text": DESCRIBE_PROMPT}),
    ])
}

/// What the description model is asked: words the compactor can summarize
/// later, without the image.
pub const DESCRIBE_PROMPT: &str = "Describe this image for a memory log that will be read without the image. \
In at most four sentences say what it is (screenshot, photo, diagram, ...), what it shows, and transcribe its \
important visible text (headings, numbers, short messages) exactly. No preamble.";

/// Writes a description of one image (the compactor's deny-all model).
pub trait Describe: Send + Sync {
    fn describe(&self, blocks: Vec<Value>) -> Result<String, String>;
}

impl super::Brain {
    /// Logs a turn image's description as a note that names its hash.
    pub(super) fn described(&mut self, image: &TurnImage, description: Result<String, String>) {
        let line = description_line(image, description.as_deref().map_err(String::as_str));
        if let Err(e) = self.chat.append(optchat_core::Kind::Note, &line) {
            (self.log)(&format!("logging an image description failed: {e}"));
        }
    }

    /// Starts one description per readable image, off the brain thread;
    /// each answer comes back as `Input::Described`.
    pub(super) fn describe_images(&self, images: &[TurnImage]) {
        let Some(describer) = self.describer.clone() else {
            return;
        };
        for image in images {
            let Some(blocks) = describe_blocks(image) else {
                continue;
            };
            let (tx, describer) = (self.tx.clone(), describer.clone());
            // The note needs the reference only, never the bytes.
            let image = TurnImage {
                data: None,
                ..image.clone()
            };
            let spawned = std::thread::Builder::new()
                .name("optchat-describe".into())
                .spawn(move || {
                    let description = describer.describe(blocks);
                    let _ = tx.send(super::Input::Described { image, description });
                });
            if let Err(e) = spawned {
                (self.log)(&format!("starting an image description failed: {e}"));
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn image(data: Option<&str>) -> TurnImage {
        TurnImage {
            hash: "0123456789abcdef".repeat(4),
            name: "shot.png".into(),
            mime_type: "image/png".into(),
            width: Some(640),
            height: Some(480),
            data: data.map(str::to_owned),
        }
    }

    #[test]
    fn the_log_keeps_a_reference_never_the_bytes() {
        let text = logged_text("what does this say?", &[image(Some("QUJD"))]);
        assert_eq!(
            text,
            "what does this say?\n[image sha256:0123456789ab \"shot.png\" 640x480 image/png]"
        );
        assert!(!text.contains("QUJD"));
        assert_eq!(
            logged_text("", &[image(None)]),
            "[image sha256:0123456789ab \"shot.png\" 640x480 image/png, not readable]"
        );
        assert_eq!(logged_text("hi", &[]), "hi");
    }

    #[test]
    fn the_block_is_an_acp_image_and_the_description_names_the_hash() {
        assert_eq!(
            image(Some("QUJD")).block(),
            Some(json!({"type":"image","mimeType":"image/png","data":"QUJD"}))
        );
        assert_eq!(image(None).block(), None);
        let blocks = describe_blocks(&image(Some("QUJD"))).unwrap();
        assert_eq!(blocks[0]["type"], "image");
        assert_eq!(blocks[1]["text"], DESCRIBE_PROMPT);
        assert_eq!(
            description_line(&image(Some("x")), Ok(" A pricing table. ")),
            "image sha256:0123456789ab \"shot.png\" shows: A pricing table."
        );
        assert!(
            description_line(&image(Some("x")), Err("timeout"))
                .ends_with("no description (timeout)")
        );
    }
}
