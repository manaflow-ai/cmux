//! Screenshots (`Page.captureScreenshot`).

use super::driver::Inner;
use crate::protocol::{DriverError, timeout_of};
use serde_json::{Value, json};
use std::time::Instant;

impl Inner {
    pub(super) fn screenshot(&self, params: &Value) -> Result<Value, DriverError> {
        let session = self.session(params)?;
        let deadline = Instant::now() + timeout_of(params);
        let format = match params.get("format").and_then(Value::as_str) {
            None | Some("png") => "png",
            Some("jpeg") => "jpeg",
            Some("webp") => "webp",
            Some(other) => {
                return Err(DriverError::invalid(format!(
                    "format: expected png, jpeg or webp, got {other:?}"
                )));
            }
        };
        let mut args = json!({"format": format, "fromSurface": true});
        if format != "png"
            && let Some(quality) = params.get("quality").and_then(Value::as_f64)
        {
            args["quality"] = json!(quality.clamp(0.0, 100.0) as i64);
        }
        let mut size: Option<(f64, f64)> = None;
        if let Some(clip) = params.get("clip").filter(|clip| clip.is_object()) {
            let read = |name: &str| clip.get(name).and_then(Value::as_f64).unwrap_or(0.0);
            let (width, height) = (read("width"), read("height"));
            if width <= 0.0 || height <= 0.0 {
                return Err(DriverError::invalid("clip: width and height must be positive"));
            }
            // CDP clips are in document coordinates; the protocol's are viewport ones.
            let metrics =
                self.send_until(&session, "Page.getLayoutMetrics", json!({}), deadline)?;
            let page_x = metrics["cssVisualViewport"]["pageX"].as_f64().unwrap_or(0.0);
            let page_y = metrics["cssVisualViewport"]["pageY"].as_f64().unwrap_or(0.0);
            args["clip"] = json!({"x": read("x") + page_x, "y": read("y") + page_y, "width": width, "height": height, "scale": 1});
            size = Some((width, height));
        } else if params.get("fullPage").and_then(Value::as_bool) == Some(true) {
            let metrics =
                self.send_until(&session, "Page.getLayoutMetrics", json!({}), deadline)?;
            let content = &metrics["cssContentSize"];
            let width = content["width"].as_f64().unwrap_or(0.0).ceil();
            let height = content["height"].as_f64().unwrap_or(0.0).ceil();
            args["clip"] = json!({"x": 0, "y": 0, "width": width, "height": height, "scale": 1});
            args["captureBeyondViewport"] = json!(true);
            size = Some((width, height));
        }
        let shot = self.send_until(&session, "Page.captureScreenshot", args, deadline)?;
        let data = shot
            .get("data")
            .and_then(Value::as_str)
            .ok_or_else(|| DriverError::invalid("Page.captureScreenshot returned no data"))?;
        let (width, height) = png_size(data)
            .map(|(w, h)| (f64::from(w), f64::from(h)))
            .or(size)
            .unwrap_or_else(|| {
                self.lock()
                    .tabs
                    .get(&session.target_id)
                    .map(|tab| tab.viewport)
                    .unwrap_or((0.0, 0.0))
            });
        Ok(json!({"base64": data, "width": width, "height": height}))
    }
}

/// Width and height from a base64 PNG's IHDR chunk (bytes 16..24), without
/// decoding the whole image.
pub(super) fn png_size(base64: &str) -> Option<(u32, u32)> {
    let prefix = base64.as_bytes().get(..32)?;
    let mut bytes = Vec::with_capacity(24);
    for chunk in prefix.chunks(4) {
        let mut acc: u32 = 0;
        for &c in chunk {
            let v = match c {
                b'A'..=b'Z' => c - b'A',
                b'a'..=b'z' => c - b'a' + 26,
                b'0'..=b'9' => c - b'0' + 52,
                b'+' => 62,
                b'/' => 63,
                _ => return None,
            };
            acc = (acc << 6) | u32::from(v);
        }
        bytes.extend_from_slice(&[(acc >> 16) as u8, (acc >> 8) as u8, acc as u8]);
    }
    if bytes.len() < 24
        || bytes[..8] != [0x89, b'P', b'N', b'G', 0x0d, 0x0a, 0x1a, 0x0a]
        || &bytes[12..16] != b"IHDR"
    {
        return None;
    }
    let width = u32::from_be_bytes(bytes.get(16..20)?.try_into().ok()?);
    let height = u32::from_be_bytes(bytes.get(20..24)?.try_into().ok()?);
    Some((width, height))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn png_size_reads_ihdr_from_base64() {
        // 1x1 transparent PNG.
        let png = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==";
        assert_eq!(png_size(png), Some((1, 1)));
        // 640x480 header.
        let header = "iVBORw0KGgoAAAANSUhEUgAAAoAAAAHgCAYAAAA";
        assert_eq!(png_size(header), Some((640, 480)));
        assert_eq!(png_size("/9j/4AAQSkZJRgABAQAAAQABAAD/2wBDAAgGBgcGBQgHBwcJ"), None);
        assert_eq!(png_size("short"), None);
    }
}
