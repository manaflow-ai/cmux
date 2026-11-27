//! The chat attachment cache's rules (`HomeAttachmentCache`): each variant's file name, where a
//! thumbnail comes from, and which files go when the cache is over its limit. Swift reads the daemon,
//! writes the files and makes the JPEG; the file extension comes from `UTType`, so Swift passes it.

use crate::ops::{OpError, parse, reply};
use serde::Deserialize;
use serde_json::{Value, json};

#[derive(Debug, Clone, Copy, PartialEq, Eq, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum Variant {
    Original,
    Poster,
    Preview,
    Thumbnail,
}

#[derive(Debug, Clone, Default, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct NameRequest {
    pub hash: String,
    pub variant: Option<Variant>,
    /// `UTType(mimeType:)?.preferredFilenameExtension` for the variant's type, without the dot.
    pub extension: Option<String>,
    pub has_poster: bool,
    pub has_preview: bool,
    pub max_pixel: i64,
}

/// The cached file's name, or the rejection (`no_poster`, `no_preview`).
pub fn file_name(req: &NameRequest) -> Result<String, &'static str> {
    let suffix = req
        .extension
        .as_deref()
        .filter(|e| !e.is_empty())
        .map(|e| format!(".{e}"))
        .unwrap_or_default();
    match req.variant.unwrap_or(Variant::Original) {
        Variant::Original => Ok(format!("{}-original{suffix}", req.hash)),
        Variant::Poster if req.has_poster => Ok(format!("{}-poster{suffix}", req.hash)),
        Variant::Poster => Err("no_poster"),
        Variant::Preview if req.has_preview => Ok(format!("{}-preview{suffix}", req.hash)),
        Variant::Preview => Err("no_preview"),
        Variant::Thumbnail => Ok(format!("{}-thumb-{}.jpg", req.hash, req.max_pixel)),
    }
}

/// A thumbnail is made from the original when it is an image, else from the poster.
pub fn thumbnail_source(mime_type: &str, has_poster: bool) -> Result<&'static str, &'static str> {
    if mime_type.starts_with("image/") {
        Ok("original")
    } else if has_poster {
        Ok("poster")
    } else {
        Err("no_thumbnail")
    }
}

#[derive(Debug, Clone, Default, Deserialize)]
#[serde(rename_all = "camelCase", default)]
pub struct CacheFile {
    /// The standardized path.
    pub path: String,
    /// Last use (modification date) in seconds since 1970; none sorts first.
    pub used: Option<f64>,
    pub size: i64,
    #[serde(default = "yes")]
    pub regular: bool,
    pub hidden: bool,
}

fn yes() -> bool {
    true
}

/// `trim(keeping:)`: over the limit, the least recently used files go (never `kept`) until it fits.
/// The plan assumes each removal succeeds; Swift stops counting one that fails.
pub fn trim(files: &[CacheFile], limit: i64, kept: &str) -> Vec<String> {
    let mut entries: Vec<&CacheFile> = files.iter().filter(|f| f.regular && !f.hidden).collect();
    let mut total: i64 = entries.iter().map(|f| f.size).sum();
    if total <= limit {
        return Vec::new();
    }
    entries.sort_by(|a, b| {
        a.used
            .unwrap_or(f64::NEG_INFINITY)
            .partial_cmp(&b.used.unwrap_or(f64::NEG_INFINITY))
            .unwrap_or(std::cmp::Ordering::Equal)
    });
    let mut remove = Vec::new();
    for entry in entries {
        if total <= limit {
            break;
        }
        if entry.path == kept {
            continue;
        }
        remove.push(entry.path.clone());
        total -= entry.size;
    }
    remove
}

#[derive(Default, Deserialize)]
#[serde(rename_all = "camelCase", default)]
struct TrimRequest {
    files: Vec<CacheFile>,
    limit: i64,
    kept: String,
}

pub fn call(name: &str, request: &Value) -> Result<Value, OpError> {
    match name {
        "attachmentFileName" => {
            let req: NameRequest = parse(request)?;
            match file_name(&req) {
                Ok(name) => reply(&json!({"name": name, "error": null})),
                Err(error) => reply(&json!({"name": null, "error": error})),
            }
        }
        "attachmentThumbnailSource" => {
            #[derive(Default, Deserialize)]
            #[serde(rename_all = "camelCase", default)]
            struct Req {
                mime_type: String,
                has_poster: bool,
            }
            let req: Req = parse(request)?;
            match thumbnail_source(&req.mime_type, req.has_poster) {
                Ok(source) => reply(&json!({"source": source, "error": null})),
                Err(error) => reply(&json!({"source": null, "error": error})),
            }
        }
        "attachmentTrim" => {
            let req: TrimRequest = parse(request)?;
            reply(&json!({"remove": trim(&req.files, req.limit, &req.kept)}))
        }
        _ => Err(OpError::Unknown),
    }
}
