//! `wallpaper.json` (plans/cmux-next/live-wallpapers.md, "The manifest").
//!
//! Strict: an unknown key is an error, so a misspelt key never silently falls
//! back. Every error names the value it is about with a JSON pointer.

use serde_json::{Map, Value, json};
use std::collections::BTreeMap;
use std::fmt;

/// At most this many params (two `vec4<f32>` in `Frame.params`).
pub const MAX_PARAMS: usize = 8;
/// At most this many variants.
pub const MAX_VARIANTS: usize = 16;
/// The longest id.
pub const MAX_ID_LEN: usize = 48;
/// The largest `wallpaper.json` read.
pub const MAX_MANIFEST_BYTES: usize = 16 * 1024;

/// One float the program reads from `frame.params` (in manifest order).
#[derive(Clone, Debug, PartialEq)]
pub struct Param {
    pub name: String,
    pub title: Option<String>,
    pub default: f32,
    pub min: f32,
    pub max: f32,
}

/// The time and pointer a still uses when the caller gives none.
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Still {
    /// Seconds since shown.
    pub time: f32,
    /// Fractions of the size, top left origin.
    pub pointer: [f32; 2],
}

/// A named look: an accent, param values, and the themes it is shown in.
#[derive(Clone, Debug, PartialEq)]
pub struct Variant {
    pub name: String,
    /// `#RRGGBB`, sRGB.
    pub accent: Option<String>,
    /// Param name to value; every name is a declared param, every value in its range.
    pub params: BTreeMap<String, f32>,
    /// `"dark"` and/or `"light"`; empty means both.
    pub themes: Vec<String>,
    /// This variant's own still; none means the manifest's.
    pub still: Option<Still>,
}

/// A checked `wallpaper.json`.
#[derive(Clone, Debug, PartialEq)]
pub struct Manifest {
    pub id: String,
    pub name: String,
    pub description: String,
    /// The program, relative to the wallpaper's folder.
    pub shader: String,
    /// The program's own frame cap, 1..=60.
    pub fps: u32,
    /// The backing scale it renders at, 0.25..=1.
    pub scale: f32,
    /// Whether pointer motion wakes it.
    pub interactive: bool,
    pub params: Vec<Param>,
    pub still: Still,
    pub variants: Vec<Variant>,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum ManifestErrorKind {
    /// Not JSON, or larger than [`MAX_MANIFEST_BYTES`].
    NotJson,
    /// A required key is absent.
    Missing,
    /// A key the spec does not define.
    UnknownKey,
    /// The value has the wrong JSON type.
    WrongType,
    /// A number outside its range, or an array or string of the wrong length.
    OutOfRange,
    /// A string that does not have the required form (id slug, path, color).
    BadFormat,
    /// A name used twice.
    Duplicate,
}

/// Why a manifest was refused, at `pointer` (RFC 6901, `""` is the document).
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ManifestError {
    pub kind: ManifestErrorKind,
    pub pointer: String,
    pub message: String,
}

impl fmt::Display for ManifestError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        if self.pointer.is_empty() {
            write!(f, "{}", self.message)
        } else {
            write!(f, "{}: {}", self.pointer, self.message)
        }
    }
}

impl std::error::Error for ManifestError {}

fn err(
    kind: ManifestErrorKind,
    pointer: impl Into<String>,
    message: impl Into<String>,
) -> ManifestError {
    ManifestError { kind, pointer: pointer.into(), message: message.into() }
}

type Result<T> = std::result::Result<T, ManifestError>;

fn escape(key: &str) -> String {
    key.replace('~', "~0").replace('/', "~1")
}

fn object<'a>(v: &'a Value, at: &str) -> Result<&'a Map<String, Value>> {
    v.as_object().ok_or_else(|| err(ManifestErrorKind::WrongType, at, "must be an object"))
}

fn only_keys(o: &Map<String, Value>, at: &str, allowed: &[&str]) -> Result<()> {
    match o.keys().find(|k| !allowed.contains(&k.as_str())) {
        Some(k) => Err(err(
            ManifestErrorKind::UnknownKey,
            format!("{at}/{}", escape(k)),
            format!("unknown key {k:?}"),
        )),
        None => Ok(()),
    }
}

fn required<'a>(o: &'a Map<String, Value>, at: &str, key: &str) -> Result<&'a Value> {
    o.get(key).ok_or_else(|| err(ManifestErrorKind::Missing, at, format!("{key} is required")))
}

