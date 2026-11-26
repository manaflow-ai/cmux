//! The Chief's picture: the crop editor's square (`HomeChiefPictureCrop.swift`), the registry's media types
//! (`HomeChiefAvatars.swift`, `ChiefAvatarPicture.swift`) and the picture file rules (`HomeChiefFiles.swift`).
//! Decoding and drawing the image stay in Swift (ImageIO); these are the numbers and names.

use crate::ops::{self, OpError};
use serde::{Deserialize, Serialize};
use serde_json::{Map, Value};

pub const MAXIMUM_ZOOM: f64 = 5.0;
pub const OUTPUT_PIXELS: i64 = 512;
pub const EDITOR_PIXELS: i64 = 2048;
/// The registry's picture cap (`chief.profile.avatar.set`), also the largest GIF kept as it is.
pub const MAXIMUM_BYTES: u64 = 1024 * 1024;
/// The picture files a profile may name.
pub const PICTURE_EXTENSIONS: &[&str] = &["png", "jpg", "jpeg", "heic", "gif", "webp"];

/// A size in points or pixels.
#[derive(Debug, Clone, Copy, Default, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct Size {
    pub width: f64,
    pub height: f64,
}

/// A point.
#[derive(Debug, Clone, Copy, Default, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct Point {
    pub x: f64,
    pub y: f64,
}

/// A rectangle.
#[derive(Debug, Clone, Copy, Default, PartialEq, Serialize, Deserialize)]
#[serde(default)]
pub struct Rect {
    pub x: f64,
    pub y: f64,
    pub width: f64,
    pub height: f64,
}

/// The square of a picture the Chief keeps: a zoom of 1 to 5 and a centre in the image's points.
#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct Crop {
    pub image_size: Size,
    pub zoom: f64,
    pub center: Point,
}

/// One change to a [`Crop`].
#[derive(Debug, Clone, Copy, PartialEq, Deserialize)]
#[serde(tag = "kind", rename_all = "camelCase")]
pub enum CropEvent {
    /// Starts over for an image of `imageSize`.
    #[serde(rename_all = "camelCase")]
    Start { image_size: Size },
    /// Sets the zoom (clamped to 1 to 5).
    Zoom { zoom: f64 },
    /// A drag of `delta` points across a disc `diameter` points wide: the picture follows the finger.
    Pan { delta: Size, diameter: f64 },
}

impl Crop {
    pub fn new(image_size: Size) -> Crop {
        Crop {
            image_size,
            zoom: 1.0,
            center: Point { x: image_size.width / 2.0, y: image_size.height / 2.0 },
        }
    }

    /// The square's side in the image's points.
    pub fn side(&self) -> f64 {
        self.image_size.width.min(self.image_size.height) / self.zoom
    }

    /// The square, in the image's points.
    pub fn rect(&self) -> Rect {
        let side = self.side();
        Rect {
            x: self.center.x - side / 2.0,
            y: self.center.y - side / 2.0,
            width: side,
            height: side,
        }
    }

    fn clamp(&mut self) {
        let half = self.side() / 2.0;
        self.center.x = self.center.x.max(half).min((self.image_size.width - half).max(half));
        self.center.y = self.center.y.max(half).min((self.image_size.height - half).max(half));
    }

    pub fn step(mut self, event: &CropEvent) -> Crop {
        match *event {
            CropEvent::Start { image_size } => return Crop::new(image_size),
            CropEvent::Zoom { zoom } => {
                self.zoom = zoom.clamp(1.0, MAXIMUM_ZOOM);
                self.clamp();
            }
            CropEvent::Pan { delta, diameter } => {
                if diameter > 0.0 {
                    let pixels_per_point = self.side() / diameter;
                    self.center.x -= delta.width * pixels_per_point;
                    self.center.y += delta.height * pixels_per_point;
                    self.clamp();
                }
            }
        }
        self
    }
}

/// What the render draws: the source square in the image's pixels (made integral and cut to the image,
/// as `CGImage.cropping` does) and the output's side.
#[derive(Debug, Clone, Copy, PartialEq, Serialize)]
pub struct Render {
    pub source: Rect,
    pub pixels: i64,
}

/// The render of `crop` from an image of `width` by `height` pixels; nil when the square misses it.
pub fn render(crop: &Crop, width: i64, height: i64) -> Option<Render> {
    let scale_x = width as f64 / crop.image_size.width.max(1.0);
    let scale_y = height as f64 / crop.image_size.height.max(1.0);
    let rect = crop.rect();
    let (min_x, min_y) = ((rect.x * scale_x).floor(), (rect.y * scale_y).floor());
    let max_x = ((rect.x + rect.width) * scale_x).ceil();
    let max_y = ((rect.y + rect.height) * scale_y).ceil();
    let (x0, y0) = (min_x.max(0.0), min_y.max(0.0));
    let (x1, y1) = (max_x.min(width as f64), max_y.min(height as f64));
    if x1 <= x0 || y1 <= y0 {
        return None;
    }
    let source = Rect { x: x0, y: y0, width: x1 - x0, height: y1 - y0 };
    Some(Render { source, pixels: OUTPUT_PIXELS.min((source.width as i64).max(1)) })
}

/// The media type the registry keeps for a picture whose bytes start with `head` and run `length` bytes:
/// PNG, JPEG, GIF or WebP, at most 1 MiB; nil for anything else.
pub fn registry_media_type(head: &[u8], length: u64) -> Option<&'static str> {
    if length > MAXIMUM_BYTES {
        return None;
    }
    if head.starts_with(&[0x89, 0x50, 0x4E, 0x47]) {
        return Some("image/png");
    }
    if head.starts_with(&[0xFF, 0xD8, 0xFF]) {
        return Some("image/jpeg");
    }
    if head.starts_with(&[0x47, 0x49, 0x46, 0x38]) {
        return Some("image/gif");
    }
    if head.len() >= 12
        && head.starts_with(&[0x52, 0x49, 0x46, 0x46])
        && head[8..12] == [0x57, 0x45, 0x42, 0x50]
    {
        return Some("image/webp");
    }
    None
}

