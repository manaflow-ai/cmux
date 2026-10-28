//! Render attach serialization budget: the render-graphic base64 cache, the
//! outbound byte budget and budgeted JSON writer, `RenderService`, and the
//! JSON writers for base64 replays and kitty graphics state, and the frame
//! variant of the attach writer (server/attach_frames.rs).

use super::AttachWireShape;
use super::OUTBOUND_CONTROL_BYTE_RESERVE;
use super::OUTBOUND_GLOBAL_BYTE_CAPACITY;
use super::OUTBOUND_GLOBAL_CONTROL_BYTE_CAPACITY;
use super::RENDER_GRAPHIC_BASE64_CACHE_MAX_BYTES;
use super::RENDER_GRAPHIC_BASE64_CACHE_MAX_ENTRIES;
use super::VtStateMessage;
use super::attach_frames::{
    AttachFrameEncoder, AttachFrameError, BudgetedFrame, EncodedAttachFrame, RefusedAttachFrame,
};
use super::attach_streams::ClientStreamId;
use super::attach_streams::StreamTagSplice;
use super::terminal_colors_json;
use super::{write_output_flow_json, write_output_key_stages_json, write_pending_sequence_json};
use crate::AttachFrame;
use crate::SurfaceId;
use crate::TerminalColors;
use crate::panic_free::JsonFields;
use crate::panic_free::RecoverPoison;
use crate::surface::AttachResize;
use base64::Engine;
use cmux_threads::sync::Mutex;
use ghostty_vt::KittyReplayState;
use serde::Serialize;
use serde_json::json;
use std::collections::HashMap;
use std::collections::VecDeque;
use std::io::Write;
use std::ops::Deref;
use std::sync::Arc;
use std::sync::Weak;
use std::sync::atomic::AtomicUsize;
use std::sync::atomic::Ordering;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub(super) struct RenderGraphicCacheKey {
    data_ptr: usize,
    data_len: usize,
}

pub(super) struct RenderGraphicCacheEntry {
    pub(super) source: Weak<[u8]>,
    pub(super) encoded: Arc<str>,
}

pub(super) struct RenderGraphicBase64Cache {
    pub(super) entries: HashMap<RenderGraphicCacheKey, RenderGraphicCacheEntry>,
    pub(super) insertion_order: VecDeque<RenderGraphicCacheKey>,
    pub(super) retained_bytes: usize,
    pub(super) max_bytes: usize,
    pub(super) max_entries: usize,
}

impl RenderGraphicBase64Cache {
    pub(super) fn new(max_bytes: usize, max_entries: usize) -> Self {
        Self {
            entries: HashMap::new(),
            insertion_order: VecDeque::new(),
            retained_bytes: 0,
            max_bytes,
            max_entries,
        }
    }

    pub(super) fn encode(&mut self, data: &Arc<[u8]>) -> Arc<str> {
        let key = RenderGraphicCacheKey { data_ptr: data.as_ptr() as usize, data_len: data.len() };
        if let Some(entry) = self.entries.get(&key)
            && entry.source.upgrade().is_some_and(|source| Arc::ptr_eq(&source, data))
        {
            return entry.encoded.clone();
        }
        if let Some(stale) = self.entries.remove(&key) {
            self.retained_bytes = self.retained_bytes.saturating_sub(stale.encoded.len());
            self.insertion_order.retain(|candidate| *candidate != key);
        }

        // Serialize while holding the cache lock. Competing render clients
        // wait for this one bounded encode instead of allocating duplicates.
        let encoded: Arc<str> =
            Arc::from(base64::engine::general_purpose::STANDARD.encode(data.as_ref()));
        if encoded.len() > self.max_bytes || self.max_entries == 0 {
            return encoded;
        }
        while self.entries.len() >= self.max_entries
            || encoded.len() > self.max_bytes.saturating_sub(self.retained_bytes)
        {
            let Some(oldest) = self.insertion_order.pop_front() else {
                break;
            };
            if let Some(evicted) = self.entries.remove(&oldest) {
                self.retained_bytes = self.retained_bytes.saturating_sub(evicted.encoded.len());
            }
        }
        self.retained_bytes += encoded.len();
        self.insertion_order.push_back(key);
        self.entries.insert(
            key,
            RenderGraphicCacheEntry { source: Arc::downgrade(data), encoded: encoded.clone() },
        );
        encoded
    }
}

