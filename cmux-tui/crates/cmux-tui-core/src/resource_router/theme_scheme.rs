//! `theme.scheme.convert`, `theme.scheme.export` and `theme.scheme.from_image`
//! (read, `theme-scheme-v1`): 16-color scheme import and export and a scheme
//! from a background image, with the converters of `cmux-theme-tokens`
//! (extensibility design 12.4, step 13), so the Settings theme studio, a page
//! and an extension convert the same way `cmux theme` does.
//!
//! All three are stateless and write nothing: installing an imported scheme
//! as a theme file is `cmux theme import` (the person's own CLI) or the app.
//! `export` reads an installed theme by name from Ghostty's theme folders,
//! never a path. `from_image` takes decoded pixels, at most
//! [`MAX_IMAGE_PIXELS`] (the caller downsamples; the palette samples a
//! 64 x 64 grid anyway), so the daemon decodes no image format.

use std::sync::Arc;

use base64::Engine as _;
use cmux_theme_tokens::{
    Appearance, Env, Pixels, Rgb, Scheme, SchemeFormat, find_theme_file, palette_from_image,
};
use serde_json::{Map, Value, json};

use super::{ParsedResourceRequest, ensure_session_route};
use crate::Mux;
use crate::resource::{ResourceError, ResourceOperation};

/// Advertised in identify: the daemon answers `theme.scheme.*`.
pub(crate) const CAPABILITY: &str = "theme-scheme-v1";

/// Most pixels `from_image` takes (256 x 256).
pub(crate) const MAX_IMAGE_PIXELS: u64 = 256 * 256;

pub(super) fn dispatch(
    mux: &Arc<Mux>,
    request: ParsedResourceRequest,
) -> Result<Value, ResourceError> {
    ensure_session_route(mux, &request.selectors)?;
    let mut fields = request.fields;
    fields.retain(|_, value| !value.is_null());
    match request.envelope.operation {
        ResourceOperation::ThemeSchemeConvert => convert(&fields),
        ResourceOperation::ThemeSchemeExport => export(&fields, &Env::current()),
        ResourceOperation::ThemeSchemeFromImage => from_image(&fields),
        other => Err(ResourceError::validation_invalid(
            None,
            format!("{} is not a theme.scheme operation", other.wire_name()),
        )),
    }
}

fn string<'a>(fields: &'a Map<String, Value>, key: &str) -> Option<&'a str> {
    fields.get(key).and_then(Value::as_str)
}

fn format_field(
    fields: &Map<String, Value>,
    key: &str,
) -> Result<Option<SchemeFormat>, ResourceError> {
    string(fields, key)
        .map(|name| {
            SchemeFormat::from_name(name).ok_or_else(|| {
                ResourceError::validation_invalid(
                    Some(key),
                    format!("unknown scheme format {name:?}"),
                )
            })
        })
        .transpose()
}

fn hex(color: Rgb) -> String {
    format!("#{:06x}", color.to_hex())
}

/// A scheme as the catalog's `ThemeScheme`.
pub(crate) fn scheme_json(scheme: &Scheme) -> Value {
    let optional = |color: Option<Rgb>| color.map_or(Value::Null, |c| Value::String(hex(c)));
    json!({
        "name": scheme.name,
        "author": scheme.author,
        "background": hex(scheme.background),
        "foreground": hex(scheme.foreground),
        "cursor": optional(scheme.cursor),
        "cursorText": optional(scheme.cursor_text),
        "selectionBackground": optional(scheme.selection_background),
        "selectionForeground": optional(scheme.selection_foreground),
        "palette": scheme.palette.iter().map(|c| hex(*c)).collect::<Vec<_>>(),
        "accent": optional(scheme.accent),
        "base16": scheme.base16_colors().iter().map(|c| hex(*c)).collect::<Vec<_>>(),
    })
}

