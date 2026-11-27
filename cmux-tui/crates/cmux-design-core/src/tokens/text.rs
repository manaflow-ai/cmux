//! Chrome text rules, as values: ports the pure logic of CmuxNextDesign `Text/`:
//! `FontSmoothing.swift` and `ProcessFontSmoothing.swift` ([`smoothing`]), `GlyphMask.swift`
//! ([`glyph_mask`]), `LabelText.swift` and `ChromeLabel.swift` ([`label`]), `TitleRoll.swift`,
//! `TitleFade.swift` and `MarqueeLabel.swift` ([`title`]) and `ChromeTextRefresh.swift`
//! ([`refresh`]). AppKit, TextKit, Core Graphics and Core Animation stay in Swift; what they
//! measure or hold comes in as inputs.
//!
//! Ops (`tokens.NAME`): `text_font_smoothing`, `text_font_smoothing_parse`,
//! `text_smooths_stems`, `text_apply_smoothing`, `text_glyph_weight_key`, `text_glyph_weight`,
//! `text_glyph_image_pixels`, `text_glyph_place`, `text_glyph_constants`,
//! `text_label_line_metrics`, `text_label_empty_metrics`, `text_label_paragraph`,
//! `text_label_configure`, `text_label_layout_height`, `text_label_measuring`,
//! `text_label_laid_out_metrics`, `text_label_trailing_spaces`, `text_label_trim_rect`,
//! `text_label_ellipsized`, `text_label_draw_clip`, `text_label_wrap_width`,
//! `text_label_intrinsic`, `text_label_size_for_width`, `text_label_frame_size`,
//! `text_label_frame_change`, `text_label_line_break`, `text_label_glyph_update`,
//! `text_label_accessibility_frame`, `text_label_accessibility_range`, `text_roll`,
//! `text_roll_plan`, `text_roll_end`, `text_roll_constants`, `text_fade_unclipped`,
//! `text_fade_clipped`, `text_fade_follow`, `text_fade_marquee_start`, `text_fade_stop`,
//! `text_fade_drop_mask`, `text_marquee_intrinsic`, `text_marquee_geometry`, `text_refresh`.

pub mod glyph_mask;
pub mod label;
pub mod refresh;
pub mod smoothing;
pub mod title;