pub(super) struct OutboundByteBudget {
    pub(super) retained_bytes: AtomicUsize,
    pub(super) max_bytes: usize,
}

impl OutboundByteBudget {
    pub(super) fn new(max_bytes: usize) -> Self {
        Self { retained_bytes: AtomicUsize::new(0), max_bytes }
    }

    pub(super) fn try_retain(&self, bytes: usize) -> bool {
        self.retained_bytes
            .fetch_update(Ordering::AcqRel, Ordering::Acquire, |retained| {
                retained.checked_add(bytes).filter(|next| *next <= self.max_bytes)
            })
            .is_ok()
    }

    pub(super) fn release(&self, bytes: usize) {
        let previous = self.retained_bytes.fetch_sub(bytes, Ordering::AcqRel);
        debug_assert!(previous >= bytes, "outbound byte budget underflow");
    }
}

pub(super) struct BudgetedText {
    pub(super) text: String,
    pub(super) retained_bytes: usize,
    pub(super) budget: Arc<OutboundByteBudget>,
}

impl Deref for BudgetedText {
    type Target = str;

    fn deref(&self) -> &Self::Target {
        &self.text
    }
}

impl Drop for BudgetedText {
    fn drop(&mut self) {
        self.budget.release(self.retained_bytes);
    }
}

pub(super) struct BudgetedJsonWriter {
    pub(super) bytes: Vec<u8>,
    // Total quota charged while this writer is alive. A reserved writer
    // starts with logical quota but grows its Vec only as bytes are written.
    pub(super) retained_bytes: usize,
    pub(super) reservation_bytes: usize,
    pub(super) budget: Arc<OutboundByteBudget>,
    /// The client stream id spliced into the object this writer serializes.
    tag: StreamTagSplice,
}

impl BudgetedJsonWriter {
    pub(super) fn new(budget: Arc<OutboundByteBudget>) -> Self {
        Self {
            bytes: Vec::new(),
            retained_bytes: 0,
            reservation_bytes: 0,
            budget,
            tag: StreamTagSplice::Done,
        }
    }

    /// A writer whose one JSON object gets `"stream": id` as its first
    /// member when `stream` is set.
    fn tagged(budget: Arc<OutboundByteBudget>, stream: Option<ClientStreamId>) -> Self {
        let mut writer = Self::new(budget);
        writer.tag = StreamTagSplice::of(stream);
        writer
    }

    /// The finished text; an item whose tag was not spliced (nothing, or
    /// not an object, was written) is refused.
    fn finish_tagged(self) -> std::io::Result<Arc<BudgetedText>> {
        if self.tag != StreamTagSplice::Done {
            return Err(std::io::Error::new(
                std::io::ErrorKind::InvalidData,
                "a stream item must be one JSON object",
            ));
        }
        Ok(self.finish())
    }

    fn append(&mut self, bytes: &[u8]) -> std::io::Result<()> {
        let required_len = self.bytes.len().checked_add(bytes.len()).ok_or_else(|| {
            std::io::Error::new(std::io::ErrorKind::InvalidData, "serialized message is too large")
        })?;
        self.ensure_capacity(required_len)?;
        self.bytes.extend_from_slice(bytes);
        Ok(())
    }

    pub(super) fn with_reservation(
        budget: Arc<OutboundByteBudget>,
        reserved_bytes: usize,
    ) -> std::io::Result<Self> {
        let mut writer = Self::new(budget);
        if !writer.budget.try_retain(reserved_bytes) {
            return Err(std::io::Error::new(
                std::io::ErrorKind::WouldBlock,
                "global outbound byte budget overflowed",
            ));
        }
        writer.retained_bytes = reserved_bytes;
        writer.reservation_bytes = reserved_bytes;
        Ok(writer)
    }