/// The file extension for a media type.
pub fn picture_extension(media_type: &str) -> &'static str {
    match media_type {
        "image/jpeg" => "jpg",
        "image/gif" => "gif",
        "image/webp" => "webp",
        _ => "png",
    }
}

/// The file a picture of `media_type` is kept as beside profile.json.
pub fn picture_file_name(media_type: &str) -> &'static str {
    if media_type == "image/gif" { "avatar.gif" } else { "avatar.png" }
}

/// `name`'s path extension, as `NSString.pathExtension` reads it (none for `.png` alone).
fn path_extension(name: &str) -> &str {
    let last = name.rsplit('/').next().unwrap_or(name);
    match last.rsplit_once('.') {
        Some((stem, ext)) if !stem.is_empty() => ext,
        _ => "",
    }
}

/// Whether an avatar value names a picture rather than text: a file name (no path) with an image extension.
pub fn names_picture(avatar: &str) -> bool {
    !avatar.contains('/')
        && PICTURE_EXTENSIONS.contains(&path_extension(avatar).to_lowercase().as_str())
}

/// A stable short key of `path` (FNV-1a 32, as `ChiefHome.host` keys a mux home).
pub fn path_key(path: &str) -> String {
    let mut hash: u32 = 0x811c_9dc5;
    for byte in path.bytes() {
        hash ^= u32::from(byte);
        hash = hash.wrapping_mul(0x0100_0193);
    }
    format!("{hash:08x}")
}

/// The centred square of a `width` by `height` picture; nil when it is square already.
pub fn square_crop(width: i64, height: i64) -> Option<Rect> {
    if width == height {
        return None;
    }
    let side = width.min(height);
    Some(Rect {
        x: ((width - side) / 2) as f64,
        y: ((height - side) / 2) as f64,
        width: side as f64,
        height: side as f64,
    })
}

/// The cached square copy's file name for the picture at `path`, modified at `stamp` (seconds).
pub fn squared_cache_name(path: &str, stamp: i64) -> String {
    let last = path.trim_end_matches('/').rsplit('/').next().unwrap_or(path);
    let stem = match last.rsplit_once('.') {
        Some((stem, _)) if !stem.is_empty() => stem,
        _ => last,
    };
    format!("{}-{stem}-{stamp}.png", path_key(path))
}

// MARK: Ops

#[derive(Deserialize, Default)]
#[serde(default)]
struct StepRequest {
    state: Option<Crop>,
    event: Option<CropEvent>,
}

#[derive(Deserialize, Default)]
#[serde(default)]
struct RenderRequest {
    crop: Option<Crop>,
    width: i64,
    height: i64,
}

#[derive(Deserialize, Default)]
#[serde(default)]
struct BytesRequest {
    head: Vec<u8>,
    length: Option<u64>,
}

#[derive(Deserialize, Default)]
#[serde(default, rename_all = "camelCase")]
struct MediaRequest {
    media_type: String,
}

#[derive(Deserialize, Default)]
#[serde(default)]
struct AvatarRequest {
    avatar: String,
}

#[derive(Deserialize, Default)]
#[serde(default)]
struct PathRequest {
    path: String,
    stamp: i64,
}

#[derive(Deserialize, Default)]
#[serde(default)]
struct SizeRequest {
    width: i64,
    height: i64,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
struct CropReply {
    #[serde(flatten)]
    crop: Crop,
    side: f64,
    rect: Rect,
}

fn object(request: &Value) -> Value {
    if request.is_null() { Value::Object(Map::new()) } else { request.clone() }
}

pub(super) fn call(name: &str, request: &Value) -> Result<Value, OpError> {
    let request = &object(request);
    match name {
        "cropStep" => {
            let request: StepRequest = ops::parse(request)?;
            let mut crop = request.state.unwrap_or_else(|| Crop::new(Size::default()));
            if let Some(event) = &request.event {
                crop = crop.step(event);
            }
            ops::reply(&CropReply { crop, side: crop.side(), rect: crop.rect() })
        }
        "cropRender" => {
            let request: RenderRequest = ops::parse(request)?;
            let crop = request.crop.unwrap_or_else(|| Crop::new(Size::default()));
            ops::reply(&render(&crop, request.width, request.height))
        }
        "registryMediaType" => {
            let request: BytesRequest = ops::parse(request)?;
            let length = request.length.unwrap_or(request.head.len() as u64);
            ops::reply(&registry_media_type(&request.head, length))
        }
        "pictureExtension" => {
            ops::reply(&picture_extension(&ops::parse::<MediaRequest>(request)?.media_type))
        }
        "pictureFileName" => {
            ops::reply(&picture_file_name(&ops::parse::<MediaRequest>(request)?.media_type))
        }
        "namesPicture" => ops::reply(&names_picture(&ops::parse::<AvatarRequest>(request)?.avatar)),
        "pathKey" => ops::reply(&path_key(&ops::parse::<PathRequest>(request)?.path)),
        "squareCrop" => {
            let request: SizeRequest = ops::parse(request)?;
            ops::reply(&square_crop(request.width, request.height))
        }
        "squaredCacheName" => {
            let request: PathRequest = ops::parse(request)?;
            ops::reply(&squared_cache_name(&request.path, request.stamp))
        }
        _ => Err(OpError::Unknown),
    }
}