/// `{text, file?, from?, to?}`: reads `text` (format `from`, else detected
/// from `file`'s extension and the text) and writes it as `to` (Ghostty by
/// default).
pub(crate) fn convert(fields: &Map<String, Value>) -> Result<Value, ResourceError> {
    let text = string(fields, "text")
        .ok_or_else(|| ResourceError::validation_invalid(Some("text"), "text is required"))?;
    let file = string(fields, "file").unwrap_or("scheme");
    let from = format_field(fields, "from")?;
    let to = format_field(fields, "to")?.unwrap_or(SchemeFormat::Ghostty);
    let read = from.unwrap_or_else(|| SchemeFormat::detect(file, text));
    let scheme = Scheme::parse(text, file, Some(read))
        .map_err(|error| ResourceError::validation_invalid(Some("text"), error.to_string()))?;
    Ok(json!({
        "from": read.name(),
        "format": to.name(),
        "text": scheme.export(to),
        "scheme": scheme_json(&scheme),
    }))
}

/// `{name, format?}`: the installed theme `name` written as `format`
/// (base16 by default).
pub(crate) fn export(fields: &Map<String, Value>, env: &Env) -> Result<Value, ResourceError> {
    let name = string(fields, "name")
        .ok_or_else(|| ResourceError::validation_invalid(Some("name"), "name is required"))?;
    let to = format_field(fields, "format")?.unwrap_or(SchemeFormat::Base16);
    let path = find_theme_file(env, name).ok_or_else(|| {
        ResourceError::validation_invalid(
            Some("name"),
            format!("no installed theme named {name:?}"),
        )
    })?;
    let text = std::fs::read_to_string(&path).map_err(|error| {
        ResourceError::operation_failed(
            "theme.scheme.export",
            format!("{}: {error}", path.display()),
            json!({}),
        )
    })?;
    let mut scheme = Scheme::parse(&text, &path.display().to_string(), Some(SchemeFormat::Ghostty))
        .map_err(|error| {
            ResourceError::operation_failed("theme.scheme.export", error.to_string(), json!({}))
        })?;
    scheme.name = Some(name.to_owned());
    Ok(json!({
        "name": name,
        "format": to.name(),
        "text": scheme.export(to),
        "scheme": scheme_json(&scheme),
    }))
}

/// `{width, height, channels, pixels, appearance?, format?}`: the scheme of
/// an image's pixels (base64 RGB or RGBA rows), with its accent and glass
/// tint, written as `format` (Ghostty by default).
pub(crate) fn from_image(fields: &Map<String, Value>) -> Result<Value, ResourceError> {
    let number = |key: &str| {
        fields.get(key).and_then(Value::as_u64).ok_or_else(|| {
            ResourceError::validation_invalid(Some(key), format!("{key} is required"))
        })
    };
    let (width, height, channels) = (number("width")?, number("height")?, number("channels")?);
    if width.saturating_mul(height) > MAX_IMAGE_PIXELS {
        return Err(ResourceError::validation_invalid(
            Some("width"),
            format!("{width}x{height} is more than {MAX_IMAGE_PIXELS} pixels; downsample first"),
        ));
    }
    let encoded = string(fields, "pixels")
        .ok_or_else(|| ResourceError::validation_invalid(Some("pixels"), "pixels is required"))?;
    let data = base64::engine::general_purpose::STANDARD
        .decode(encoded)
        .map_err(|error| ResourceError::validation_invalid(Some("pixels"), error.to_string()))?;
    let appearance = match string(fields, "appearance") {
        None => None,
        Some("dark") => Some(Appearance::Dark),
        Some("light") => Some(Appearance::Light),
        Some(other) => {
            return Err(ResourceError::validation_invalid(
                Some("appearance"),
                format!("appearance is dark or light, not {other:?}"),
            ));
        }
    };
    let to = format_field(fields, "format")?.unwrap_or(SchemeFormat::Ghostty);
    let pixels = Pixels {
        width: u32::try_from(width).unwrap_or(u32::MAX),
        height: u32::try_from(height).unwrap_or(u32::MAX),
        channels: u8::try_from(channels).unwrap_or(0),
        data: &data,
    };
    let palette = palette_from_image(&pixels, appearance)
        .map_err(|error| ResourceError::validation_invalid(Some("pixels"), error.to_string()))?;
    Ok(json!({
        "appearance": if palette.appearance == Appearance::Dark { "dark" } else { "light" },
        "accent": hex(palette.accent),
        "glassTint": format!("#{:08x}", palette.glass_tint.to_rgba_u32()),
        "swatches": palette.swatches.iter().map(|(color, share)| json!({
            "color": hex(*color),
            "share": share,
        })).collect::<Vec<_>>(),
        "format": to.name(),
        "text": palette.scheme.export(to),
        "scheme": scheme_json(&palette.scheme),
    }))
}

