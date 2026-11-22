//! Render and browser attach wire messages: the vt-state replay shape, the
//! render-state / render-delta / render-graphics JSON a render attach client
//! receives, the per-client render state that computes deltas, and the
//! browser-state and frame payloads. Owns only serialization; the transport
//! (`MessageWriter`, `OutboundStream`) and the graphics cache
//! (`RenderService`) stay in the parent module.

use std::collections::HashSet;
use std::io::Write;
use std::sync::Arc;

use ghostty_vt::{Dirty, KittyReplayState, StyledRun, UnderlineStyle};
use serde::Serialize;
use serde_json::{Value, json};

use super::{
    BudgetedJsonWriter, MessageWriter, OutboundStream, RenderService, write_base64_json_string,
};
use crate::browser::{BrowserAttachUpdate, BrowserFrameUpdate};
use crate::{BrowserAttachState, Rgb, SurfaceId, SurfaceRenderFrame};

pub(super) struct VtStateMessage {
    pub(super) surface: SurfaceId,
    pub(super) cols: u16,
    pub(super) rows: u16,
    pub(super) replay: Arc<[u8]>,
    pub(super) kitty_image_aliases: Vec<ghostty_vt::KittyImageAlias>,
    pub(super) kitty_state: KittyReplayState,
    pub(super) colors: Value,
    pub(super) pending_sequence: Arc<[u8]>,
}

/// Additive attach-event fields captured from the client's advertised
/// capabilities when it attaches.
#[derive(Clone, Copy, Debug, Default)]
pub(super) struct AttachWireShape {
    pub(super) color_overrides: bool,
    pub(super) pending_sequence: bool,
}

/// Appends the optional `pending` field: the incomplete sequence a replay's
/// source parser is inside. Clients write it after the replay and its colors,
/// immediately before the live stream. Omitted when the parser is at a
/// boundary, so those events are unchanged for older clients.
pub(super) fn write_pending_sequence_json(
    writer: &mut BudgetedJsonWriter,
    pending: &[u8],
) -> std::io::Result<()> {
    if pending.is_empty() {
        return Ok(());
    }
    writer.write_all(b",\"pending\":\"")?;
    write_base64_json_string(writer, pending)?;
    writer.write_all(b"\"")
}

fn rgb_hex(color: Rgb) -> String {
    format!("#{:02x}{:02x}{:02x}", color.r, color.g, color.b)
}

pub(super) fn styled_run_json(run: &StyledRun) -> Value {
    let underline = run.underline.map(|style| match style {
        UnderlineStyle::Single => "single",
        UnderlineStyle::Double => "double",
        UnderlineStyle::Curly => "curly",
        UnderlineStyle::Dotted => "dotted",
        UnderlineStyle::Dashed => "dashed",
    });
    let mut value = json!({
        "text": run.text,
        "fg": run.fg.map(rgb_hex),
        "bg": run.bg.map(rgb_hex),
        "attrs": run.attrs,
    });
    if let Some(underline) = underline {
        value["underline"] = json!(underline);
    }
    if let Some(width_hint) = run.width_hint {
        value["width_hint"] = json!(width_hint);
    }
    value
}

fn render_rows_json(frame: &SurfaceRenderFrame, rows: impl IntoIterator<Item = u16>) -> Vec<Value> {
    rows.into_iter()
        .filter_map(|row| {
            frame.frame.row_runs(row).map(|runs| {
                json!({
                    "row": row,
                    "runs": runs.iter().map(styled_run_json).collect::<Vec<_>>(),
                })
            })
        })
        .collect()
}

fn render_cursor_json(frame: &SurfaceRenderFrame) -> Value {
    let (style, blink) = frame.frame.cursor_visual;
    let style = match style {
        ghostty_vt::CursorShape::Bar => "bar",
        ghostty_vt::CursorShape::Underline => "underline",
        ghostty_vt::CursorShape::Block | ghostty_vt::CursorShape::BlockHollow => "block",
    };
    let (x, y, visible) =
        frame.frame.cursor.map(|cursor| (cursor.x, cursor.y, true)).unwrap_or((0, 0, false));
    json!({
        "x": x,
        "y": y,
        "style": style,
        "blink": blink,
        "visible": visible,
        "color": frame.frame.cursor_color.map(rgb_hex),
    })
}