fn string(v: &Value, at: &str, max_chars: usize) -> Result<String> {
    let s = v.as_str().ok_or_else(|| err(ManifestErrorKind::WrongType, at, "must be a string"))?;
    let n = s.chars().count();
    if n == 0 || n > max_chars {
        return Err(err(
            ManifestErrorKind::OutOfRange,
            at,
            format!("must be 1 to {max_chars} characters"),
        ));
    }
    if s.chars().any(char::is_control) {
        return Err(err(ManifestErrorKind::BadFormat, at, "must not contain control characters"));
    }
    Ok(s.to_string())
}

fn number(v: &Value, at: &str, min: f64, max: f64) -> Result<f32> {
    let n = v.as_f64().ok_or_else(|| err(ManifestErrorKind::WrongType, at, "must be a number"))?;
    if !n.is_finite() || n < min || n > max {
        return Err(err(
            ManifestErrorKind::OutOfRange,
            at,
            format!("must be within {min} to {max}"),
        ));
    }
    #[allow(clippy::cast_possible_truncation)]
    Ok(n as f32)
}

fn is_slug(s: &str) -> bool {
    !s.is_empty()
        && s.len() <= MAX_ID_LEN
        && s.split('-').all(|part| {
            !part.is_empty() && part.bytes().all(|b| b.is_ascii_lowercase() || b.is_ascii_digit())
        })
        && s.as_bytes().first().is_some_and(u8::is_ascii_lowercase)
}

fn is_param_name(s: &str) -> bool {
    s.len() <= 32
        && s.as_bytes().first().is_some_and(u8::is_ascii_lowercase)
        && s.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'_')
}

/// A relative path inside the folder: no leading `/`, no `..`, no backslash.
fn is_relative_path(s: &str) -> bool {
    !s.is_empty()
        && s.len() <= 256
        && !s.starts_with('/')
        && s.split('/').all(|seg| !seg.is_empty() && seg != "." && seg != "..")
        && s.bytes()
            .all(|b| b.is_ascii_alphanumeric() || matches!(b, b'.' | b'_' | b'-' | b'/' | b'@'))
}

fn is_hex_color(s: &str) -> bool {
    s.len() == 7 && s.starts_with('#') && s.bytes().skip(1).all(|b| b.is_ascii_hexdigit())
}

impl Manifest {
    /// Parses and checks `wallpaper.json`'s bytes.
    pub fn parse(json: &[u8]) -> Result<Self> {
        if json.len() > MAX_MANIFEST_BYTES {
            return Err(err(
                ManifestErrorKind::NotJson,
                "",
                format!("wallpaper.json is larger than {} KiB", MAX_MANIFEST_BYTES / 1024),
            ));
        }
        let v: Value = serde_json::from_slice(json)
            .map_err(|e| err(ManifestErrorKind::NotJson, "", format!("not JSON: {e}")))?;
        Self::from_value(&v)
    }

    /// Checks a parsed `wallpaper.json`.
    pub fn from_value(v: &Value) -> Result<Self> {
        let o = object(v, "")?;
        only_keys(
            o,
            "",
            &[
                "id",
                "name",
                "description",
                "shader",
                "fps",
                "scale",
                "interactive",
                "params",
                "still",
                "variants",
            ],
        )?;
        let id_v = required(o, "", "id")?;
        let id = id_v
            .as_str()
            .ok_or_else(|| err(ManifestErrorKind::WrongType, "/id", "must be a string"))?;
        if !is_slug(id) {
            return Err(err(
                ManifestErrorKind::BadFormat,
                "/id",
                format!(
                    "{id:?} is not a slug: lowercase letters, digits and single dashes, starting with a letter, at most {MAX_ID_LEN}"
                ),
            ));
        }
        let name = string(required(o, "", "name")?, "/name", 60)?;
        let description = string(required(o, "", "description")?, "/description", 300)?;
        let shader_v = required(o, "", "shader")?;
        let shader = shader_v
            .as_str()
            .ok_or_else(|| err(ManifestErrorKind::WrongType, "/shader", "must be a string"))?;
        if !is_relative_path(shader) || !shader.ends_with(".wgsl") {
            return Err(err(
                ManifestErrorKind::BadFormat,
                "/shader",
                format!("{shader:?} must be a .wgsl file inside the wallpaper's folder"),
            ));
        }
        let fps_v = required(o, "", "fps")?;
        let fps = fps_v
            .as_u64()
            .ok_or_else(|| err(ManifestErrorKind::WrongType, "/fps", "must be a whole number"))?;
        if !(1..=60).contains(&fps) {
            return Err(err(ManifestErrorKind::OutOfRange, "/fps", "must be within 1 to 60"));
        }
        let scale = number(required(o, "", "scale")?, "/scale", 0.25, 1.0)?;
        let interactive = required(o, "", "interactive")?.as_bool().ok_or_else(|| {
            err(ManifestErrorKind::WrongType, "/interactive", "must be true or false")
        })?;
        let params = match o.get("params") {
            None => Vec::new(),
            Some(p) => parse_params(p)?,
        };
        let still = parse_still(required(o, "", "still")?, "/still")?;
        let variants = match o.get("variants") {
            None => Vec::new(),
            Some(p) => parse_variants(p, &params)?,
        };
        Ok(Self {
            id: id.to_string(),
            name,
            description,
            shader: shader.to_string(),
            fps: u32::try_from(fps).unwrap_or(30),
            scale,
            interactive,
            params,
            still,
            variants,
        })
    }