    pub(super) fn ensure_capacity(&mut self, required_len: usize) -> std::io::Result<()> {
        if required_len <= self.bytes.capacity() {
            return Ok(());
        }
        let target = required_len.checked_next_power_of_two().unwrap_or(required_len).max(8);
        let previous_retained = self.retained_bytes;
        let target_retained = target.max(self.reservation_bytes);
        let additional_retained = target_retained.saturating_sub(previous_retained);
        if additional_retained > 0 && !self.budget.try_retain(additional_retained) {
            return Err(std::io::Error::new(
                std::io::ErrorKind::WouldBlock,
                "global outbound byte budget overflowed",
            ));
        }
        self.retained_bytes = target_retained;
        if let Err(error) = self.bytes.try_reserve_exact(target.saturating_sub(self.bytes.len())) {
            self.retained_bytes = previous_retained;
            if additional_retained > 0 {
                self.budget.release(additional_retained);
            }
            return Err(std::io::Error::other(error));
        }
        let actual_capacity = self.bytes.capacity();
        let actual_retained = actual_capacity.max(self.reservation_bytes);
        if actual_retained > self.retained_bytes {
            let additional = actual_retained - self.retained_bytes;
            if !self.budget.try_retain(additional) {
                return Err(std::io::Error::new(
                    std::io::ErrorKind::WouldBlock,
                    "global outbound byte budget overflowed",
                ));
            }
            self.retained_bytes = actual_retained;
        } else if actual_retained < self.retained_bytes {
            let unused = self.retained_bytes - actual_retained;
            self.retained_bytes = actual_retained;
            self.budget.release(unused);
        }
        Ok(())
    }

    pub(super) fn finish(mut self) -> Arc<BudgetedText> {
        let bytes = std::mem::take(&mut self.bytes);
        let retained_bytes = bytes.capacity();
        debug_assert!(retained_bytes <= self.retained_bytes);
        if retained_bytes < self.retained_bytes {
            self.budget.release(self.retained_bytes - retained_bytes);
        }
        self.retained_bytes = 0;
        self.reservation_bytes = 0;
        // serde_json emits UTF-8; a lossy decode keeps this path panic-free.
        let text = String::from_utf8(bytes)
            .unwrap_or_else(|error| String::from_utf8_lossy(error.as_bytes()).into_owned());
        Arc::new(BudgetedText { text, retained_bytes, budget: self.budget.clone() })
    }
}

impl Write for BudgetedJsonWriter {
    fn write(&mut self, bytes: &[u8]) -> std::io::Result<usize> {
        let mut rest = bytes;
        loop {
            match self.tag {
                StreamTagSplice::Done => {
                    self.append(rest)?;
                    return Ok(bytes.len());
                }
                StreamTagSplice::Open(stream) => {
                    let Some((&b'{', tail)) = rest.split_first() else {
                        if rest.is_empty() {
                            return Ok(bytes.len());
                        }
                        return Err(std::io::Error::new(
                            std::io::ErrorKind::InvalidData,
                            "a stream item must be one JSON object",
                        ));
                    };
                    self.append(b"{\"stream\":")?;
                    self.append(stream.0.to_string().as_bytes())?;
                    self.tag = StreamTagSplice::Member;
                    rest = tail;
                }
                StreamTagSplice::Member => {
                    let Some(&next) = rest.first() else { return Ok(bytes.len()) };
                    if next != b'}' {
                        self.append(b",")?;
                    }
                    self.tag = StreamTagSplice::Done;
                }
            }
        }
    }

    fn flush(&mut self) -> std::io::Result<()> {
        Ok(())
    }
}

impl Drop for BudgetedJsonWriter {
    fn drop(&mut self) {
        if self.retained_bytes > 0 {
            self.budget.release(self.retained_bytes);
        }
    }
}

pub(super) struct RenderService {
    pub(super) graphic_base64: Mutex<RenderGraphicBase64Cache>,
    pub(super) outbound_budget: Arc<OutboundByteBudget>,
    pub(super) control_budget: Arc<OutboundByteBudget>,
}

impl RenderService {
    pub(super) fn new() -> Self {
        Self::new_with_outbound_budgets(
            OUTBOUND_GLOBAL_BYTE_CAPACITY,
            OUTBOUND_GLOBAL_CONTROL_BYTE_CAPACITY,
        )
    }

    #[cfg(test)]
    pub(super) fn new_with_outbound_budget(max_bytes: usize) -> Self {
        Self::new_with_outbound_budgets(max_bytes, OUTBOUND_GLOBAL_CONTROL_BYTE_CAPACITY)
    }

