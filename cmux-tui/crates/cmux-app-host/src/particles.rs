//! The `Particles {choreography}` document (`cmux.particles/1`, js/ABI.md "Particles choreography"):
//! the one validator every renderer relies on.
//!
//! A choreography is a small glyph of dots that moves through named phases, frame by frame: each
//! frame places every dot (`[x, y, scale]`, points from the node's centre, +y down) at a share of the
//! phase's duration, and the renderer eases between frames. A phase may instead generate its frames
//! from `sites`, `spawn` and `lifeFrames` (a dot born at the centre, flown to a site, gathered back).
//! `triggers` names the phases to play for an acpmux tool kind or session state.
//!
//! [`validate`] refuses unknown keys and anything past a limit. The app host runs it on every scene
//! batch ([`sanitize_scene_ops`]): an invalid document is replaced by `null` before the batch leaves
//! the VM, with a log line naming the first bad path, so the web and native renderers only ever see a
//! valid document or none (and draw nothing for none).

use serde_json::{Map, Value};

/// The document's `$schema`.
pub const SCHEMA: &str = "cmux.particles/1";
/// Most dots on screen at once (`particle.max`).
pub const MAX_PARTICLES: u64 = 16;
/// Most phases in a document.
pub const MAX_PHASES: usize = 32;
/// Most frames in a phase (`frames`, `lifeFrames`).
pub const MAX_FRAMES: usize = 64;
/// Most dots in a frame or a formation, and most `sites`.
pub const MAX_DOTS: usize = 16;
/// Shortest phase, spawn interval or life, in milliseconds.
pub const MIN_DURATION_MS: f64 = 50.0;
/// Longest phase, spawn interval or life, in milliseconds.
pub const MAX_DURATION_MS: f64 = 30_000.0;
/// Largest dot scale over `particle.size`.
pub const MAX_SCALE: f64 = 4.0;
/// Largest document, as compact JSON.
pub const MAX_DOCUMENT_BYTES: usize = 32 * 1024;
/// Farthest a dot may sit from the centre on either axis, in points.
pub const MAX_OFFSET: f64 = 256.0;
/// Largest `particle.size`, in points.
pub const MAX_SIZE: f64 = 64.0;
/// Most named formations, and most phases one trigger lists.
pub const MAX_NAMED: usize = 32;
/// Longest phase, formation or trigger name.
pub const MAX_NAME_LEN: usize = 32;

/// Formations a frame may name without defining them (`{"at": 0, "formation": "row"}`).
pub const BUILT_IN_FORMATIONS: &[&str] =
    &["row", "pair", "triangle", "diagonal", "grid2x2", "lone", "satellites"];
/// Trigger keys: the acpmux tool kinds (ACP `ToolKind`), the session states, and `cycle` (the
/// fallback for any other kind).
pub const TRIGGERS: &[&str] = &[
    "read",
    "edit",
    "delete",
    "move",
    "search",
    "execute",
    "think",
    "fetch",
    "switch_mode",
    "other",
    "sendMessage",
    "turnStart",
    "thinking",
    "idle",
    "cursor",
    "cycle",
];
/// Named curves for `ease` (the Motion vocabulary's curves and the timed curve's choices).
pub const EASE_NAMES: &[&str] = &["linear", "easeIn", "easeOut", "easeInOut", "smooth", "snappy"];
/// Dot shapes.
pub const SHAPES: &[&str] = &["circle", "square"];
/// The scene's semantic color tokens (ABI.md "Scene ops", Props).
pub const COLOR_TOKENS: &[&str] = &[
    "primary",
    "secondary",
    "tertiary",
    "accent",
    "separator",
    "success",
    "warning",
    "danger",
    "hover",
    "selected",
];

/// Why a document was refused: the first bad path (`phases.row.frames[3].dots[1]`) and what is wrong.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct ChoreographyError {
    pub path: String,
    pub message: String,
}

impl std::fmt::Display for ChoreographyError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        if self.path.is_empty() {
            write!(f, "{}", self.message)
        } else {
            write!(f, "{}: {}", self.path, self.message)
        }
    }
}

impl std::error::Error for ChoreographyError {}

type Checked = Result<(), ChoreographyError>;

fn fail<T>(path: &str, message: impl Into<String>) -> Result<T, ChoreographyError> {
    Err(ChoreographyError { path: path.to_string(), message: message.into() })
}