fn serialize_arc_str<S>(value: &Arc<str>, serializer: S) -> Result<S::Ok, S::Error>
where
    S: serde::Serializer,
{
    serializer.serialize_str(value)
}

#[derive(Serialize)]
pub(super) struct RenderGraphicImageMessage {
    pub(super) id: u32,
    pub(super) generation: u64,
    pub(super) width: u32,
    pub(super) height: u32,
    pub(super) format: &'static str,
    #[serde(serialize_with = "serialize_arc_str")]
    pub(super) data: Arc<str>,
}

#[derive(Serialize)]
pub(super) struct RenderGraphicPlacementMessage {
    pub(super) image_id: u32,
    pub(super) placement_id: u32,
    pub(super) ordinal: u32,
    pub(super) x_offset: u32,
    pub(super) y_offset: u32,
    pub(super) source_x: u32,
    pub(super) source_y: u32,
    pub(super) source_width: u32,
    pub(super) source_height: u32,
    pub(super) columns: u32,
    pub(super) rows: u32,
    pub(super) grid_cols: u32,
    pub(super) grid_rows: u32,
    pub(super) pixel_width: u32,
    pub(super) pixel_height: u32,
    pub(super) viewport_col: i32,
    pub(super) viewport_row: i32,
    pub(super) viewport_visible: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub(super) anchor_col: Option<u16>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub(super) anchor_row: Option<u32>,
    pub(super) z: i32,
}

impl From<&ghostty_vt::KittyPlacement> for RenderGraphicPlacementMessage {
    fn from(placement: &ghostty_vt::KittyPlacement) -> Self {
        Self {
            image_id: placement.image_id,
            placement_id: placement.placement_id,
            ordinal: placement.key.ordinal,
            x_offset: placement.x_offset,
            y_offset: placement.y_offset,
            source_x: placement.source_x,
            source_y: placement.source_y,
            source_width: placement.source_width,
            source_height: placement.source_height,
            columns: placement.columns,
            rows: placement.rows,
            grid_cols: placement.grid_cols,
            grid_rows: placement.grid_rows,
            pixel_width: placement.pixel_width,
            pixel_height: placement.pixel_height,
            viewport_col: placement.viewport_col,
            viewport_row: placement.viewport_row,
            viewport_visible: placement.viewport_visible,
            anchor_col: placement.anchor.map(|anchor| anchor.col),
            anchor_row: placement.anchor.map(|anchor| anchor.row),
            z: placement.z,
        }
    }
}

#[derive(Serialize)]
pub(super) struct RenderGraphicsMessage {
    pub(super) generation: u64,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub(super) placements: Option<Vec<RenderGraphicPlacementMessage>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub(super) images: Option<Vec<RenderGraphicImageMessage>>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub(super) removed_image_ids: Option<Vec<u32>>,
}

pub(super) fn render_graphics_message(
    render_service: &RenderService,
    graphics: &ghostty_vt::KittyGraphicsSnapshot,
    image_ids: Option<&HashSet<u32>>,
    removed_image_ids: &[u32],
    include_placements: bool,
) -> RenderGraphicsMessage {
    let images = graphics
        .images
        .iter()
        .filter(|image| image_ids.is_none_or(|ids| ids.contains(&image.id)))
        .map(|image| {
            let data = render_service.encode_graphic(&image.data);
            RenderGraphicImageMessage {
                id: image.id,
                generation: image.generation,
                width: image.width,
                height: image.height,
                format: match image.format {
                    ghostty_vt::KittyImageFormat::Rgb => "rgb",
                    ghostty_vt::KittyImageFormat::Rgba => "rgba",
                },
                data,
            }
        })
        .collect::<Vec<_>>();
    RenderGraphicsMessage {
        generation: graphics.generation,
        placements: include_placements
            .then(|| graphics.placements.iter().map(RenderGraphicPlacementMessage::from).collect()),
        images: (image_ids.is_none() || !images.is_empty()).then_some(images),
        removed_image_ids: (!removed_image_ids.is_empty()).then(|| removed_image_ids.to_vec()),
    }
}