    /// The params' values in manifest order, padded with 0 to 8: the default,
    /// or the override of the same name. An unknown name is ignored; a value
    /// is clamped to the param's range.
    pub fn param_values(&self, overrides: &BTreeMap<String, f32>) -> [f32; MAX_PARAMS] {
        let mut out = [0.0; MAX_PARAMS];
        for (slot, p) in out.iter_mut().zip(&self.params) {
            let v = overrides.get(&p.name).copied().filter(|v| v.is_finite()).unwrap_or(p.default);
            *slot = v.clamp(p.min, p.max);
        }
        out
    }

    /// The manifest as JSON with every optional key filled in: the shape the
    /// app reads (`cmux_wallpaper_validate_manifest`).
    pub fn to_json(&self) -> Value {
        json!({
            "id": self.id,
            "name": self.name,
            "description": self.description,
            "shader": self.shader,
            "fps": self.fps,
            "scale": self.scale,
            "interactive": self.interactive,
            "params": self.params.iter().map(|p| json!({
                "name": p.name,
                "title": p.title.clone().unwrap_or_else(|| p.name.clone()),
                "default": p.default,
                "min": p.min,
                "max": p.max,
            })).collect::<Vec<_>>(),
            "still": { "time": self.still.time, "pointer": self.still.pointer },
            "variants": self.variants.iter().map(|v| {
                let mut out = Map::new();
                out.insert("name".into(), json!(v.name));
                out.insert("params".into(), json!(v.params));
                let themes = if v.themes.is_empty() { vec!["dark".to_string(), "light".to_string()] } else { v.themes.clone() };
                out.insert("themes".into(), json!(themes));
                // An absent key, not null: the parser refuses null.
                if let Some(a) = &v.accent {
                    out.insert("accent".into(), json!(a));
                }
                if let Some(s) = v.still {
                    out.insert("still".into(), json!({ "time": s.time, "pointer": s.pointer }));
                }
                Value::Object(out)
            }).collect::<Vec<_>>(),
        })
    }
}

fn parse_params(v: &Value) -> Result<Vec<Param>> {
    let items = v
        .as_array()
        .ok_or_else(|| err(ManifestErrorKind::WrongType, "/params", "must be an array"))?;
    if items.len() > MAX_PARAMS {
        return Err(err(
            ManifestErrorKind::OutOfRange,
            "/params",
            format!("at most {MAX_PARAMS} params"),
        ));
    }
    let mut out: Vec<Param> = Vec::with_capacity(items.len());
    for (i, item) in items.iter().enumerate() {
        let at = format!("/params/{i}");
        let o = object(item, &at)?;
        only_keys(o, &at, &["name", "title", "default", "min", "max"])?;
        let name_at = format!("{at}/name");
        let name = required(o, &at, "name")?
            .as_str()
            .ok_or_else(|| err(ManifestErrorKind::WrongType, &name_at, "must be a string"))?;
        if !is_param_name(name) {
            return Err(err(
                ManifestErrorKind::BadFormat,
                name_at,
                format!(
                    "{name:?} must start with a lowercase letter and use letters, digits and _ (at most 32)"
                ),
            ));
        }
        if out.iter().any(|p| p.name == name) {
            return Err(err(
                ManifestErrorKind::Duplicate,
                name_at,
                format!("{name} is declared twice"),
            ));
        }
        let title = match o.get("title") {
            None => None,
            Some(t) => Some(string(t, &format!("{at}/title"), 60)?),
        };
        let wide = f64::from(f32::MAX);
        let min = number(required(o, &at, "min")?, &format!("{at}/min"), -wide, wide)?;
        let max = number(required(o, &at, "max")?, &format!("{at}/max"), f64::from(min), wide)?;
        let default = number(
            required(o, &at, "default")?,
            &format!("{at}/default"),
            f64::from(min),
            f64::from(max),
        )?;
        out.push(Param { name: name.to_string(), title, default, min, max });
    }
    Ok(out)
}