fn join(path: &str, key: &str) -> String {
    if path.is_empty() { key.to_string() } else { format!("{path}.{key}") }
}

fn object<'a>(value: &'a Value, path: &str) -> Result<&'a Map<String, Value>, ChoreographyError> {
    value.as_object().map_or_else(|| fail(path, "must be an object"), Ok)
}

fn array<'a>(value: &'a Value, path: &str) -> Result<&'a Vec<Value>, ChoreographyError> {
    value.as_array().map_or_else(|| fail(path, "must be an array"), Ok)
}

fn only_keys(map: &Map<String, Value>, allowed: &[&str], path: &str) -> Checked {
    match map.keys().find(|key| !allowed.contains(&key.as_str())) {
        Some(key) => fail(&join(path, key), "unknown key"),
        None => Ok(()),
    }
}

fn number(value: &Value, path: &str, low: f64, high: f64) -> Result<f64, ChoreographyError> {
    match value.as_f64() {
        Some(n) if n.is_finite() && (low..=high).contains(&n) => Ok(n),
        Some(_) => fail(path, format!("must be from {low} to {high}")),
        None => fail(path, "must be a number"),
    }
}

fn duration(value: &Value, path: &str) -> Result<f64, ChoreographyError> {
    number(value, path, MIN_DURATION_MS, MAX_DURATION_MS)
}

fn name_ok(name: &str) -> bool {
    !name.is_empty()
        && name.len() <= MAX_NAME_LEN
        && name.chars().all(|c| c.is_ascii_alphanumeric() || c == '-' || c == '_')
}

fn color(value: &Value, path: &str) -> Checked {
    let Some(text) = value.as_str() else { return fail(path, "must be a color string") };
    if COLOR_TOKENS.contains(&text) {
        return Ok(());
    }
    let hex = text.strip_prefix('#').unwrap_or("");
    if text.starts_with('#')
        && (hex.len() == 6 || hex.len() == 8)
        && hex.chars().all(|c| c.is_ascii_hexdigit())
    {
        return Ok(());
    }
    fail(path, "must be a scene color token or #RRGGBB[AA]")
}

fn ease(value: &Value, path: &str) -> Checked {
    if let Some(name) = value.as_str() {
        return if EASE_NAMES.contains(&name) {
            Ok(())
        } else {
            fail(
                path,
                format!("must be one of {}, {{spring}} or {{bezier}}", EASE_NAMES.join(", ")),
            )
        };
    }
    let map = object(value, path)?;
    if map.len() != 1 {
        return fail(path, "must have exactly one of spring or bezier");
    }
    if let Some(spring) = map.get("spring") {
        let at = join(path, "spring");
        let spring = object(spring, &at)?;
        only_keys(spring, &["response", "dampingFraction"], &at)?;
        let response = spring.get("response").map_or_else(|| fail(&at, "needs response"), Ok)?;
        number(response, &join(&at, "response"), 0.05, 10.0)?;
        if let Some(damping) = spring.get("dampingFraction") {
            number(damping, &join(&at, "dampingFraction"), 0.3, 1.0)?;
        }
        return Ok(());
    }
    if let Some(bezier) = map.get("bezier") {
        let at = join(path, "bezier");
        let points = array(bezier, &at)?;
        if points.len() != 4 {
            return fail(&at, "must be [x1, y1, x2, y2]");
        }
        for (index, point) in points.iter().enumerate() {
            // x stays in [0, 1] so the curve is a function of time; y may overshoot.
            let (low, high) = if index % 2 == 0 { (0.0, 1.0) } else { (-2.0, 3.0) };
            number(point, &format!("{at}[{index}]"), low, high)?;
        }
        return Ok(());
    }
    fail(path, "must have exactly one of spring or bezier")
}

fn at(value: Option<&Value>, path: &str, previous: Option<f64>) -> Result<f64, ChoreographyError> {
    let key = join(path, "at");
    let at = number(value.map_or(&Value::Null, |v| v), &key, 0.0, 1.0)?;
    if previous.is_some_and(|previous| at <= previous) {
        return fail(&key, "must be after the previous frame's");
    }
    Ok(at)
}