#[derive(Serialize)]
pub(super) struct RenderSizeMessage {
    pub(super) cols: u16,
    pub(super) rows: u16,
}

#[derive(Serialize)]
pub(super) struct RenderStateMessage {
    pub(super) event: &'static str,
    pub(super) surface: SurfaceId,
    pub(super) size: RenderSizeMessage,
    pub(super) cursor: Value,
    pub(super) default_fg: String,
    pub(super) default_bg: String,
    pub(super) scrollback_rows: u32,
    pub(super) history_epoch: u64,
    pub(super) rows: Vec<Value>,
    pub(super) graphics: RenderGraphicsMessage,
}

pub(super) fn render_state_message(
    render_service: &RenderService,
    surface: SurfaceId,
    frame: &SurfaceRenderFrame,
) -> RenderStateMessage {
    let (cols, rows) = frame.frame.size;
    RenderStateMessage {
        event: "render-state",
        surface,
        size: RenderSizeMessage { cols, rows },
        cursor: render_cursor_json(frame),
        default_fg: rgb_hex(frame.frame.default_colors.1),
        default_bg: rgb_hex(frame.frame.default_colors.0),
        scrollback_rows: frame.scrollback_rows,
        history_epoch: frame.history_epoch,
        rows: render_rows_json(frame, 0..rows),
        graphics: render_graphics_message(
            render_service,
            &frame.frame.kitty_graphics,
            None,
            &[],
            true,
        ),
    }
}

#[derive(Serialize)]
pub(super) struct RenderDeltaMessage {
    pub(super) event: &'static str,
    pub(super) surface: SurfaceId,
    pub(super) cursor: Value,
    pub(super) full: bool,
    pub(super) rows: Vec<Value>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub(super) size: Option<RenderSizeMessage>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub(super) default_fg: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub(super) default_bg: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub(super) scrollback_rows: Option<u32>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub(super) history_epoch: Option<u64>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub(super) graphics: Option<RenderGraphicsMessage>,
}

pub(super) struct RenderClientState {
    pub(super) render_service: Arc<RenderService>,
    pub(super) size: (u16, u16),
    pub(super) default_colors: (Rgb, Rgb),
    pub(super) scrollback_rows: u32,
    pub(super) history_epoch: u64,
    pub(super) graphics_snapshot_id: u64,
    pub(super) graphics_image_revision: u64,
    pub(super) graphics_placement_revision: u64,
    pub(super) graphics_image_generations: Arc<[(u32, u64)]>,
    pub(super) graphics_image_generations_match_snapshot: bool,
    #[cfg(test)]
    pub(super) image_generation_scan_count: usize,
}

fn render_client_image_delta(
    previous: &[(u32, u64)],
    next: &[(u32, u64)],
) -> (HashSet<u32>, Vec<u32>) {
    let mut changed = HashSet::new();
    let mut removed = Vec::new();
    let (mut previous_index, mut next_index) = (0, 0);
    while previous_index < previous.len() || next_index < next.len() {
        match (previous.get(previous_index), next.get(next_index)) {
            (Some(&(previous_id, previous_generation)), Some(&(next_id, next_generation))) => {
                if previous_id < next_id {
                    removed.push(previous_id);
                    previous_index += 1;
                } else if next_id < previous_id {
                    changed.insert(next_id);
                    next_index += 1;
                } else {
                    if previous_generation != next_generation {
                        changed.insert(next_id);
                    }
                    previous_index += 1;
                    next_index += 1;
                }
            }
            (Some(&(previous_id, _)), None) => {
                removed.push(previous_id);
                previous_index += 1;
            }
            (None, Some(&(next_id, _))) => {
                changed.insert(next_id);
                next_index += 1;
            }
            (None, None) => break,
        }
    }
    (changed, removed)
}