fn parse_still(v: &Value, at: &str) -> Result<Still> {
    let o = object(v, at)?;
    only_keys(o, at, &["time", "pointer"])?;
    let time = number(required(o, at, "time")?, &format!("{at}/time"), 0.0, 1.0e6)?;
    let p_at = format!("{at}/pointer");
    let p = required(o, at, "pointer")?
        .as_array()
        .ok_or_else(|| err(ManifestErrorKind::WrongType, &p_at, "must be [x, y]"))?;
    let [x, y] = p.as_slice() else {
        return Err(err(ManifestErrorKind::OutOfRange, p_at, "must be [x, y]"));
    };
    let x = number(x, &format!("{p_at}/0"), 0.0, 1.0)?;
    let y = number(y, &format!("{p_at}/1"), 0.0, 1.0)?;
    Ok(Still { time, pointer: [x, y] })
}

fn parse_variants(v: &Value, params: &[Param]) -> Result<Vec<Variant>> {
    let items = v
        .as_array()
        .ok_or_else(|| err(ManifestErrorKind::WrongType, "/variants", "must be an array"))?;
    if items.len() > MAX_VARIANTS {
        return Err(err(
            ManifestErrorKind::OutOfRange,
            "/variants",
            format!("at most {MAX_VARIANTS} variants"),
        ));
    }
    let mut out: Vec<Variant> = Vec::with_capacity(items.len());
    for (i, item) in items.iter().enumerate() {
        let at = format!("/variants/{i}");
        let o = object(item, &at)?;
        only_keys(o, &at, &["name", "accent", "params", "themes", "still"])?;
        let name = string(required(o, &at, "name")?, &format!("{at}/name"), 60)?;
        if out.iter().any(|v| v.name == name) {
            return Err(err(
                ManifestErrorKind::Duplicate,
                format!("{at}/name"),
                format!("{name} is declared twice"),
            ));
        }
        let accent = match o.get("accent") {
            None => None,
            Some(a) => {
                let s = a.as_str().filter(|s| is_hex_color(s)).ok_or_else(|| {
                    err(ManifestErrorKind::BadFormat, format!("{at}/accent"), "must be #RRGGBB")
                })?;
                Some(s.to_string())
            }
        };
        let mut values = BTreeMap::new();
        if let Some(p) = o.get("params") {
            let p_at = format!("{at}/params");
            for (key, value) in object(p, &p_at)? {
                let v_at = format!("{p_at}/{}", escape(key));
                let Some(param) = params.iter().find(|p| &p.name == key) else {
                    return Err(err(
                        ManifestErrorKind::UnknownKey,
                        v_at,
                        format!("{key} is not a declared param"),
                    ));
                };
                let n = number(value, &v_at, f64::from(param.min), f64::from(param.max))?;
                values.insert(key.clone(), n);
            }
        }
        let mut themes: Vec<String> = Vec::new();
        if let Some(t) = o.get("themes") {
            let t_at = format!("{at}/themes");
            let list = t
                .as_array()
                .ok_or_else(|| err(ManifestErrorKind::WrongType, &t_at, "must be an array"))?;
            if list.is_empty() {
                return Err(err(
                    ManifestErrorKind::OutOfRange,
                    t_at,
                    "must name dark, light or both",
                ));
            }
            for (j, theme) in list.iter().enumerate() {
                let th_at = format!("{t_at}/{j}");
                let theme =
                    theme.as_str().filter(|s| matches!(*s, "dark" | "light")).ok_or_else(|| {
                        err(ManifestErrorKind::BadFormat, &th_at, "must be \"dark\" or \"light\"")
                    })?;
                if themes.iter().any(|t| t == theme) {
                    return Err(err(
                        ManifestErrorKind::Duplicate,
                        th_at,
                        format!("{theme} is listed twice"),
                    ));
                }
                themes.push(theme.to_string());
            }
        }
        let still = match o.get("still") {
            None => None,
            Some(s) => Some(parse_still(s, &format!("{at}/still"))?),
        };
        out.push(Variant { name, accent, params: values, themes, still });
    }
    Ok(out)
}