/// `[x, y, scale]` (or `[x, y]` for a site).
fn point(value: &Value, path: &str, with_scale: bool) -> Checked {
    let (x, y, scale) = match (array(value, path)?.as_slice(), with_scale) {
        ([x, y, scale], true) => (x, y, Some(scale)),
        ([x, y], false) => (x, y, None),
        _ => {
            return fail(path, if with_scale { "must be [x, y, scale]" } else { "must be [x, y]" });
        }
    };
    number(x, &format!("{path}[0]"), -MAX_OFFSET, MAX_OFFSET)?;
    number(y, &format!("{path}[1]"), -MAX_OFFSET, MAX_OFFSET)?;
    if let Some(scale) = scale {
        number(scale, &format!("{path}[2]"), 0.0, MAX_SCALE)?;
    }
    Ok(())
}

fn dots(value: &Value, path: &str, max: usize) -> Checked {
    let list = array(value, path)?;
    if list.len() > max {
        return fail(path, format!("has {} dots; particle.max allows {max}", list.len()));
    }
    for (index, dot) in list.iter().enumerate() {
        point(dot, &format!("{path}[{index}]"), true)?;
    }
    Ok(())
}

struct Context<'a> {
    max: usize,
    formations: Option<&'a Map<String, Value>>,
}

fn frames(value: &Value, path: &str, context: &Context<'_>) -> Checked {
    let list = array(value, path)?;
    if list.is_empty() || list.len() > MAX_FRAMES {
        return fail(path, format!("must hold 1 to {MAX_FRAMES} frames"));
    }
    let mut previous = None;
    for (index, frame) in list.iter().enumerate() {
        let here = format!("{path}[{index}]");
        let frame = object(frame, &here)?;
        only_keys(frame, &["at", "dots", "formation", "ease"], &here)?;
        previous = Some(at(frame.get("at"), &here, previous)?);
        match (frame.get("dots"), frame.get("formation")) {
            (Some(list), None) => dots(list, &join(&here, "dots"), context.max)?,
            (None, Some(name)) => {
                let key = join(&here, "formation");
                let Some(name) = name.as_str() else { return fail(&key, "must be a name") };
                let defined = context.formations.and_then(|f| f.get(name));
                if let Some(points) = defined {
                    let count = points.as_array().map_or(0, Vec::len);
                    if count > context.max {
                        return fail(
                            &key,
                            format!("has {count} dots; particle.max allows {}", context.max),
                        );
                    }
                } else if !BUILT_IN_FORMATIONS.contains(&name) {
                    return fail(&key, "is not a built-in or a defined formation");
                }
            }
            _ => return fail(&here, "needs exactly one of dots or formation"),
        }
        if let Some(value) = frame.get("ease") {
            ease(value, &join(&here, "ease"))?;
        }
    }
    Ok(())
}

fn generator(phase: &Map<String, Value>, path: &str, context: &Context<'_>) -> Checked {
    let need = |key: &str| {
        phase.get(key).map_or_else(|| fail(path, format!("a generated phase needs {key}")), Ok)
    };
    let sites_key = join(path, "sites");
    let sites = array(need("sites")?, &sites_key)?;
    if sites.is_empty() || sites.len() > MAX_DOTS {
        return fail(&sites_key, format!("must hold 1 to {MAX_DOTS} sites"));
    }
    for (index, site) in sites.iter().enumerate() {
        point(site, &format!("{sites_key}[{index}]"), false)?;
    }

    let spawn_key = join(path, "spawn");
    let spawn = object(need("spawn")?, &spawn_key)?;
    only_keys(spawn, &["every", "order", "life"], &spawn_key)?;
    let get =
        |key: &str| spawn.get(key).map_or_else(|| fail(&spawn_key, format!("needs {key}")), Ok);
    let every = duration(get("every")?, &join(&spawn_key, "every"))?;
    let life = duration(get("life")?, &join(&spawn_key, "life"))?;
    let order_key = join(&spawn_key, "order");
    let order = array(get("order")?, &order_key)?;
    if order.is_empty() || order.len() > MAX_FRAMES {
        return fail(&order_key, format!("must list 1 to {MAX_FRAMES} site indexes"));
    }
    for (index, site) in order.iter().enumerate() {
        match site.as_u64() {
            Some(site) if (site as usize) < sites.len() => {}
            _ => return fail(&format!("{order_key}[{index}]"), "must be a site index"),
        }
    }
    // Dots alive at once: a new one every `every` ms, each living `life` ms.
    let alive = (life / every).ceil() as usize;
    if alive > context.max {
        return fail(
            &spawn_key,
            format!("keeps {alive} dots alive at once; particle.max allows {}", context.max),
        );
    }

    let life_key = join(path, "lifeFrames");
    let life_frames = array(need("lifeFrames")?, &life_key)?;
    if life_frames.is_empty() || life_frames.len() > MAX_FRAMES {
        return fail(&life_key, format!("must hold 1 to {MAX_FRAMES} frames"));
    }
    let mut previous = None;
    for (index, frame) in life_frames.iter().enumerate() {
        let here = format!("{life_key}[{index}]");
        let frame = object(frame, &here)?;
        only_keys(frame, &["at", "pos", "offset", "s", "ease"], &here)?;
        previous = Some(at(frame.get("at"), &here, previous)?);
        match frame.get("pos").and_then(Value::as_str) {
            Some("centre" | "site" | "between") => {}
            _ => return fail(&join(&here, "pos"), "must be centre, site or between"),
        }
        if let Some(offset) = frame.get("offset") {
            point(offset, &join(&here, "offset"), false)?;
        }
        let scale = frame.get("s").map_or_else(|| fail(&here, "needs s"), Ok)?;
        number(scale, &join(&here, "s"), 0.0, MAX_SCALE)?;
        if let Some(value) = frame.get("ease") {
            ease(value, &join(&here, "ease"))?;
        }
    }
    Ok(())
}