    pub(super) fn new_with_outbound_budgets(max_bytes: usize, control_max_bytes: usize) -> Self {
        Self {
            graphic_base64: Mutex::new(RenderGraphicBase64Cache::new(
                RENDER_GRAPHIC_BASE64_CACHE_MAX_BYTES,
                RENDER_GRAPHIC_BASE64_CACHE_MAX_ENTRIES,
            )),
            outbound_budget: Arc::new(OutboundByteBudget::new(max_bytes)),
            control_budget: Arc::new(OutboundByteBudget::new(control_max_bytes)),
        }
    }

    pub(super) fn encode_graphic(&self, data: &Arc<[u8]>) -> Arc<str> {
        self.graphic_base64.lock().recover_poison().encode(data)
    }

    #[cfg(test)]
    pub(super) fn serialize<T: Serialize + ?Sized>(
        &self,
        value: &T,
    ) -> std::io::Result<Arc<BudgetedText>> {
        self.serialize_for(value, None)
    }

    /// `value` as an item of a stream, tagged with `stream` when the client
    /// minted the stream's id (attach-streams-v1).
    pub(super) fn serialize_for<T: Serialize + ?Sized>(
        &self,
        value: &T,
        stream: Option<ClientStreamId>,
    ) -> std::io::Result<Arc<BudgetedText>> {
        let mut writer = BudgetedJsonWriter::tagged(self.outbound_budget.clone(), stream);
        serde_json::to_writer(&mut writer, value).map_err(json_error_to_io)?;
        writer.finish_tagged()
    }

    pub(super) fn serialize_control<T: Serialize + ?Sized>(
        &self,
        value: &T,
    ) -> std::io::Result<Arc<BudgetedText>> {
        self.serialize_control_for(value, None)
    }

    pub(super) fn serialize_control_for<T: Serialize + ?Sized>(
        &self,
        value: &T,
        stream: Option<ClientStreamId>,
    ) -> std::io::Result<Arc<BudgetedText>> {
        let mut writer = BudgetedJsonWriter::tagged(self.control_budget.clone(), stream);
        serde_json::to_writer(&mut writer, value).map_err(json_error_to_io)?;
        writer.finish_tagged()
    }

    #[cfg(test)]
    pub(super) fn serialize_vt_state(
        &self,
        value: &VtStateMessage,
    ) -> std::io::Result<Arc<BudgetedText>> {
        self.serialize_vt_state_for(value, None)
    }

    pub(super) fn serialize_vt_state_for(
        &self,
        value: &VtStateMessage,
        stream: Option<ClientStreamId>,
    ) -> std::io::Result<Arc<BudgetedText>> {
        let mut writer = BudgetedJsonWriter::tagged(self.outbound_budget.clone(), stream);
        write!(
            writer,
            "{{\"event\":\"vt-state\",\"surface\":{},\"cols\":{},\"rows\":{},\"data\":\"",
            value.surface, value.cols, value.rows
        )?;
        {
            let mut encoder = base64::write::EncoderWriter::new(
                &mut writer,
                &base64::engine::general_purpose::STANDARD,
            );
            encoder.write_all(&value.replay)?;
            encoder.finish()?;
        }
        writer.write_all(b"\",\"kitty_image_aliases\":")?;
        write_kitty_image_aliases_json(&mut writer, &value.kitty_image_aliases)?;
        writer.write_all(b",\"kitty_graphics_state\":")?;
        write_kitty_replay_state_json(&mut writer, value.kitty_state)?;
        writer.write_all(b",\"colors\":")?;
        serde_json::to_writer(&mut writer, &value.colors).map_err(json_error_to_io)?;
        write_pending_sequence_json(&mut writer, &value.pending_sequence)?;
        writer.write_all(b"}")?;
        writer.finish_tagged()
    }

    #[cfg(test)]
    pub(super) fn serialize_attach_frame(
        &self,
        surface: SurfaceId,
        frame: &AttachFrame,
        shape: AttachWireShape,
    ) -> std::io::Result<Arc<BudgetedText>> {
        self.serialize_attach_frame_for(surface, frame, shape, None, None)
    }