#[cfg(test)]
mod tests {
    use super::*;

    fn fields(value: Value) -> Map<String, Value> {
        value.as_object().cloned().unwrap_or_default()
    }

    const BASE16: &str = "scheme: \"T\"\nbase00: \"1d1f21\"\nbase01: \"282a2e\"\nbase02: \"373b41\"\nbase03: \"969896\"\nbase04: \"b4b7b4\"\nbase05: \"c5c8c6\"\nbase06: \"e0e0e0\"\nbase07: \"ffffff\"\nbase08: \"cc6666\"\nbase09: \"de935f\"\nbase0A: \"f0c674\"\nbase0B: \"b5bd68\"\nbase0C: \"8abeb7\"\nbase0D: \"81a2be\"\nbase0E: \"b294bb\"\nbase0F: \"a3685a\"\n";

    #[test]
    fn convert_reads_base16_and_writes_ghostty() {
        let out = convert(&fields(json!({ "text": BASE16, "file": "t.yaml" }))).unwrap();
        assert_eq!(out["from"], "base16");
        assert_eq!(out["format"], "ghostty");
        assert_eq!(out["scheme"]["background"], "#1d1f21");
        assert_eq!(out["scheme"]["palette"][4], "#81a2be");
        assert!(out["text"].as_str().unwrap().contains("palette = 4=#81a2be"));
    }

    #[test]
    fn convert_names_the_file_and_line_of_a_bad_color() {
        let bad = BASE16.replace("\"b294bb\"", "\"b294zz\"");
        let error = convert(&fields(json!({ "text": bad, "file": "t.yaml" }))).unwrap_err();
        assert_eq!(error.code, "validation.invalid");
        assert!(error.message.contains("t.yaml:15"), "{}", error.message);
    }

    #[test]
    fn export_reads_an_installed_theme_by_name() {
        let home =
            std::env::temp_dir().join(format!("cmux-core-theme-export-{}", std::process::id()));
        let _ = std::fs::remove_dir_all(&home);
        let env =
            Env { home: Some(home.clone()), xdg_data_dirs: Some(String::new()), ..Env::default() };
        let scheme = Scheme::parse(BASE16, "t.yaml", None).unwrap();
        cmux_theme_tokens::install_scheme(&env, "Mine", &scheme, false).unwrap();
        let out = export(&fields(json!({ "name": "Mine", "format": "base16" })), &env).unwrap();
        assert!(out["text"].as_str().unwrap().contains("base0D: \"#81a2be\""), "{out}");
        assert!(export(&fields(json!({ "name": "../etc/passwd" })), &env).is_err());
        let _ = std::fs::remove_dir_all(&home);
    }

    #[test]
    fn from_image_gives_a_readable_scheme() {
        let mut data = Vec::new();
        for i in 0..64u32 {
            data.extend_from_slice(if i < 40 { &[16, 24, 48] } else { &[120, 60, 20] });
        }
        let pixels = base64::engine::general_purpose::STANDARD.encode(&data);
        let out = from_image(&fields(json!({
            "width": 8, "height": 8, "channels": 3, "pixels": pixels,
        })))
        .unwrap();
        assert_eq!(out["appearance"], "dark");
        assert!(out["accent"].as_str().unwrap().starts_with('#'));
        let too_big = from_image(&fields(json!({
            "width": 1000, "height": 1000, "channels": 3, "pixels": "",
        })));
        assert!(too_big.is_err());
    }
}