fn phase(value: &Value, path: &str, context: &Context<'_>) -> Checked {
    let phase = object(value, path)?;
    only_keys(phase, &["duration", "ease", "frames", "sites", "spawn", "lifeFrames"], path)?;
    let length = phase.get("duration").map_or_else(|| fail(path, "needs duration"), Ok)?;
    duration(length, &join(path, "duration"))?;
    if let Some(value) = phase.get("ease") {
        ease(value, &join(path, "ease"))?;
    }
    let generated = ["sites", "spawn", "lifeFrames"].iter().any(|key| phase.contains_key(*key));
    if generated {
        generator(phase, path, context)?;
    }
    match phase.get("frames") {
        Some(list) => frames(list, &join(path, "frames"), context),
        // A generated phase may keep sampled frames beside its generator, for checking.
        None if generated => Ok(()),
        None => fail(path, "needs frames, or sites, spawn and lifeFrames"),
    }
}

fn program(value: &Value, path: &str, phases: &Map<String, Value>) -> Checked {
    let list = |value: &Value, path: &str, may_be_empty: bool| -> Checked {
        let names = array(value, path)?;
        if (!may_be_empty && names.is_empty()) || names.len() > MAX_NAMED {
            return fail(path, format!("must list 1 to {MAX_NAMED} phases"));
        }
        for (index, name) in names.iter().enumerate() {
            match name.as_str() {
                Some(name) if phases.contains_key(name) => {}
                _ => return fail(&format!("{path}[{index}]"), "is not a phase of this document"),
            }
        }
        Ok(())
    };
    if value.is_array() {
        return list(value, path, false);
    }
    // `{intro?, loop}`: the intro plays once, then the loop repeats.
    let map = object(value, path)?;
    only_keys(map, &["intro", "loop"], path)?;
    if let Some(intro) = map.get("intro") {
        list(intro, &join(path, "intro"), true)?;
    }
    let looped = map.get("loop").map_or_else(|| fail(path, "needs loop"), Ok)?;
    list(looped, &join(path, "loop"), false)
}