    /// [`Self::serialize_attach_frame`] with the daemon stages of the key
    /// press an output frame echoes, sent now.
    #[cfg(test)]
    pub(super) fn serialize_attach_frame_with_stages(
        &self,
        surface: SurfaceId,
        frame: &AttachFrame,
        shape: AttachWireShape,
        key_stages: Option<crate::input_stages::KeyStages>,
    ) -> std::io::Result<Arc<BudgetedText>> {
        self.serialize_attach_frame_for(surface, frame, shape, key_stages, None)
    }

    /// An attach frame in `shape` for client `stream`; an output frame that
    /// echoes a key press carries that press's `key_stages`.
    pub(super) fn serialize_attach_frame_for(
        &self,
        surface: SurfaceId,
        frame: &AttachFrame,
        shape: AttachWireShape,
        key_stages: Option<crate::input_stages::KeyStages>,
        stream: Option<ClientStreamId>,
    ) -> std::io::Result<Arc<BudgetedText>> {
        let mut writer = BudgetedJsonWriter::tagged(self.outbound_budget.clone(), stream);
        if let AttachFrame::ColorsChanged(colors) = frame {
            write_colors_changed_json(&mut writer, surface, colors, shape)?;
        } else if let Some(resize) = frame.resize() {
            write!(
                writer,
                "{{\"event\":\"resized\",\"surface\":{surface},\"cols\":{},\"rows\":{},\"replay\":\"",
                resize.cols, resize.rows
            )?;
            write_resized_replay_json(&mut writer, resize.replay, resize.pending_sequence, shape)?;
            writer.write_all(b"\"")?;
            write_resized_state_fields(&mut writer, &resize, shape)?;
            if shape.pending_sequence {
                write_pending_sequence_json(&mut writer, resize.pending_sequence)?;
            }
            writer.write_all(b"}")?;
        } else if let Some(output) = frame.output() {
            write!(writer, "{{\"event\":\"output\",\"surface\":{surface},\"data\":\"")?;
            write_base64_json_string(&mut writer, output)?;
            writer.write_all(b"\"")?;
            write_output_sidecar_fields(&mut writer, frame.output_colors(), frame.flow(), shape)?;
            if key_stages.is_some() {
                write_output_key_stages_json(
                    &mut writer,
                    key_stages,
                    crate::input_stages::now_ns(),
                )?;
            }
            writer.write_all(b"}")?;
        }
        writer.finish_tagged()
    }

    pub(super) fn reserved_control_writer(&self) -> std::io::Result<BudgetedJsonWriter> {
        BudgetedJsonWriter::with_reservation(
            self.control_budget.clone(),
            OUTBOUND_CONTROL_BYTE_RESERVE,
        )
    }
}

/// Attach frames are bound with `attach-frames-v1` (`IpcTransports::BOUND`)
/// once the outbound queue carries stream frames; until then only tests
/// encode them.
#[cfg_attr(not(test), expect(dead_code, reason = "no transport serves attach-frames-v1 yet"))]
impl RenderService {
    /// The frame variant of [`Self::serialize_attach_frame`] for a stream
    /// granted `attach-frames-v1`: raw OUTPUT, GRID and EVENT frames
    /// (server/attach_frames.rs), charged to the same outbound budget.
    pub(super) fn encode_attach_frame(
        &self,
        encoder: &mut AttachFrameEncoder,
        frame: AttachFrame,
    ) -> Result<EncodedAttachFrame, RefusedAttachFrame> {
        encoder.encode(frame, &self.outbound_budget)
    }

    /// Another attach event (`detached`, `overflow`) as an EVENT frame at
    /// the stream's current offset.
    pub(super) fn encode_attach_event<T: Serialize + ?Sized>(
        &self,
        encoder: &AttachFrameEncoder,
        value: &T,
    ) -> Result<BudgetedFrame, AttachFrameError> {
        encoder.event(value, &self.outbound_budget)
    }
}

pub(super) fn json_error_to_io(error: serde_json::Error) -> std::io::Error {
    std::io::Error::new(error.io_error_kind().unwrap_or(std::io::ErrorKind::InvalidData), error)
}

pub(super) fn write_base64_json_string(
    writer: &mut BudgetedJsonWriter,
    bytes: &[u8],
) -> std::io::Result<()> {
    write_base64_json_parts(writer, &[bytes])
}