#[cfg(test)]
mod tests {
    use super::*;

    fn base() -> Value {
        json!({
            "id": "grain-silk",
            "name": "Grain and Silk",
            "description": "Film grain.",
            "shader": "wallpaper.wgsl",
            "fps": 30,
            "scale": 0.5,
            "interactive": true,
            "params": [{ "name": "speed", "title": "Speed", "default": 0.4, "min": 0, "max": 2 }],
            "still": { "time": 14.0, "pointer": [0.62, 0.42] },
            "variants": [{ "name": "Cobalt", "accent": "#3D7BFF", "params": { "speed": 1 }, "themes": ["dark"] }]
        })
    }

    fn refuse(edit: impl FnOnce(&mut Value)) -> ManifestError {
        let mut v = base();
        edit(&mut v);
        match Manifest::from_value(&v) {
            Ok(m) => panic!("accepted {m:?}"),
            Err(e) => e,
        }
    }

    #[test]
    fn the_spec_example_parses() {
        let m = Manifest::from_value(&base()).unwrap();
        assert_eq!(m.id, "grain-silk");
        assert_eq!(m.fps, 30);
        assert_eq!(m.params.len(), 1);
        assert_eq!(m.still.pointer, [0.62, 0.42]);
        assert_eq!(m.variants[0].params["speed"], 1.0);
        let back = Manifest::from_value(&m.to_json()).unwrap();
        assert_eq!(back.id, m.id);
        assert_eq!(back.params[0].title.as_deref(), Some("Speed"));
    }

    #[test]
    fn a_variant_may_carry_its_own_still() {
        let mut v = base();
        v["variants"][0]["still"] = json!({ "time": 3.0, "pointer": [0.2, 0.8] });
        let m = Manifest::from_value(&v).unwrap();
        assert_eq!(m.variants[0].still, Some(Still { time: 3.0, pointer: [0.2, 0.8] }));
        let back = Manifest::from_value(&m.to_json()).unwrap();
        assert_eq!(back.variants[0].still, m.variants[0].still);
        let plain = Manifest::from_value(&base()).unwrap();
        assert_eq!(plain.variants[0].still, None);
        assert_eq!(Manifest::from_value(&plain.to_json()).unwrap(), plain);
        let mut bare = base();
        bare["variants"][0].as_object_mut().unwrap().remove("accent");
        let bare = Manifest::from_value(&bare).unwrap();
        assert_eq!(Manifest::from_value(&bare.to_json()).unwrap(), bare);
        let e = refuse(|v| v["variants"][0]["still"] = json!({ "time": 3.0, "pointer": [0.2, 2] }));
        assert_eq!(e.pointer, "/variants/0/still/pointer/1");
    }

    #[test]
    fn params_and_variants_are_optional() {
        let e = Manifest::from_value(&{
            let mut v = base();
            let o = v.as_object_mut().unwrap();
            o.remove("params");
            o.remove("variants");
            v
        })
        .unwrap();
        assert!(e.params.is_empty());
        assert_eq!(e.param_values(&BTreeMap::new()), [0.0; 8]);
    }

    #[test]
    fn param_values_take_overrides_clamped() {
        let m = Manifest::from_value(&base()).unwrap();
        let mut o = BTreeMap::new();
        assert_eq!(m.param_values(&o)[0], 0.4);
        o.insert("speed".to_string(), 9.0);
        assert_eq!(m.param_values(&o)[0], 2.0);
    }