impl RenderClientState {
    pub(super) fn new(render_service: Arc<RenderService>, frame: &SurfaceRenderFrame) -> Self {
        let graphics_delta = &frame.frame.kitty_graphics_delta;
        let mut graphics_image_generations = frame
            .frame
            .kitty_graphics
            .images
            .iter()
            .map(|image| (image.id, image.generation))
            .collect::<Vec<_>>();
        graphics_image_generations.sort_unstable_by_key(|(id, _)| *id);
        let graphics_image_generations: Arc<[(u32, u64)]> = graphics_image_generations.into();
        let graphics_image_generations_match_snapshot =
            graphics_image_generations.as_ref() == graphics_delta.image_generations.as_ref();
        Self {
            render_service,
            size: frame.frame.size,
            default_colors: frame.frame.default_colors,
            scrollback_rows: frame.scrollback_rows,
            history_epoch: frame.history_epoch,
            graphics_snapshot_id: graphics_delta.snapshot_id,
            graphics_image_revision: graphics_delta.image_revision,
            graphics_placement_revision: graphics_delta.placement_revision,
            graphics_image_generations,
            graphics_image_generations_match_snapshot,
            #[cfg(test)]
            image_generation_scan_count: 0,
        }
    }

    pub(super) fn delta_message(
        &mut self,
        surface: SurfaceId,
        frame: &SurfaceRenderFrame,
    ) -> RenderDeltaMessage {
        let size_changed = self.size != frame.frame.size;
        let foreground_changed = self.default_colors.1 != frame.frame.default_colors.1;
        let background_changed = self.default_colors.0 != frame.frame.default_colors.0;
        let scrollback_changed = self.scrollback_rows != frame.scrollback_rows;
        let history_epoch_changed = self.history_epoch != frame.history_epoch;
        let full = size_changed
            || foreground_changed
            || background_changed
            || frame.frame.dirty == Dirty::Full;
        let rows = if full {
            render_rows_json(frame, 0..frame.frame.size.1)
        } else {
            render_rows_json(frame, frame.frame.dirty_rows.iter().copied())
        };
        let mut message = RenderDeltaMessage {
            event: "render-delta",
            surface,
            cursor: render_cursor_json(frame),
            full,
            rows,
            size: size_changed.then_some(RenderSizeMessage {
                cols: frame.frame.size.0,
                rows: frame.frame.size.1,
            }),
            default_fg: foreground_changed.then(|| rgb_hex(frame.frame.default_colors.1)),
            default_bg: background_changed.then(|| rgb_hex(frame.frame.default_colors.0)),
            scrollback_rows: scrollback_changed.then_some(frame.scrollback_rows),
            history_epoch: history_epoch_changed.then_some(frame.history_epoch),
            graphics: None,
        };
        let graphics_delta = &frame.frame.kitty_graphics_delta;
        if self.graphics_snapshot_id != graphics_delta.snapshot_id {
            let graphics = &frame.frame.kitty_graphics;
            let image_revision_changed =
                self.graphics_image_revision != graphics_delta.image_revision;
            let (upsert_image_ids, removed_image_ids) = if self
                .graphics_image_generations_match_snapshot
                && graphics_delta.previous_snapshot_id == Some(self.graphics_snapshot_id)
            {
                if image_revision_changed {
                    (
                        graphics_delta.changed_image_ids.iter().copied().collect::<HashSet<_>>(),
                        graphics_delta.removed_image_ids.to_vec(),
                    )
                } else {
                    (HashSet::new(), Vec::new())
                }
            } else {
                #[cfg(test)]
                {
                    self.image_generation_scan_count += self
                        .graphics_image_generations
                        .len()
                        .max(graphics_delta.image_generations.len());
                }
                render_client_image_delta(
                    &self.graphics_image_generations,
                    &graphics_delta.image_generations,
                )
            };
            let images_changed = !upsert_image_ids.is_empty() || !removed_image_ids.is_empty();
            let placements_changed =
                self.graphics_placement_revision != graphics_delta.placement_revision;
            if images_changed || placements_changed {
                message.graphics = Some(render_graphics_message(
                    &self.render_service,
                    graphics,
                    Some(&upsert_image_ids),
                    &removed_image_ids,
                    placements_changed,
                ));
            }
            self.graphics_snapshot_id = graphics_delta.snapshot_id;
            self.graphics_image_revision = graphics_delta.image_revision;
            self.graphics_placement_revision = graphics_delta.placement_revision;
            self.graphics_image_generations = graphics_delta.image_generations.clone();
            self.graphics_image_generations_match_snapshot = true;
        }
        self.size = frame.frame.size;
        self.default_colors = frame.frame.default_colors;
        self.scrollback_rows = frame.scrollback_rows;
        self.history_epoch = frame.history_epoch;
        message
    }
}