use crate::ops::{OpError, OpResult, parse, reply};
use label::{Alignment, FontLine, LabelState, LineBreak, Rect, Shape, Size};
use serde::Deserialize;
use serde_json::{Value, json};
use smoothing::FontSmoothing;

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct ModeRequest {
    mode: FontSmoothing,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct RawRequest {
    raw: String,
}

#[derive(Deserialize, Default)]
#[serde(rename_all = "camelCase", default)]
struct ValueRequest {
    value: Option<i64>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
struct ApplyRequest {
    mode: FontSmoothing,
    #[serde(default)]
    saved: Option<i64>,
    #[serde(default)]
    global: Option<i64>,
}

#[derive(Deserialize, Default)]
#[serde(rename_all = "camelCase", default)]
struct WeightKeyRequest {
    ink: Option<Vec<f64>>,
    smooths_stems: bool,
}

#[derive(Deserialize, Default)]
#[serde(rename_all = "camelCase", default)]
struct WeightRequest {
    measured: i64,
    smooths_stems: bool,
}

#[derive(Deserialize, Default)]
#[serde(rename_all = "camelCase", default)]
struct PlaceRequest {
    width: f64,
    height: f64,
    scale: f64,
    flipped_chain: Vec<bool>,
}

#[derive(Deserialize, Default)]
#[serde(rename_all = "camelCase", default)]
struct FontsRequest {
    fonts: Vec<FontLine>,
    text_is_empty: bool,
    width: Option<f64>,
    scale: f64,
}

#[derive(Deserialize, Default)]
#[serde(rename_all = "camelCase", default)]
struct ShapeRequest {
    shape: Shape,
    own_alignment: Option<Alignment>,
    has_own_style: bool,
    width: Option<f64>,
    height: Option<f64>,
    frame_width: f64,
}

#[derive(Deserialize, Default)]
#[serde(rename_all = "camelCase", default)]
struct LaidOutRequest {
    has_text: bool,
    used_max_x: f64,
    used_max_y: f64,
    first_baseline: Option<f64>,
    last_baseline: Option<f64>,
    scale: f64,
}

#[derive(Deserialize, Default)]
#[serde(rename_all = "camelCase", default)]
struct TextRangeRequest {
    text: String,
    start: usize,
    end: usize,
    shape: Shape,
    shown_end: usize,
}

#[derive(Deserialize, Default)]
#[serde(rename_all = "camelCase", default)]
struct TrimRequest {
    used: Rect,
    kept_max_x: f64,
}

#[derive(Deserialize, Default)]
#[serde(rename_all = "camelCase", default)]
struct ClipRequest {
    last_line_min_y: f64,
    width: f64,
    height: f64,
}

#[derive(Deserialize, Default)]
#[serde(rename_all = "camelCase", default)]
struct LabelRequest {
    label: LabelState,
    line: Size,
    measured: Size,
    width_changed: bool,
}

#[derive(Deserialize, Default)]
#[serde(rename_all = "camelCase", default)]
struct SizeRequest {
    size: Size,
}

#[derive(Deserialize, Default)]
#[serde(rename_all = "camelCase", default)]
struct LineBreakRequest {
    mode: LineBreak,
    wraps: Option<bool>,
}

#[derive(Deserialize, Default)]
#[serde(rename_all = "camelCase", default)]
struct GlyphUpdateRequest {
    drawn: Option<DrawnRequest>,
    kept_for_weight: bool,
    text_is_empty: bool,
}

#[derive(Deserialize, Default)]
#[serde(rename_all = "camelCase", default)]
struct DrawnRequest {
    same_ink: bool,
    same_weight: bool,
}

#[derive(Deserialize, Default)]
#[serde(rename_all = "camelCase", default)]
struct AccessibilityRequest {
    bounds: Rect,
    location: i64,
    length: i64,
    content_length: i64,
}

#[derive(Deserialize, Default)]
#[serde(rename_all = "camelCase", default)]
struct RollPlanRequest {
    point_size: f64,
    flipped: bool,
    opacity: f64,
    rest: f64,
}

#[derive(Deserialize, Default)]
#[serde(rename_all = "camelCase", default)]
struct RollEndRequest {
    host_has_roll_out: bool,
    text_in_host: bool,
}

#[derive(Deserialize, Default)]
#[serde(rename_all = "camelCase", default)]
struct UnclippedRequest {
    animated: bool,
    returning: bool,
    masked: bool,
    leading_padding: f64,
    width: f64,
    current: Option<Vec<f64>>,
    shown: Option<Vec<f64>>,
}

#[derive(Deserialize, Default)]
#[serde(rename_all = "camelCase", default)]
struct ClippedRequest {
    animated: bool,
    current: Option<Vec<f64>>,
    locations: [f64; 5],
    was_masked: bool,
    marquee_active: bool,
    previous_travel: Option<f64>,
    travel: f64,
}

#[derive(Deserialize, Default)]
#[serde(rename_all = "camelCase", default)]
struct FollowSample {
    shown: bool,
    span: f64,
    truncated: bool,
    mask_locations: [f64; 5],
    leading_padding: f64,
}

#[derive(Deserialize, Default)]
#[serde(rename_all = "camelCase", default)]
struct FollowRequest {
    target_text_width: f64,
    samples: Vec<FollowSample>,
}

#[derive(Deserialize, Default)]
#[serde(rename_all = "camelCase", default)]
struct MarqueeStartRequest {
    #[serde(flatten)]
    start: title::MarqueeStart,
    rest: [f64; 5],
    scrolled: [f64; 5],
    fade_width: f64,
    leading_padding: f64,
}

#[derive(Deserialize, Default)]
#[serde(rename_all = "camelCase", default)]
struct StopRequest {
    animated: bool,
    shown: f64,
    animates_movement: bool,
    shown_stops: Option<Vec<f64>>,
    rest: Option<Vec<f64>>,
}

#[derive(Deserialize, Default)]
#[serde(rename_all = "camelCase", default)]
struct DropMaskRequest {
    truncated: Option<bool>,
    masked: bool,
    sliding: bool,
    stops_animating: bool,
}

#[derive(Deserialize, Default)]
#[serde(rename_all = "camelCase", default)]
struct MarqueeRequest {
    text_width: f64,
    ascender: f64,
    descender: f64,
    leading: f64,
    bounds_width: f64,
    trailing_occlusion: f64,
    leading_padding: f64,
    fade_width: f64,
}

fn utf16(text: &str) -> Vec<u16> {
    text.encode_utf16().collect()
}

/// Runs the `tokens.text_*` ops.
pub fn call(name: &str, request: &Value) -> OpResult {
    match name {
        "text_font_smoothing" => {
            let r: ModeRequest = parse(request)?;
            reply(&json!({"rawValue": r.mode.raw_value(), "cssValue": r.mode.css_value()}))
        }
        "text_font_smoothing_parse" => {
            let r: RawRequest = parse(request)?;
            reply(&json!({"mode": FontSmoothing::from_raw(&r.raw)}))
        }
        "text_smooths_stems" => {
            let r: ValueRequest = parse(request)?;
            reply(
                &json!({"smoothsStems": smoothing::smooths_stems(r.value), "defaultsKey": smoothing::DEFAULTS_KEY}),
            )
        }
        "text_apply_smoothing" => {
            let r: ApplyRequest = parse(request)?;
            reply(&smoothing::apply(r.mode, r.saved, r.global))
        }
        "text_glyph_weight_key" => {
            let r: WeightKeyRequest = parse(request)?;
            let rgb = glyph_mask::components(r.ink.as_deref());
            reply(&json!({"components": rgb, "key": glyph_mask::weight_key(rgb, r.smooths_stems)}))
        }
        "text_glyph_weight" => {
            let r: WeightRequest = parse(request)?;
            reply(&json!({"weight": glyph_mask::weight(r.measured, r.smooths_stems)}))
        }
        "text_glyph_image_pixels" => {
            let r: PlaceRequest = parse(request)?;
            reply(&json!({"pixels": glyph_mask::image_pixels(r.width, r.height, r.scale)}))
        }
        "text_glyph_place" => {
            let r: PlaceRequest = parse(request)?;
            let top_down = glyph_mask::renders_top_down(&r.flipped_chain);
            reply(&glyph_mask::place(r.width, r.height, r.scale, top_down))
        }
        "text_glyph_constants" => reply(&json!({
            "weightCacheLimit": glyph_mask::WEIGHT_CACHE_LIMIT,
            "measureString": glyph_mask::MEASURE_STRING,
            "measureWidth": glyph_mask::MEASURE_WIDTH,
            "measureHeight": glyph_mask::MEASURE_HEIGHT,
            "referenceScale": glyph_mask::REFERENCE_SCALE,
            "referenceTextPosition": glyph_mask::REFERENCE_TEXT_POSITION,
            "warmString": glyph_mask::WARM_STRING,
            "warmWidth": glyph_mask::WARM_WIDTH,
            "warmHeight": glyph_mask::WARM_HEIGHT,
            "warmWeights": glyph_mask::WARM_WEIGHTS,
        })),
        "text_label_line_metrics" => {
            let r: FontsRequest = parse(request)?;
            let line = label::whole_point_line(&r.fonts)
                .map(|(ascent, height)| json!({"ascent": ascent, "height": height}));
            reply(&json!({"line": line}))
        }
        "text_label_empty_metrics" => {
            let r: FontsRequest = parse(request)?;
            reply(
                &json!({"metrics": label::empty_line_metrics(r.text_is_empty, r.width, &r.fonts, r.scale)}),
            )
        }
        "text_label_paragraph" => {
            let r: ShapeRequest = parse(request)?;
            reply(&json!({
                "lineBreak": label::paragraph_line_break(&r.shape),
                "alignment": label::paragraph_alignment(r.own_alignment, &r.shape),
                "takesStrategy": label::paragraph_takes_strategy(r.has_own_style),
                "isMultiline": r.shape.is_multiline(),
            }))
        }
        "text_label_configure" => {
            let r: ShapeRequest = parse(request)?;
            reply(&label::configure(&r.shape, r.width, r.height))
        }
        "text_label_layout_height" => {
            let r: ShapeRequest = parse(request)?;
            reply(&json!({"height": label::layout_height(&r.shape, r.height.unwrap_or(0.0))}))
        }
        "text_label_measuring" => {
            let r: ShapeRequest = parse(request)?;
            let (shape, shown_lines) = label::measuring_shape(&r.shape);
            reply(
                &json!({"shape": shape, "shownLines": shown_lines, "width": label::measuring_width(r.width)}),
            )
        }
        "text_label_laid_out_metrics" => {
            let r: LaidOutRequest = parse(request)?;
            reply(&label::laid_out_metrics(
                r.has_text,
                r.used_max_x,
                r.used_max_y,
                r.first_baseline,
                r.last_baseline,
                r.scale,
            ))
        }
        "text_label_trailing_spaces" => {
            let r: TextRangeRequest = parse(request)?;
            let units = utf16(&r.text);
            if r.start > r.end || r.end > units.len() {
                return Err(OpError::Invalid("range outside the text".into()));
            }
            let kept = label::trailing_space_end(&units, r.start, r.end);
            reply(
                &json!({"keptEnd": kept, "trims": label::trims_trailing_spaces(r.start, r.end, kept)}),
            )
        }
        "text_label_trim_rect" => {
            let r: TrimRequest = parse(request)?;
            reply(&label::without_trailing_spaces(r.used, r.kept_max_x))
        }
        "text_label_ellipsized" => {
            let r: TextRangeRequest = parse(request)?;
            let cut = label::ellipsized(&r.shape, &utf16(&r.text), r.shown_end).map(
                |(text, at)| json!({"text": String::from_utf16_lossy(&text), "attributesAt": at}),
            );
            reply(&json!({"cut": cut}))
        }
        "text_label_draw_clip" => {
            let r: ClipRequest = parse(request)?;
            reply(&json!({"clip": label::draw_clip(r.last_line_min_y, r.width, r.height)}))
        }
        "text_label_wrap_width" => {
            let r: LabelRequest = parse(request)?;
            reply(&json!({"wrapWidth": label::wrap_width(&r.label)}))
        }
        "text_label_intrinsic" => {
            let r: LabelRequest = parse(request)?;
            reply(&json!({
                "measureWidth": label::intrinsic_measure_width(&r.label),
                "size": label::intrinsic_size(&r.label, r.line, r.measured),
            }))
        }
        "text_label_size_for_width" => {
            let r: ShapeRequest = parse(request)?;
            reply(&json!({"measureWidth": label::size_for_width_measure(&r.shape, r.frame_width)}))
        }
        "text_label_frame_size" => {
            let r: SizeRequest = parse(request)?;
            reply(&label::frame_size(r.size))
        }
        "text_label_frame_change" => {
            let r: LabelRequest = parse(request)?;
            reply(
                &json!({"invalidatesIntrinsic": label::frame_change_invalidates_intrinsic(&r.label, r.width_changed)}),
            )
        }
        "text_label_line_break" => {
            let r: LineBreakRequest = parse(request)?;
            reply(&json!({
                "wraps": label::wraps_for_line_break(r.mode),
                "lineBreak": r.wraps.map(|w| label::line_break_for_wraps(w, r.mode)),
            }))
        }
        "text_label_glyph_update" => {
            let r: GlyphUpdateRequest = parse(request)?;
            let drawn = r.drawn.map(|d| (d.same_ink, d.same_weight));
            reply(&label::glyph_update(drawn, r.kept_for_weight, r.text_is_empty))
        }
        "text_label_accessibility_frame" => {
            let r: AccessibilityRequest = parse(request)?;
            reply(&json!({"frame": label::accessibility_frame(r.bounds)}))
        }
        "text_label_accessibility_range" => {
            let r: AccessibilityRequest = parse(request)?;
            reply(
                &json!({"valid": label::accessibility_range_valid(r.location, r.length, r.content_length)}),
            )
        }
        "text_roll" => {
            let r: title::RollInput = parse(request)?;
            reply(&json!({"rolls": title::rolls(&r)}))
        }
        "text_roll_plan" => {
            let r: RollPlanRequest = parse(request)?;
            reply(&title::roll_plan(r.point_size, r.flipped, r.opacity, r.rest))
        }
        "text_roll_end" => {
            let r: RollEndRequest = parse(request)?;
            reply(
                &json!({"clearsBlur": title::roll_end_clears_blur(r.host_has_roll_out, r.text_in_host)}),
            )
        }
        "text_roll_constants" => reply(&json!({
            "rollOutName": title::ROLL_OUT_NAME,
            "blurPath": title::BLUR_PATH,
            "riseEm": title::ROLL_RISE_EM,
            "blurRadius": title::ROLL_BLUR_RADIUS,
            "cancelKeys": title::ROLL_KEYS,
        })),
        "text_fade_unclipped" => {
            let r: UnclippedRequest = parse(request)?;
            let open = title::open_locations(r.leading_padding, r.width);
            reply(&json!({
                "keepsMask": title::unclipped_keeps_mask(r.animated, r.returning, r.masked),
                "open": open,
                "settled": title::unclipped_settled(r.current.as_deref(), open),
                "from": title::unclipped_from(r.shown.as_deref().or(r.current.as_deref()), open),
            }))
        }
        "text_fade_clipped" => {
            let r: ClippedRequest = parse(request)?;
            reply(&json!({
                "stops": title::clipped_stops(r.animated, r.current.as_deref(), r.locations, r.was_masked),
                "restartsMarquee": title::restarts_marquee(r.marquee_active, r.previous_travel, r.travel),
            }))
        }
        "text_fade_follow" => {
            let r: FollowRequest = parse(request)?;
            let spans: Vec<f64> = r.samples.iter().filter(|s| s.shown).map(|s| s.span).collect();
            let shown: Vec<bool> = r.samples.iter().map(|s| s.shown).collect();
            let filled = title::follow_filled(&shown);
            let stops: Option<Vec<[f64; 5]>> = filled.as_ref().map(|idx| {
                idx.iter()
                    .filter_map(|i| r.samples.get(*i))
                    .map(|s| {
                        title::follow_locations(
                            s.truncated,
                            s.mask_locations,
                            s.leading_padding,
                            s.span,
                        )
                    })
                    .collect()
            });
            reply(&json!({
                "width": filled.as_ref().map(|_| title::follow_width(r.target_text_width, &spans)),
                "filled": filled,
                "stopsChange": stops.as_deref().map(title::follow_changes),
                "stops": stops,
            }))
        }
        "text_fade_marquee_start" => {
            let r: MarqueeStartRequest = parse(request)?;
            reply(&json!({
                "starts": title::starts_marquee(&r.start),
                "edgeReach": title::marquee_edge(r.rest, r.scrolled, r.fade_width, r.leading_padding),
            }))
        }
        "text_fade_stop" => {
            let r: StopRequest = parse(request)?;
            reply(&json!({
                "springsBack": title::springs_back(r.animated, r.shown, r.animates_movement),
                "easesEdgeBack": title::eases_edge_back(r.shown_stops.as_deref(), r.rest.as_deref()),
            }))
        }
        "text_fade_drop_mask" => {
            let r: DropMaskRequest = parse(request)?;
            reply(
                &json!({"drops": title::drops_open_mask(r.truncated, r.masked, r.sliding, r.stops_animating)}),
            )
        }
        "text_marquee_intrinsic" => {
            let r: MarqueeRequest = parse(request)?;
            let (width, height) =
                title::marquee_intrinsic_size(r.text_width, r.ascender, r.descender, r.leading);
            reply(&json!({"width": width, "height": height}))
        }
        "text_marquee_geometry" => {
            let r: MarqueeRequest = parse(request)?;
            reply(&title::marquee_geometry_input(
                r.text_width,
                r.bounds_width,
                r.trailing_occlusion,
                r.leading_padding,
                r.fade_width,
            ))
        }
        "text_refresh" => {
            let r: refresh::LayerNode = parse(request)?;
            reply(&json!({"refresh": refresh::refresh(&r)}))
        }
        _ => Err(OpError::Unknown),
    }
}