    #[test]
    fn each_rule_refuses_with_a_pointer() {
        type Edit = Box<dyn FnOnce(&mut Value)>;
        let cases: Vec<(Edit, ManifestErrorKind, &str)> = vec![
            (Box::new(|v| v["id"] = json!("Grain")), ManifestErrorKind::BadFormat, "/id"),
            (Box::new(|v| v["id"] = json!("a--b")), ManifestErrorKind::BadFormat, "/id"),
            (Box::new(|v| v["id"] = json!("-a")), ManifestErrorKind::BadFormat, "/id"),
            (Box::new(|v| v["id"] = json!(3)), ManifestErrorKind::WrongType, "/id"),
            (
                Box::new(|v| {
                    v.as_object_mut().unwrap().remove("name");
                }),
                ManifestErrorKind::Missing,
                "",
            ),
            (Box::new(|v| v["name"] = json!("")), ManifestErrorKind::OutOfRange, "/name"),
            (Box::new(|v| v["extra"] = json!(1)), ManifestErrorKind::UnknownKey, "/extra"),
            (
                Box::new(|v| v["shader"] = json!("../x.wgsl")),
                ManifestErrorKind::BadFormat,
                "/shader",
            ),
            (Box::new(|v| v["shader"] = json!("/x.wgsl")), ManifestErrorKind::BadFormat, "/shader"),
            (Box::new(|v| v["shader"] = json!("x.metal")), ManifestErrorKind::BadFormat, "/shader"),
            (Box::new(|v| v["fps"] = json!(0)), ManifestErrorKind::OutOfRange, "/fps"),
            (Box::new(|v| v["fps"] = json!(61)), ManifestErrorKind::OutOfRange, "/fps"),
            (Box::new(|v| v["fps"] = json!(29.5)), ManifestErrorKind::WrongType, "/fps"),
            (Box::new(|v| v["scale"] = json!(0.2)), ManifestErrorKind::OutOfRange, "/scale"),
            (Box::new(|v| v["scale"] = json!(1.5)), ManifestErrorKind::OutOfRange, "/scale"),
            (
                Box::new(|v| v["interactive"] = json!(1)),
                ManifestErrorKind::WrongType,
                "/interactive",
            ),
            (
                Box::new(|v| {
                    v["params"] = json!((0..9).map(|i| json!({"name": format!("p{i}"), "default": 0, "min": 0, "max": 1})).collect::<Vec<_>>());
                }),
                ManifestErrorKind::OutOfRange,
                "/params",
            ),
            (
                Box::new(|v| v["params"][0]["default"] = json!(3)),
                ManifestErrorKind::OutOfRange,
                "/params/0/default",
            ),
            (
                Box::new(|v| v["params"][0]["max"] = json!(-1)),
                ManifestErrorKind::OutOfRange,
                "/params/0/max",
            ),
            (
                Box::new(|v| v["params"][0]["name"] = json!("Speed")),
                ManifestErrorKind::BadFormat,
                "/params/0/name",
            ),
            (
                Box::new(
                    |v| v["params"] = json!([{"name": "a", "default": 0, "min": 0, "max": 1}, {"name": "a", "default": 0, "min": 0, "max": 1}]),
                ),
                ManifestErrorKind::Duplicate,
                "/params/1/name",
            ),
            (
                Box::new(|v| v["still"]["pointer"] = json!([0.5])),
                ManifestErrorKind::OutOfRange,
                "/still/pointer",
            ),
            (
                Box::new(|v| v["still"]["pointer"] = json!([0.5, 2])),
                ManifestErrorKind::OutOfRange,
                "/still/pointer/1",
            ),
            (
                Box::new(|v| v["still"]["time"] = json!(-1)),
                ManifestErrorKind::OutOfRange,
                "/still/time",
            ),
            (
                Box::new(|v| v["variants"][0]["accent"] = json!("blue")),
                ManifestErrorKind::BadFormat,
                "/variants/0/accent",
            ),
            (
                Box::new(|v| v["variants"][0]["params"] = json!({"x": 1})),
                ManifestErrorKind::UnknownKey,
                "/variants/0/params/x",
            ),
            (
                Box::new(|v| v["variants"][0]["params"] = json!({"speed": 5})),
                ManifestErrorKind::OutOfRange,
                "/variants/0/params/speed",
            ),
            (
                Box::new(|v| v["variants"][0]["themes"] = json!(["sepia"])),
                ManifestErrorKind::BadFormat,
                "/variants/0/themes/0",
            ),
            (
                Box::new(|v| v["variants"][0]["themes"] = json!([])),
                ManifestErrorKind::OutOfRange,
                "/variants/0/themes",
            ),
        ];
        for (i, (edit, kind, pointer)) in cases.into_iter().enumerate() {
            let e = refuse(edit);
            assert_eq!((e.kind, e.pointer.as_str()), (kind, pointer), "case {i}: {e}");
        }
    }

    #[test]
    fn not_json_and_too_large_are_refused() {
        assert_eq!(Manifest::parse(b"{").unwrap_err().kind, ManifestErrorKind::NotJson);
        let big = vec![b' '; MAX_MANIFEST_BYTES + 1];
        assert_eq!(Manifest::parse(&big).unwrap_err().kind, ManifestErrorKind::NotJson);
        assert_eq!(Manifest::parse(b"[]").unwrap_err().kind, ManifestErrorKind::WrongType);
    }
}