/// Checks a `cmux.particles/1` document: refuses unknown keys, anything past a limit, a frame with
/// more dots than `particle.max`, and a trigger naming a phase the document lacks.
pub fn validate(doc: &Value) -> Result<(), ChoreographyError> {
    let size = serde_json::to_vec(doc).map_or(usize::MAX, |bytes| bytes.len());
    if size > MAX_DOCUMENT_BYTES {
        return fail("", format!("is {size} bytes; the limit is {MAX_DOCUMENT_BYTES}"));
    }
    let root = object(doc, "")?;
    only_keys(root, &["$schema", "particle", "phases", "formations", "triggers"], "")?;
    if root.get("$schema").and_then(Value::as_str) != Some(SCHEMA) {
        return fail("$schema", format!("must be {SCHEMA}"));
    }

    let particle = object(root.get("particle").unwrap_or(&Value::Null), "particle")?;
    only_keys(particle, &["shape", "size", "color", "max"], "particle")?;
    if let Some(shape) = particle.get("shape")
        && !shape.as_str().is_some_and(|shape| SHAPES.contains(&shape))
    {
        return fail("particle.shape", format!("must be one of {}", SHAPES.join(", ")));
    }
    let size = particle.get("size").map_or_else(|| fail("particle", "needs size"), Ok)?;
    let size = number(size, "particle.size", 0.0, MAX_SIZE)?;
    if size <= 0.0 {
        return fail("particle.size", "must be more than 0");
    }
    if let Some(value) = particle.get("color") {
        color(value, "particle.color")?;
    }
    let max = match particle.get("max") {
        None => MAX_PARTICLES,
        Some(value) => match value.as_u64() {
            Some(max) if (1..=MAX_PARTICLES).contains(&max) => max,
            _ => {
                return fail(
                    "particle.max",
                    format!("must be an integer from 1 to {MAX_PARTICLES}"),
                );
            }
        },
    };

    let formations = match root.get("formations") {
        None => None,
        Some(value) => {
            let map = object(value, "formations")?;
            if map.len() > MAX_NAMED {
                return fail("formations", format!("may name at most {MAX_NAMED}"));
            }
            for (name, points) in map {
                let here = join("formations", name);
                if !name_ok(name) {
                    return fail(&here, "is not a name (letters, digits, - and _, up to 32)");
                }
                if BUILT_IN_FORMATIONS.contains(&name.as_str()) {
                    return fail(&here, "redefines a built-in formation");
                }
                dots(points, &here, MAX_DOTS)?;
            }
            Some(map)
        }
    };
    let context = Context { max: max as usize, formations };

    let phases = object(root.get("phases").unwrap_or(&Value::Null), "phases")?;
    if phases.is_empty() || phases.len() > MAX_PHASES {
        return fail("phases", format!("must hold 1 to {MAX_PHASES} phases"));
    }
    for (name, value) in phases {
        let here = join("phases", name);
        if !name_ok(name) {
            return fail(&here, "is not a name (letters, digits, - and _, up to 32)");
        }
        phase(value, &here, &context)?;
    }

    if let Some(triggers) = root.get("triggers") {
        let triggers = object(triggers, "triggers")?;
        for (kind, value) in triggers {
            let here = join("triggers", kind);
            if !TRIGGERS.contains(&kind.as_str()) {
                return fail(&here, "is not an acpmux tool kind or session state");
            }
            program(value, &here, phases)?;
        }
    }
    Ok(())
}

/// Validates the `choreography` prop of every `create` and `update` op in a scene batch, in place,
/// and a sidebar row's `indicator: {choreography, trigger}` (`cmux.sidebar.rows/1`): a refused
/// document becomes `null` (the renderers then draw nothing). Returns one message per refusal,
/// naming the node. A `choreography` that is a string (`"glyph"`, the look's thinking glyph setting,
/// which the settings owner checks) is a reference, not a document.
pub fn sanitize_scene_ops(ops: &mut Value) -> Vec<String> {
    let mut refused = Vec::new();
    let Some(list) = ops.as_array_mut() else { return refused };
    for op in list {
        let id = op.get("id").and_then(Value::as_str).unwrap_or("?").to_string();
        let Some(props) = op.get_mut("props").and_then(Value::as_object_mut) else { continue };
        if let Some(doc) = props.get_mut("choreography") {
            sanitize_document(doc, &format!("Particles {id}: choreography"), &mut refused);
        }
        if let Some(doc) = props
            .get_mut("indicator")
            .and_then(Value::as_object_mut)
            .and_then(|indicator| indicator.get_mut("choreography"))
            .filter(|doc| !doc.is_string())
        {
            sanitize_document(doc, &format!("row {id}: indicator.choreography"), &mut refused);
        }
    }
    refused
}

fn sanitize_document(doc: &mut Value, what: &str, refused: &mut Vec<String>) {
    if doc.is_null() {
        return;
    }
    if let Err(error) = validate(doc) {
        refused.push(format!("{what} refused: {error}"));
        *doc = Value::Null;
    }
}

#[cfg(test)]
#[path = "particles_tests.rs"]
mod tests;