/// One base64 string for the concatenation of `parts`, without copying them.
fn write_base64_json_parts(
    writer: &mut BudgetedJsonWriter,
    parts: &[&[u8]],
) -> std::io::Result<()> {
    let mut encoder =
        base64::write::EncoderWriter::new(writer, &base64::engine::general_purpose::STANDARD);
    for part in parts {
        encoder.write_all(part)?;
    }
    encoder.finish().map(|_| ())
}

/// A resized replay and its pending sequence: separate fields for viewers
/// that advertised the capability, one self-contained replay otherwise.
fn write_resized_replay_json(
    writer: &mut BudgetedJsonWriter,
    replay: &[u8],
    pending: &[u8],
    shape: AttachWireShape,
) -> std::io::Result<()> {
    if shape.pending_sequence {
        write_base64_json_string(writer, replay)
    } else {
        write_base64_json_parts(writer, &[replay, pending])
    }
}

/// `,"colors":…` and `,"flow":N` of an `output` event: the fields that ride
/// beside its bytes, in the JSON line and in an output sidecar EVENT.
pub(super) fn write_output_sidecar_fields(
    writer: &mut BudgetedJsonWriter,
    colors: Option<&TerminalColors>,
    flow: u64,
    shape: AttachWireShape,
) -> std::io::Result<()> {
    if let Some(colors) = colors {
        writer.write_all(b",\"colors\":")?;
        serde_json::to_writer(&mut *writer, &terminal_colors_json(*colors, shape.color_overrides))
            .map_err(json_error_to_io)?;
    }
    write_output_flow_json(writer, flow)
}

/// The fields of a `resized` event after its replay: Kitty aliases and
/// state, then the colors of a `ResizedWithColors`.
pub(super) fn write_resized_state_fields(
    writer: &mut BudgetedJsonWriter,
    resize: &AttachResize<'_>,
    shape: AttachWireShape,
) -> std::io::Result<()> {
    writer.write_all(b",\"kitty_image_aliases\":")?;
    write_kitty_image_aliases_json(writer, resize.kitty_image_aliases)?;
    writer.write_all(b",\"kitty_graphics_state\":")?;
    write_kitty_replay_state_json(writer, resize.kitty_state)?;
    if let Some(colors) = resize.colors {
        writer.write_all(b",\"colors\":")?;
        serde_json::to_writer(&mut *writer, &terminal_colors_json(*colors, shape.color_overrides))
            .map_err(json_error_to_io)?;
    }
    Ok(())
}

/// The whole `colors-changed` event.
pub(super) fn write_colors_changed_json(
    writer: &mut BudgetedJsonWriter,
    surface: SurfaceId,
    colors: &TerminalColors,
    shape: AttachWireShape,
) -> std::io::Result<()> {
    let mut value = terminal_colors_json(*colors, shape.color_overrides);
    value.insert("event", json!("colors-changed"));
    value.insert("surface", json!(surface));
    serde_json::to_writer(writer, &value).map_err(json_error_to_io)
}

pub(super) fn write_kitty_image_aliases_json(
    writer: &mut impl Write,
    aliases: &[ghostty_vt::KittyImageAlias],
) -> std::io::Result<()> {
    writer.write_all(b"[")?;
    for (index, alias) in aliases.iter().enumerate() {
        if index != 0 {
            writer.write_all(b",")?;
        }
        write!(
            writer,
            "{{\"image_id\":{},\"image_number\":{}}}",
            alias.image_id, alias.image_number
        )?;
    }
    writer.write_all(b"]")
}

pub(super) fn write_kitty_replay_state_json(
    writer: &mut impl Write,
    state: KittyReplayState,
) -> std::io::Result<()> {
    write!(
        writer,
        concat!(
            "{{\"image_bytes\":{},\"inflight_bytes\":{},\"images\":{},\"placements\":{},",
            "\"replay_cursor_offset\":{},",
            "\"primary_replay_next_image_id\":{},\"primary_next_image_id\":{},",
            "\"alternate_replay_next_image_id\":{},\"alternate_next_image_id\":{}}}"
        ),
        state.limits.image_bytes,
        state.limits.inflight_bytes,
        state.limits.images,
        state.limits.placements,
        state.replay_cursor_offset,
        state.replay_next_image_ids.primary,
        state.next_image_ids.primary,
        state.replay_next_image_ids.alternate,
        state.next_image_ids.alternate,
    )
}