#[derive(Serialize)]
pub(super) struct BrowserStateMessage<'a> {
    pub(super) event: &'static str,
    pub(super) surface: SurfaceId,
    pub(super) cols: u16,
    pub(super) rows: u16,
    pub(super) url: &'a str,
    pub(super) title: &'a str,
    pub(super) status: &'static str,
    pub(super) error: Option<&'a str>,
    pub(super) pointer_frame_floor_seq: Option<u64>,
    pub(super) pointer_frame_seq: Option<u64>,
    pub(super) frames_stalled: bool,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub(super) frame: Option<Option<BrowserFramePayload<'a>>>,
}

#[derive(Serialize)]
pub(super) struct BrowserFramePayload<'a> {
    pub(super) seq: u64,
    pub(super) width: u32,
    pub(super) height: u32,
    pub(super) image_width: u32,
    pub(super) image_height: u32,
    pub(super) data: &'a str,
}

pub(super) fn browser_state_message<'a>(
    surface: SurfaceId,
    state: &'a BrowserAttachState,
    include_frame: bool,
) -> BrowserStateMessage<'a> {
    BrowserStateMessage {
        event: "browser-state",
        surface,
        cols: state.cols,
        rows: state.rows,
        url: &state.url,
        title: &state.title,
        status: state.status.as_str(),
        error: match &state.status {
            crate::BrowserStatus::Failed(error) => Some(error),
            crate::BrowserStatus::Starting | crate::BrowserStatus::Live => None,
        },
        pointer_frame_floor_seq: state.pointer_frame_floor_seq,
        pointer_frame_seq: state.pointer_frame_seq,
        frames_stalled: state.frames_stalled,
        frame: include_frame.then(|| state.frame.as_ref().map(browser_frame_payload)),
    }
}

pub(super) fn browser_frame_json(surface: SurfaceId, update: &BrowserFrameUpdate) -> Value {
    json!({
        "event": "frame",
        "surface": surface,
        "seq": update.frame.seq,
        "width": update.frame.css_width,
        "height": update.frame.css_height,
        "image_width": update.frame.image_width,
        "image_height": update.frame.image_height,
        "data": update.frame.data_b64,
        "status": update.status.as_str(),
        "error": update.status.error(),
        "pointer_frame_floor_seq": update.pointer_frame_floor_seq,
        "pointer_frame_seq": update.pointer_frame_seq,
    })
}

pub(super) fn send_browser_attach_update(
    writer: &MessageWriter,
    surface: SurfaceId,
    update: BrowserAttachUpdate,
    outbound_stream: &OutboundStream,
) -> std::io::Result<()> {
    if let Some(frame) = update.frame {
        writer.send_stream_backpressured(&browser_frame_json(surface, &frame), outbound_stream)?;
    }
    if let Some(state) = update.state {
        writer.send_stream_backpressured(
            &browser_state_message(surface, &state, false),
            outbound_stream,
        )?;
    }
    Ok(())
}

fn browser_frame_payload(frame: &crate::BrowserFrame) -> BrowserFramePayload<'_> {
    BrowserFramePayload {
        seq: frame.seq,
        width: frame.css_width,
        height: frame.css_height,
        image_width: frame.image_width,
        image_height: frame.image_height,
        data: &frame.data_b64,
    }
}
