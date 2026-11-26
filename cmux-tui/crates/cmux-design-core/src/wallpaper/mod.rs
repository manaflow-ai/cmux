//! Wallpaper tint, live wallpaper picks and backdrop rules (time of day, sun, placement).
//!
//! The pure rules the Mac app's wallpaper Swift used to hold: the sun's position and events,
//! a time-of-day schedule, the location a zone implies, a picture's placement and the adjust
//! overlay's gestures, dynamic macOS pictures' frames and the desktop store's choice, the desktop
//! picture's fit, the agent glow, the shader wallpapers and their view clock, live wallpaper
//! manifests, the wallpaper light's geometry and CSS, and the playback signals. The crate reads
//! no clock, file or tz database: times are Unix seconds and zones come in as [`zone::Zone`].
//!
//! Ops: `wallpaper.NAME` (see [`call`]).

pub mod art_fit;
pub mod dynamic;
pub mod glow;
pub mod light;
pub mod live;
pub mod location;
pub mod placement;
pub mod shader;
pub mod signals;
pub mod sun;
pub mod time_of_day;
pub mod zone;

use crate::ops::{OpError, OpResult, parse, reply};
use location::Location;
use placement::{Placement, Rect, Size};
use serde::Deserialize;
use serde_json::{Value, json};
use std::collections::BTreeMap;
use zone::Zone;

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct At {
    location: Location,
    t: f64,
    #[serde(default)]
    zone: Zone,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Text {
    text: String,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Resolve {
    entries: Vec<time_of_day::Entry>,
    t: f64,
    location: Option<Location>,
    #[serde(default)]
    zone: Zone,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct LocationOf {
    identifier: String,
    seconds_from_gmt: i32,
    #[serde(default)]
    zones: BTreeMap<String, Location>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct PlacementIn {
    #[serde(default)]
    placement: Option<Placement>,
    #[serde(default)]
    image: Option<Size>,
    #[serde(default)]
    view: Option<Size>,
    #[serde(default)]
    bounds: Option<Rect>,
}

impl PlacementIn {
    fn placement(&self) -> Placement {
        self.placement.unwrap_or_default()
    }
    fn image(&self) -> Result<Size, OpError> {
        self.image.ok_or_else(|| OpError::Invalid("missing image".into()))
    }
    fn view(&self) -> Result<Size, OpError> {
        self.view.ok_or_else(|| OpError::Invalid("missing view".into()))
    }
    fn bounds(&self) -> Result<Rect, OpError> {
        self.bounds.ok_or_else(|| OpError::Invalid("missing bounds".into()))
    }
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct Drag {
    placement: Placement,
    image: Size,
    view: Size,
    #[serde(default)]
    dx: f64,
    #[serde(default)]
    dy: f64,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct OverlayDrag {
    placement: Placement,
    image: Size,
    view: Size,
    from: [f64; 2],
    to: [f64; 2],
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct FramesAt {
    frames: dynamic::Frames,
    t: f64,
    location: Location,
    #[serde(default)]
    zone: Zone,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct DynamicRead {
    #[serde(default)]
    solar: Option<Value>,
    #[serde(default)]
    h24: Option<Value>,
    #[serde(default)]
    apr: Option<Value>,
    count: usize,
    #[serde(default)]
    dark: bool,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct StoreChoiceFrame {
    #[serde(default)]
    frames: Option<dynamic::Frames>,
    #[serde(default)]
    motion: Option<dynamic::Motion>,
    t: f64,
    location: Location,
    #[serde(default)]
    zone: Zone,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct ArtFitRect {
    fit: art_fit::ArtFit,
    image: Size,
    bounds: Rect,
    #[serde(default = "one")]
    points_per_pixel: f64,
}

fn one() -> f64 {
    1.0
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct ShaderStep {
    clock: shader::Clock,
    #[serde(flatten)]
    step: shader::Step,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct ShaderAt {
    clock: shader::Clock,
    #[serde(default = "unit")]
    scale: [f64; 2],
    #[serde(default)]
    ceiling: Option<f64>,
    #[serde(default)]
    warm: bool,
    #[serde(default)]
    point: [f64; 2],
}

fn unit() -> [f64; 2] {
    [1.0, 1.0]
}

/// Runs `wallpaper.NAME`.
pub fn call(name: &str, request: &Value) -> OpResult {
    match name {
        "sunPosition" => {
            let r: At = parse(request)?;
            reply(&sun::sun_position(&r.location, r.t))
        }
        "sunEvents" => {
            let r: At = parse(request)?;
            reply(&sun::sun_events(&r.location, r.t, &r.zone))
        }
        "sunAngle" => {
            #[derive(Deserialize)]
            struct R {
                a: sun::SunPosition,
                b: sun::SunPosition,
            }
            let r: R = parse(request)?;
            reply(&json!({"angle": r.a.angle(&r.b), "aIsDark": r.a.is_dark()}))
        }
        "timeOfDayWhen" => {
            let r: Text = parse(request)?;
            reply(&time_of_day::when(&r.text))
        }
        "timeOfDayParse" => {
            let members: BTreeMap<String, String> = parse(request)?;
            reply(&time_of_day::parse(&members, |_| true))
        }
        "timeOfDayResolve" => {
            let r: Resolve = parse(request)?;
            let entries = time_of_day::sorted(r.entries);
            reply(&time_of_day::resolve(&entries, r.t, r.location.as_ref(), &r.zone))
        }
        "locationParse" => {
            let r: Text = parse(request)?;
            reply(&Location::parse(&r.text))
        }
        "locationCoordinates" => {
            let r: Text = parse(request)?;
            reply(&location::coordinates(&r.text))
        }
        "zoneTable" => {
            let r: Text = parse(request)?;
            reply(&location::parse_zone_table(&r.text))
        }
        "locationOf" => {
            let r: LocationOf = parse(request)?;
            reply(&Location::of(&r.identifier, r.seconds_from_gmt, &r.zones))
        }
        "placementParse" => {
            let r: Text = parse(request)?;
            reply(&Placement::parse(&r.text))
        }
        "placementText" => {
            let r: PlacementIn = parse(request)?;
            reply(&r.placement().text())
        }
        "placementRect" => {
            let r: PlacementIn = parse(request)?;
            reply(&r.placement().rect(r.image()?, r.view()?))
        }
        "placementVisible" => {
            let r: PlacementIn = parse(request)?;
            reply(&r.placement().visible(r.image()?, r.view()?))
        }
        "placementLayerFrame" => {
            let r: PlacementIn = parse(request)?;
            reply(&r.placement().layer_frame(r.image()?, r.bounds()?))
        }
        "placementDrawnFrame" => {
            let r: PlacementIn = parse(request)?;
            reply(&r.placement().drawn_frame(r.image()?, r.bounds()?))
        }
        "placementDrag" => {
            let r: Drag = parse(request)?;
            reply(&r.placement.dragged(r.image, r.view, r.dx, r.dy))
        }
        "placementZoom" => {
            #[derive(Deserialize)]
            struct R {
                placement: Placement,
                factor: f64,
            }
            let r: R = parse(request)?;
            reply(&r.placement.zoomed(r.factor))
        }
        "placementKey" => {
            #[derive(Deserialize)]
            #[serde(rename_all = "camelCase")]
            struct R {
                picture_id: String,
            }
            let r: R = parse(request)?;
            reply(&placement::key(&r.picture_id))
        }
        "placementMap" => {
            let raw: BTreeMap<String, Value> = parse(request)?;
            let texts = raw
                .into_iter()
                .filter_map(|(k, v)| v.as_str().map(|s| (k, s.to_string())))
                .collect();
            reply(&placement::map(&texts))
        }
        "overlayDrag" => {
            let r: OverlayDrag = parse(request)?;
            let from = (r.from[0], r.from[1]);
            let to = (r.to[0], r.to[1]);
            reply(&placement::overlay_dragged(&r.placement, r.image, r.view, from, to))
        }
        "scrollZoom" => {
            #[derive(Deserialize)]
            #[serde(rename_all = "camelCase")]
            struct R {
                delta_y: f64,
                #[serde(default)]
                precise: bool,
            }
            let r: R = parse(request)?;
            reply(&placement::scroll_zoom(r.delta_y, r.precise))
        }
        "overlayChoose" => {
            #[derive(Deserialize)]
            struct R {
                choice: placement::Choice,
                #[serde(default)]
                placement: Placement,
            }
            let r: R = parse(request)?;
            reply(&placement::choose(r.choice, &r.placement))
        }
        "dynamicFrame" => {
            let r: FramesAt = parse(request)?;
            reply(&r.frames.frame(r.t, &r.location, &r.zone))
        }
        "dynamicNextChange" => {
            let r: FramesAt = parse(request)?;
            reply(&r.frames.next_change(r.t, &r.location, &r.zone))
        }
        "dynamicRead" => {
            let r: DynamicRead = parse(request)?;
            reply(&dynamic::read(r.solar.as_ref(), r.h24.as_ref(), r.apr.as_ref(), r.count))
        }
        "appearanceFrame" => {
            let r: DynamicRead = parse(request)?;
            let (apr, solar, h24) = (r.apr.as_ref(), r.solar.as_ref(), r.h24.as_ref());
            reply(&dynamic::appearance_frame(apr, solar, h24, r.dark, r.count))
        }
        "storeChoiceRead" => {
            #[derive(Deserialize)]
            struct R {
                root: Value,
                #[serde(default)]
                display: Option<String>,
            }
            let r: R = parse(request)?;
            let choice = dynamic::read_store(&r.root, r.display.as_deref());
            reply(&choice.map(|c| {
                json!({
                    "provider": c.provider,
                    "strings": c.strings,
                    "isAerial": c.is_aerial(),
                    "aerialIds": c.aerial_ids(),
                    "files": c.files(),
                    "motion": c.motion(),
                })
            }))
        }
        "storeChoiceFrame" => {
            let r: StoreChoiceFrame = parse(request)?;
            reply(&dynamic::frame_of(r.frames.as_ref(), r.motion, r.t, &r.location, &r.zone))
        }
        "momentUntil" => {
            #[derive(Deserialize)]
            struct R {
                next: Option<f64>,
                t: f64,
            }
            let r: R = parse(request)?;
            reply(&dynamic::moment_until(r.next, r.t))
        }
        "artFit" => {
            #[derive(Deserialize)]
            #[serde(rename_all = "camelCase")]
            struct R {
                image_scaling: Option<i64>,
                allow_clipping: Option<bool>,
            }
            let r: R = parse(request)?;
            let fit = art_fit::ArtFit::from_options(r.image_scaling, r.allow_clipping);
            reply(&json!({"fit": fit, "showsFill": fit.shows_fill()}))
        }
        "artFitRect" => {
            let r: ArtFitRect = parse(request)?;
            reply(&r.fit.rect(r.image, r.bounds, r.points_per_pixel))
        }
        "agentGlow" => {
            #[derive(Deserialize)]
            struct R {
                agents: Vec<glow::Agent>,
            }
            let r: R = parse(request)?;
            reply(&glow::glow(&r.agents))
        }
        "shaders" => reply(&shader::all()),
        "shaderId" => {
            #[derive(Deserialize)]
            struct R {
                id: String,
            }
            let r: R = parse(request)?;
            reply(&shader::from_id(&r.id))
        }
        "posterName" => {
            #[derive(Deserialize)]
            struct R {
                raw: String,
                dark: bool,
            }
            let r: R = parse(request)?;
            reply(&shader::poster_name(&r.raw, r.dark))
        }
        "posterParse" => {
            #[derive(Deserialize)]
            #[serde(rename_all = "camelCase")]
            struct R {
                file_name: String,
            }
            let r: R = parse(request)?;
            reply(&shader::poster(&r.file_name).map(|(s, dark)| json!({"shader": s, "dark": dark})))
        }
        "shaderAdvance" => {
            let mut r: ShaderStep = parse(request)?;
            r.clock.advance(&r.step);
            reply(&r.clock)
        }
        "shaderResumed" => {
            let mut r: ShaderAt = parse(request)?;
            r.clock.resumed();
            reply(&r.clock)
        }
        "shaderFps" => {
            let r: ShaderAt = parse(request)?;
            let ceiling = r.ceiling.unwrap_or_else(|| shader::ceiling(r.warm));
            reply(&json!({
                "lively": r.clock.lively(r.scale),
                "fps": r.clock.frames_per_second(r.scale, ceiling),
            }))
        }
        "shaderRing" => {
            let mut r: ShaderAt = parse(request)?;
            r.clock.ring(r.point, r.scale);
            reply(&r.clock)
        }
        "frameDue" => {
            #[derive(Deserialize)]
            #[serde(rename_all = "camelCase")]
            struct R {
                since_drawn: f64,
                fps: f64,
            }
            let r: R = parse(request)?;
            reply(&shader::frame_due(r.since_drawn, r.fps))
        }
        "holdReasonName" => {
            #[derive(Deserialize)]
            struct R {
                reason: u8,
            }
            let r: R = parse(request)?;
            reply(&live::hold_reason_name(r.reason))
        }
        "liveDigest" => {
            #[derive(Deserialize)]
            struct R {
                source: Option<String>,
            }
            let r: R = parse(request)?;
            reply(&format!("{:x}", live::digest(r.source.as_deref().map(str::as_bytes))))
        }
        "liveManifest" => reply(&live::manifest(request)),
        "liveStill" => {
            #[derive(Deserialize)]
            struct R {
                manifest: live::Manifest,
                width: u32,
                height: u32,
            }
            let r: R = parse(request)?;
            reply(&live::still(&r.manifest, r.width, r.height))
        }
        "lightGeometry" => {
            #[derive(Deserialize)]
            struct R {
                rect: Rect,
                container: Rect,
            }
            let r: R = parse(request)?;
            reply(&light::geometry(r.rect, r.container))
        }
        "lightCss" => {
            let r: light::PageLight = parse(request)?;
            reply(&light::css(&r))
        }
        "playbackSignal" => {
            #[derive(Deserialize)]
            struct R {
                #[serde(default)]
                state: signals::Playback,
                name: String,
            }
            let r: R = parse(request)?;
            let (state, signal) = signals::note(r.state, &r.name);
            reply(&json!({"state": state, "signal": signal}))
        }
        "desktopShownSelection" => {
            #[derive(Deserialize)]
            struct R {
                path: String,
                frame: Option<usize>,
                #[serde(default)]
                dark: bool,
            }
            let r: R = parse(request)?;
            reply(&signals::selection(&r.path, r.frame, r.dark))
        }
        _ => Err(OpError::Unknown),
    }
}
