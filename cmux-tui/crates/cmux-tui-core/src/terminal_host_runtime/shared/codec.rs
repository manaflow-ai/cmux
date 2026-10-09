//! Wire codecs of the terminal-host protocol that do not touch the OS:
//! snapshot, resize and kitty-graphics payloads, hex helpers, and the
//! length-prefixed payload reader and writers. Moved from `mod unix`
//! (cx-ko2e table A) so the Windows host can share them.

use std::io::Read;

use cmux_pty::PtyOpenError;
use ghostty_vt::CursorShape;

use super::super::*;
use super::host_state::pty_size;

pub(crate) fn encode_snapshot(snapshot: &HostSnapshot) -> anyhow::Result<Vec<u8>> {
    encode_snapshot_for_version(snapshot, PROTOCOL_VERSION, false)
}

pub(crate) fn encode_snapshot_for_version(
    snapshot: &HostSnapshot,
    protocol_version: u16,
    include_terminal_metadata: bool,
) -> anyhow::Result<Vec<u8>> {
    if !(LEGACY_PROTOCOL_VERSION..=PROTOCOL_VERSION).contains(&protocol_version) {
        anyhow::bail!("unsupported terminal-host snapshot protocol {protocol_version}");
    }
    if include_terminal_metadata && protocol_version < PROTOCOL_VERSION {
        anyhow::bail!("terminal metadata requires the current snapshot protocol");
    }
    if snapshot.osc_progress.chars().count() > crate::terminal_metadata::MAX_PROGRESS_CHARS
        || snapshot.osc_progress.chars().any(char::is_control)
    {
        anyhow::bail!("terminal-host OSC progress is out of range");
    }
    let (cols, rows) = normalize_terminal_geometry(snapshot.cols, snapshot.rows)?;
    snapshot
        .kitty_state
        .validate_for_replay(snapshot.replay.len())
        .map_err(|_| anyhow::anyhow!("terminal-host Kitty replay offset is invalid"))?;
    let mut output = Vec::new();
    output.extend_from_slice(&cols.to_le_bytes());
    output.extend_from_slice(&rows.to_le_bytes());
    output.extend_from_slice(&snapshot.pid.unwrap_or(0).to_le_bytes());
    put_blob(&mut output, &snapshot.replay)?;
    put_optional_string(&mut output, snapshot.cwd.as_deref())?;
    if snapshot.command.len() > MAX_ARGV {
        anyhow::bail!("terminal-host snapshot command count is too large");
    }
    output.extend_from_slice(&(snapshot.command.len() as u16).to_le_bytes());
    for argument in &snapshot.command {
        put_string(&mut output, argument)?;
    }
    encode_kitty_image_aliases(&mut output, &snapshot.kitty_image_aliases)?;
    output.extend_from_slice(&snapshot.cell_pixels.0.max(1).to_le_bytes());
    output.extend_from_slice(&snapshot.cell_pixels.1.max(1).to_le_bytes());
    encode_kitty_replay_state(&mut output, snapshot.kitty_state)?;
    if include_terminal_metadata {
        put_string(&mut output, &snapshot.osc_progress)?;
    }
    if output.len() > MAX_FRAME_PAYLOAD {
        anyhow::bail!("terminal-host snapshot payload is too large");
    }
    Ok(output)
}

/// Encode the version-current snapshot payload used by native smart
/// renderer clients. Keeping this paired with the public decoder prevents
/// client fixtures and adapters from reproducing a stale wire schema.
pub fn encode_host_snapshot_payload(snapshot: &HostSnapshot) -> anyhow::Result<Vec<u8>> {
    encode_snapshot(snapshot)
}

#[cfg(test)]
pub(crate) fn decode_snapshot(payload: &[u8]) -> anyhow::Result<HostSnapshot> {
    decode_snapshot_for_version(payload, PROTOCOL_VERSION, false)
}

pub fn decode_host_snapshot_payload(payload: &[u8]) -> anyhow::Result<HostSnapshot> {
    decode_snapshot_for_version(payload, PROTOCOL_VERSION, false)
}

pub(crate) fn decode_snapshot_for_version(
    payload: &[u8],
    protocol_version: u16,
    include_terminal_metadata: bool,
) -> anyhow::Result<HostSnapshot> {
    if !(LEGACY_PROTOCOL_VERSION..=PROTOCOL_VERSION).contains(&protocol_version) {
        anyhow::bail!("unsupported terminal-host snapshot protocol {protocol_version}");
    }
    if include_terminal_metadata && protocol_version < PROTOCOL_VERSION {
        anyhow::bail!("terminal metadata requires the current snapshot protocol");
    }
    let mut decoder = PayloadDecoder::new(payload);
    let (cols, rows) = normalize_terminal_geometry(decoder.u16()?, decoder.u16()?)?;
    let pid = match decoder.u32()? {
        0 => None,
        pid => Some(pid),
    };
    let replay = decoder.blob()?.to_vec();
    let cwd = decoder.optional_string()?;
    let argc = decoder.u16()? as usize;
    if argc > MAX_ARGV {
        anyhow::bail!("terminal-host snapshot command count is too large");
    }
    let mut command = Vec::with_capacity(argc);
    for _ in 0..argc {
        command.push(decoder.string()?);
    }
    let kitty_image_aliases =
        if protocol_version >= 2 { decode_kitty_image_aliases(&mut decoder)? } else { Vec::new() };
    let cell_pixels = if protocol_version >= 2 {
        (decoder.u16()?.max(1), decoder.u16()?.max(1))
    } else {
        DEFAULT_CELL_PIXELS
    };
    let kitty_state = if protocol_version >= 3 {
        decode_kitty_replay_state(&mut decoder)?
            .validate_for_replay(replay.len())
            .map_err(|_| anyhow::anyhow!("terminal-host Kitty replay offset is invalid"))?
    } else {
        KittyReplayState::disabled()
    };
    let osc_progress = if include_terminal_metadata {
        if !decoder.has_remaining() {
            anyhow::bail!("terminal-host snapshot omitted negotiated metadata");
        }
        let value = decoder.string()?;
        if value.chars().count() > crate::terminal_metadata::MAX_PROGRESS_CHARS
            || value.chars().any(char::is_control)
        {
            anyhow::bail!("terminal-host OSC progress is out of range");
        }
        value
    } else {
        String::new()
    };
    pty_size(cols, rows, cell_pixels)?;
    decoder.finish()?;
    Ok(HostSnapshot {
        cols,
        rows,
        cell_pixels,
        replay,
        kitty_image_aliases,
        kitty_state,
        sequence_boundary: 0,
        colors: TerminalColorOverrides::default(),
        pid,
        command,
        cwd,
        osc_progress,
    })
}

pub(crate) fn encode_kitty_image_aliases(
    output: &mut Vec<u8>,
    aliases: &[KittyImageAlias],
) -> anyhow::Result<()> {
    validate_kitty_image_aliases(aliases)?;
    output.extend_from_slice(&(aliases.len() as u16).to_le_bytes());
    for alias in aliases {
        output.extend_from_slice(&alias.image_id.to_le_bytes());
        output.extend_from_slice(&alias.image_number.to_le_bytes());
    }
    Ok(())
}

pub(crate) fn decode_kitty_image_aliases(
    decoder: &mut PayloadDecoder<'_>,
) -> anyhow::Result<Vec<KittyImageAlias>> {
    let count = decoder.u16()? as usize;
    if count > MAX_KITTY_IMAGE_ALIASES {
        anyhow::bail!("terminal-host Kitty image alias count is too large");
    }
    let mut aliases = Vec::with_capacity(count);
    for _ in 0..count {
        aliases.push(KittyImageAlias { image_id: decoder.u32()?, image_number: decoder.u32()? });
    }
    validate_kitty_image_aliases(&aliases)?;
    Ok(aliases)
}

pub(crate) fn encode_kitty_graphics_limits(
    output: &mut Vec<u8>,
    limits: KittyGraphicsLimits,
) -> anyhow::Result<()> {
    let limits = limits
        .validate()
        .map_err(|_| anyhow::anyhow!("terminal-host Kitty graphics limits are out of range"))?;
    output.extend_from_slice(&limits.image_bytes.to_le_bytes());
    output.extend_from_slice(&limits.inflight_bytes.to_le_bytes());
    output.extend_from_slice(&limits.images.to_le_bytes());
    output.extend_from_slice(&limits.placements.to_le_bytes());
    Ok(())
}

pub(crate) fn decode_kitty_graphics_limits(
    decoder: &mut PayloadDecoder<'_>,
) -> anyhow::Result<KittyGraphicsLimits> {
    KittyGraphicsLimits {
        image_bytes: decoder.u64()?,
        inflight_bytes: decoder.u64()?,
        images: decoder.u64()?,
        placements: decoder.u64()?,
    }
    .validate()
    .map_err(|_| anyhow::anyhow!("terminal-host Kitty graphics limits are out of range"))
}

/// The Kitty limits a smart host's `ResyncRequired` carries when a quota
/// change evicted nothing (nx-scale 1b); `None` for an empty or attach-gap
/// payload, which still requires a reconnect.
pub(crate) fn decode_resync_kitty_graphics_limits(payload: &[u8]) -> Option<KittyGraphicsLimits> {
    if payload.len() != KITTY_GRAPHICS_LIMITS_ENCODED_LEN {
        return None;
    }
    let mut decoder = PayloadDecoder::new(payload);
    let limits = decode_kitty_graphics_limits(&mut decoder).ok()?;
    decoder.finish().ok()?;
    Some(limits)
}

pub(crate) fn encode_kitty_replay_state(
    output: &mut Vec<u8>,
    state: KittyReplayState,
) -> anyhow::Result<()> {
    let state = state
        .validate()
        .map_err(|_| anyhow::anyhow!("terminal-host Kitty replay state is invalid"))?;
    encode_kitty_graphics_limits(output, state.limits)?;
    output.extend_from_slice(&state.replay_cursor_offset.to_le_bytes());
    output.extend_from_slice(&state.replay_next_image_ids.primary.to_le_bytes());
    output.extend_from_slice(&state.next_image_ids.primary.to_le_bytes());
    output.extend_from_slice(&state.replay_next_image_ids.alternate.to_le_bytes());
    output.extend_from_slice(&state.next_image_ids.alternate.to_le_bytes());
    Ok(())
}

pub(crate) fn decode_kitty_replay_state(
    decoder: &mut PayloadDecoder<'_>,
) -> anyhow::Result<KittyReplayState> {
    let limits = decode_kitty_graphics_limits(decoder)?;
    let replay_cursor_offset = decoder.u32()?;
    let primary_replay_next_image_id = decoder.u32()?;
    let primary_next_image_id = decoder.u32()?;
    let alternate_replay_next_image_id = decoder.u32()?;
    let alternate_next_image_id = decoder.u32()?;
    KittyReplayState {
        limits,
        replay_cursor_offset,
        replay_next_image_ids: KittyImageIdCursors {
            primary: primary_replay_next_image_id,
            alternate: alternate_replay_next_image_id,
        },
        next_image_ids: KittyImageIdCursors {
            primary: primary_next_image_id,
            alternate: alternate_next_image_id,
        },
    }
    .validate()
    .map_err(|_| anyhow::anyhow!("terminal-host Kitty replay state is invalid"))
}

pub(crate) fn encode_resize(
    cols: u16,
    rows: u16,
    replay: &[u8],
    kitty_image_aliases: &[KittyImageAlias],
    cell_pixels: (u16, u16),
    kitty_state: KittyReplayState,
) -> anyhow::Result<Vec<u8>> {
    let (cols, rows) = normalize_terminal_geometry(cols, rows)?;
    kitty_state
        .validate_for_replay(replay.len())
        .map_err(|_| anyhow::anyhow!("terminal-host Kitty replay offset is invalid"))?;
    let cell_pixels = (cell_pixels.0.max(1), cell_pixels.1.max(1));
    pty_size(cols, rows, cell_pixels)?;
    if replay.len() > crate::surface::VT_REPLAY_MAX_BYTES {
        anyhow::bail!("terminal-host resize replay is too large");
    }
    let replay_len = u32::try_from(replay.len())
        .map_err(|_| anyhow::anyhow!("terminal-host resize replay exceeds u32"))?;
    let mut output = Vec::with_capacity(
        8 + replay.len()
            + KITTY_IMAGE_ALIAS_COUNT_LEN
            + kitty_image_aliases.len() * KITTY_IMAGE_ALIAS_ENCODED_LEN
            + CELL_PIXEL_SIZE_ENCODED_LEN
            + KITTY_REPLAY_STATE_ENCODED_LEN,
    );
    output.extend_from_slice(&cols.to_le_bytes());
    output.extend_from_slice(&rows.to_le_bytes());
    output.extend_from_slice(&replay_len.to_le_bytes());
    output.extend_from_slice(replay);
    encode_kitty_image_aliases(&mut output, kitty_image_aliases)?;
    output.extend_from_slice(&cell_pixels.0.to_le_bytes());
    output.extend_from_slice(&cell_pixels.1.to_le_bytes());
    encode_kitty_replay_state(&mut output, kitty_state)?;
    if output.len() > MAX_FRAME_PAYLOAD {
        anyhow::bail!("terminal-host resize payload is too large");
    }
    Ok(output)
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) struct DecodedHostResize {
    pub cols: u16,
    pub rows: u16,
    pub cell_pixels: (u16, u16),
    pub replay: Vec<u8>,
    pub kitty_image_aliases: Vec<KittyImageAlias>,
    pub kitty_state: KittyReplayState,
}

#[cfg(test)]
pub(crate) fn decode_host_resize_payload(payload: &[u8]) -> anyhow::Result<DecodedHostResize> {
    decode_host_resize_payload_for_version(payload, PROTOCOL_VERSION)
}

pub(crate) fn decode_host_resize_payload_for_version(
    payload: &[u8],
    protocol_version: u16,
) -> anyhow::Result<DecodedHostResize> {
    if !(LEGACY_PROTOCOL_VERSION..=PROTOCOL_VERSION).contains(&protocol_version) {
        anyhow::bail!("unsupported terminal-host resize protocol {protocol_version}");
    }
    let mut decoder = PayloadDecoder::new(payload);
    let (cols, rows) = normalize_terminal_geometry(decoder.u16()?, decoder.u16()?)?;
    let replay = decoder.bytes_with_limit(crate::surface::VT_REPLAY_MAX_BYTES)?.to_vec();
    let kitty_image_aliases =
        if protocol_version >= 2 { decode_kitty_image_aliases(&mut decoder)? } else { Vec::new() };
    let cell_pixels = if protocol_version >= 2 {
        (decoder.u16()?.max(1), decoder.u16()?.max(1))
    } else {
        DEFAULT_CELL_PIXELS
    };
    let kitty_state = if protocol_version >= 3 {
        decode_kitty_replay_state(&mut decoder)?
            .validate_for_replay(replay.len())
            .map_err(|_| anyhow::anyhow!("terminal-host Kitty replay offset is invalid"))?
    } else {
        KittyReplayState::disabled()
    };
    pty_size(cols, rows, cell_pixels)?;
    decoder.finish()?;
    Ok(DecodedHostResize { cols, rows, cell_pixels, replay, kitty_image_aliases, kitty_state })
}

pub(crate) fn encode_resize_ack(cols: u16, rows: u16, canonical_changed: bool) -> Vec<u8> {
    let mut output = Vec::with_capacity(8);
    output.extend_from_slice(&cols.to_le_bytes());
    output.extend_from_slice(&rows.to_le_bytes());
    output.extend_from_slice(
        &(if canonical_changed { RESIZE_ACK_CANONICAL_CHANGED } else { 0 }).to_le_bytes(),
    );
    output
}

pub(crate) fn protocol_io_error(
    error: crate::terminal_host_protocol::ProtocolError,
) -> std::io::Error {
    match error {
        crate::terminal_host_protocol::ProtocolError::Io(error) => error,
        other => std::io::Error::new(std::io::ErrorKind::InvalidData, other),
    }
}

pub(crate) fn stable_token(value: &str) -> String {
    let mut hash = 0xcbf2_9ce4_8422_2325u64;
    for byte in value.as_bytes() {
        hash ^= u64::from(*byte);
        hash = hash.wrapping_mul(0x100_0000_01b3);
    }
    format!("{hash:016x}")
}

pub(crate) fn constant_time_equal(left: &[u8], right: &[u8]) -> bool {
    if left.len() != right.len() {
        return false;
    }
    let mut difference = 0u8;
    for (left, right) in left.iter().zip(right) {
        difference |= left ^ right;
    }
    difference == 0
}

pub(crate) fn encode_hex(bytes: &[u8]) -> String {
    const HEX: &[u8; 16] = b"0123456789abcdef";
    let mut output = String::with_capacity(bytes.len() * 2);
    for byte in bytes {
        output.push(HEX[(byte >> 4) as usize] as char);
        output.push(HEX[(byte & 0x0f) as usize] as char);
    }
    output
}

pub(crate) fn decode_hex_array<const N: usize>(text: &str) -> anyhow::Result<[u8; N]> {
    if text.len() != N * 2 {
        anyhow::bail!("terminal-host identity has the wrong length");
    }
    let mut bytes = [0u8; N];
    for (index, byte) in bytes.iter_mut().enumerate() {
        let start = index * 2;
        *byte = u8::from_str_radix(&text[start..start + 2], 16)
            .map_err(|_| anyhow::anyhow!("terminal-host identity is not hexadecimal"))?;
    }
    Ok(bytes)
}

pub(crate) fn decode_lower_hex_array<const N: usize>(
    text: &str,
    field: &str,
) -> anyhow::Result<[u8; N]> {
    if !text.bytes().all(|byte| byte.is_ascii_digit() || matches!(byte, b'a'..=b'f')) {
        anyhow::bail!("terminal-host {field} is not canonical lowercase hexadecimal");
    }
    decode_hex_array(text)
}

pub(crate) struct PayloadDecoder<'a> {
    pub(crate) payload: &'a [u8],
    pub(crate) offset: usize,
}

impl<'a> PayloadDecoder<'a> {
    pub(crate) fn new(payload: &'a [u8]) -> Self {
        Self { payload, offset: 0 }
    }

    pub(crate) fn take(&mut self, length: usize) -> anyhow::Result<&'a [u8]> {
        let end = self
            .offset
            .checked_add(length)
            .filter(|end| *end <= self.payload.len())
            .ok_or_else(|| anyhow::anyhow!("truncated terminal-host payload"))?;
        let bytes = &self.payload[self.offset..end];
        self.offset = end;
        Ok(bytes)
    }

    pub(crate) fn u16(&mut self) -> anyhow::Result<u16> {
        Ok(u16::from_le_bytes(self.take(2)?.try_into().unwrap()))
    }

    pub(crate) fn u8(&mut self) -> anyhow::Result<u8> {
        Ok(self.take(1)?[0])
    }

    pub(crate) fn rgb(&mut self) -> anyhow::Result<Rgb> {
        let bytes = self.take(3)?;
        Ok(Rgb { r: bytes[0], g: bytes[1], b: bytes[2] })
    }

    pub(crate) fn u32(&mut self) -> anyhow::Result<u32> {
        Ok(u32::from_le_bytes(self.take(4)?.try_into().unwrap()))
    }

    pub(crate) fn u64(&mut self) -> anyhow::Result<u64> {
        Ok(u64::from_le_bytes(self.take(8)?.try_into().unwrap()))
    }

    pub(crate) fn bytes_with_limit(&mut self, limit: usize) -> anyhow::Result<&'a [u8]> {
        let length = self.u32()? as usize;
        if length > limit {
            anyhow::bail!("terminal-host payload field is too large");
        }
        self.take(length)
    }

    pub(crate) fn blob(&mut self) -> anyhow::Result<&'a [u8]> {
        self.bytes_with_limit(MAX_BLOB)
    }

    pub(crate) fn string(&mut self) -> anyhow::Result<String> {
        Ok(std::str::from_utf8(self.bytes_with_limit(MAX_STRING)?)?.to_string())
    }

    pub(crate) fn optional_string(&mut self) -> anyhow::Result<Option<String>> {
        match self.take(1)?[0] {
            0 => Ok(None),
            1 => Ok(Some(self.string()?)),
            _ => anyhow::bail!("bad terminal-host optional string tag"),
        }
    }

    pub(crate) fn finish(&self) -> anyhow::Result<()> {
        if self.offset != self.payload.len() {
            anyhow::bail!("trailing terminal-host payload bytes");
        }
        Ok(())
    }

    pub(crate) fn has_remaining(&self) -> bool {
        self.offset < self.payload.len()
    }
}

pub(crate) fn put_bytes(output: &mut Vec<u8>, bytes: &[u8]) -> anyhow::Result<()> {
    if bytes.len() > MAX_STRING {
        anyhow::bail!("terminal-host payload field is too large");
    }
    output.extend_from_slice(&(bytes.len() as u32).to_le_bytes());
    output.extend_from_slice(bytes);
    Ok(())
}

pub(crate) fn put_string(output: &mut Vec<u8>, value: &str) -> anyhow::Result<()> {
    put_bytes(output, value.as_bytes())
}

pub(crate) fn put_blob(output: &mut Vec<u8>, value: &[u8]) -> anyhow::Result<()> {
    if value.len() > MAX_BLOB {
        anyhow::bail!("terminal-host payload blob is too large");
    }
    output.extend_from_slice(&(value.len() as u32).to_le_bytes());
    output.extend_from_slice(value);
    Ok(())
}

pub(crate) fn put_optional_string(output: &mut Vec<u8>, value: Option<&str>) -> anyhow::Result<()> {
    match value {
        Some(value) => {
            output.push(1);
            put_string(output, value)
        }
        None => {
            output.push(0);
            Ok(())
        }
    }
}

#[derive(Debug)]
pub(crate) struct HostLaunch {
    pub(crate) endpoint: String,
    pub(crate) record_path: String,
    pub(crate) term: String,
    pub(crate) cols: u16,
    pub(crate) rows: u16,
    pub(crate) cell_pixels: (u16, u16),
    pub(crate) scrollback: usize,
    pub(crate) cwd: Option<String>,
    pub(crate) command: Vec<String>,
    pub(crate) extra_env: Vec<(String, String)>,
    pub(crate) default_colors: DefaultColors,
    pub(crate) kitty_graphics_limits: KittyGraphicsLimits,
    /// VT replay applied to the host's parser before the child's first
    /// byte (cx-6so.49 L2 respawn); an optional trailing blob.
    pub(crate) seed: Vec<u8>,
}

impl HostLaunch {
    pub(crate) fn encode(&self) -> anyhow::Result<Vec<u8>> {
        if self.command.is_empty() || self.command.len() > MAX_ARGV {
            anyhow::bail!("terminal-host command count is out of range");
        }
        if self.extra_env.len() > MAX_ENV {
            anyhow::bail!("terminal-host environment count is out of range");
        }
        let (cols, rows) = normalize_terminal_geometry(self.cols, self.rows)?;
        let cell_pixels = (self.cell_pixels.0.max(1), self.cell_pixels.1.max(1));
        pty_size(cols, rows, cell_pixels)?;
        let mut output = Vec::new();
        put_string(&mut output, &self.endpoint)?;
        put_string(&mut output, &self.record_path)?;
        put_string(&mut output, &self.term)?;
        output.extend_from_slice(&cols.to_le_bytes());
        output.extend_from_slice(&rows.to_le_bytes());
        output.extend_from_slice(
            &u32::try_from(self.scrollback)
                .map_err(|_| anyhow::anyhow!("terminal-host scrollback is too large"))?
                .to_le_bytes(),
        );
        put_optional_string(&mut output, self.cwd.as_deref())?;
        output.extend_from_slice(&(self.command.len() as u16).to_le_bytes());
        for argument in &self.command {
            put_string(&mut output, argument)?;
        }
        output.extend_from_slice(&(self.extra_env.len() as u16).to_le_bytes());
        for (key, value) in &self.extra_env {
            put_string(&mut output, key)?;
            put_string(&mut output, value)?;
        }
        encode_default_colors(&mut output, self.default_colors);
        output.extend_from_slice(&cell_pixels.0.to_le_bytes());
        output.extend_from_slice(&cell_pixels.1.to_le_bytes());
        encode_kitty_graphics_limits(&mut output, self.kitty_graphics_limits)?;
        if output.len() > MAX_LAUNCH_PAYLOAD {
            anyhow::bail!("terminal-host launch payload is too large");
        }
        if !self.seed.is_empty() {
            put_blob(&mut output, &self.seed)?;
        }
        Ok(output)
    }

    pub(crate) fn decode(payload: &[u8]) -> anyhow::Result<Self> {
        let mut decoder = PayloadDecoder::new(payload);
        let endpoint = decoder.string()?;
        let record_path = decoder.string()?;
        let term = decoder.string()?;
        let (cols, rows) = normalize_terminal_geometry(decoder.u16()?, decoder.u16()?)?;
        let scrollback = decoder.u32()? as usize;
        let cwd = decoder.optional_string()?;
        let argc = decoder.u16()? as usize;
        if argc == 0 || argc > MAX_ARGV {
            anyhow::bail!("terminal-host command count is out of range");
        }
        let mut command = Vec::with_capacity(argc);
        for _ in 0..argc {
            command.push(decoder.string()?);
        }
        let envc = decoder.u16()? as usize;
        if envc > MAX_ENV {
            anyhow::bail!("terminal-host environment count is out of range");
        }
        let mut extra_env = Vec::with_capacity(envc);
        for _ in 0..envc {
            extra_env.push((decoder.string()?, decoder.string()?));
        }
        let default_colors = decode_default_colors(&mut decoder)?;
        let cell_pixels = (decoder.u16()?.max(1), decoder.u16()?.max(1));
        pty_size(cols, rows, cell_pixels)?;
        let kitty_graphics_limits = decode_kitty_graphics_limits(&mut decoder)?;
        anyhow::ensure!(decoder.offset <= MAX_LAUNCH_PAYLOAD, "launch is too large");
        let seed = if decoder.has_remaining() { decoder.blob()?.to_vec() } else { Vec::new() };
        decoder.finish()?;
        Ok(Self {
            endpoint,
            record_path,
            term,
            cols,
            rows,
            cell_pixels,
            scrollback,
            cwd,
            command,
            extra_env,
            default_colors,
            kitty_graphics_limits,
            seed,
        })
    }
}

pub(crate) fn encode_default_colors(output: &mut Vec<u8>, colors: DefaultColors) {
    let mut flags = 0u8;
    flags |= colors.fg.is_some() as u8;
    flags |= (colors.bg.is_some() as u8) << 1;
    flags |= (colors.cursor.is_some() as u8) << 2;
    flags |= (colors.cursor_style.is_some() as u8) << 3;
    flags |= (colors.cursor_blink.is_some() as u8) << 4;
    flags |= (colors.selection_bg.is_some() as u8) << 5;
    flags |= (colors.selection_fg.is_some() as u8) << 6;
    output.push(flags);
    for color in [colors.fg, colors.bg, colors.cursor, colors.selection_bg, colors.selection_fg]
        .into_iter()
        .flatten()
    {
        output.extend_from_slice(&[color.r, color.g, color.b]);
    }
    if let Some(style) = colors.cursor_style {
        output.push(match style {
            CursorShape::Block => 1,
            CursorShape::BlockHollow => 2,
            CursorShape::Bar => 3,
            CursorShape::Underline => 4,
        });
    }
    if let Some(blink) = colors.cursor_blink {
        output.push(blink as u8);
    }
    let palette_count = colors.palette.iter().filter(|color| color.is_some()).count() as u16;
    output.extend_from_slice(&palette_count.to_le_bytes());
    for (index, color) in colors.palette.iter().enumerate() {
        if let Some(color) = color {
            output.extend_from_slice(&[index as u8, color.r, color.g, color.b]);
        }
    }
}

pub(crate) fn decode_default_colors(
    decoder: &mut PayloadDecoder<'_>,
) -> anyhow::Result<DefaultColors> {
    let flags = decoder.u8()?;
    if flags & !0b111_1111 != 0 {
        anyhow::bail!("terminal-host default-color flags are out of range");
    }
    let fg = if flags & 1 != 0 { Some(decoder.rgb()?) } else { None };
    let bg = if flags & 2 != 0 { Some(decoder.rgb()?) } else { None };
    let cursor = if flags & 4 != 0 { Some(decoder.rgb()?) } else { None };
    let selection_bg = if flags & 32 != 0 { Some(decoder.rgb()?) } else { None };
    let selection_fg = if flags & 64 != 0 { Some(decoder.rgb()?) } else { None };
    let cursor_style = if flags & 8 != 0 {
        Some(match decoder.u8()? {
            1 => CursorShape::Block,
            2 => CursorShape::BlockHollow,
            3 => CursorShape::Bar,
            4 => CursorShape::Underline,
            _ => anyhow::bail!("terminal-host default cursor style is out of range"),
        })
    } else {
        None
    };
    let cursor_blink = if flags & 16 != 0 {
        Some(match decoder.u8()? {
            0 => false,
            1 => true,
            _ => anyhow::bail!("terminal-host default cursor blink is out of range"),
        })
    } else {
        None
    };
    let palette_count = decoder.u16()? as usize;
    if palette_count > 256 {
        anyhow::bail!("terminal-host default palette count is out of range");
    }
    let mut palette = [None; 256];
    for _ in 0..palette_count {
        let index = decoder.u8()? as usize;
        if palette[index].is_some() {
            anyhow::bail!("duplicate terminal-host default palette index");
        }
        palette[index] = Some(decoder.rgb()?);
    }
    Ok(DefaultColors {
        fg,
        bg,
        cursor,
        selection_bg,
        selection_fg,
        cursor_style,
        cursor_blink,
        palette,
    })
}

pub(crate) fn encode_default_colors_payload(colors: DefaultColors) -> Vec<u8> {
    let mut payload = Vec::new();
    encode_default_colors(&mut payload, colors);
    payload
}

pub(crate) fn decode_default_colors_payload(payload: &[u8]) -> anyhow::Result<DefaultColors> {
    let mut decoder = PayloadDecoder::new(payload);
    let colors = decode_default_colors(&mut decoder)?;
    decoder.finish()?;
    Ok(colors)
}

pub(crate) fn clear_history_ack_status(result: Result<(), ClearHistoryFailure>) -> u8 {
    match result {
        Ok(()) => CLEAR_HISTORY_ACK_OK,
        Err(failure) if failure.delivery() == ClearHistoryDelivery::Ambiguous => {
            CLEAR_HISTORY_ACK_AMBIGUOUS
        }
        Err(failure) => match failure.error().to_string().as_str() {
            CLEAR_HISTORY_PRESERVATION_ERROR => CLEAR_HISTORY_ACK_PRESERVATION_FAILED,
            CLEAR_HISTORY_STREAM_TIMEOUT_ERROR => CLEAR_HISTORY_ACK_STREAM_TIMEOUT,
            CLEAR_HISTORY_FALLBACK_UNREPRESENTABLE_ERROR => {
                CLEAR_HISTORY_ACK_FALLBACK_UNREPRESENTABLE
            }
            CLEAR_HISTORY_FALLBACK_WRITE_TIMEOUT_ERROR => CLEAR_HISTORY_ACK_FALLBACK_WRITE_TIMEOUT,
            _ => CLEAR_HISTORY_ACK_KNOWN_NOT_DELIVERED,
        },
    }
}

pub(crate) fn clear_history_ack_failure(status: u8) -> Option<ClearHistoryFailure> {
    let (delivery, message) = match status {
        CLEAR_HISTORY_ACK_PRESERVATION_FAILED => {
            (ClearHistoryDelivery::KnownNotDelivered, CLEAR_HISTORY_PRESERVATION_ERROR)
        }
        CLEAR_HISTORY_ACK_STREAM_TIMEOUT => {
            (ClearHistoryDelivery::KnownNotDelivered, CLEAR_HISTORY_STREAM_TIMEOUT_ERROR)
        }
        CLEAR_HISTORY_ACK_FALLBACK_UNREPRESENTABLE => {
            (ClearHistoryDelivery::KnownNotDelivered, CLEAR_HISTORY_FALLBACK_UNREPRESENTABLE_ERROR)
        }
        CLEAR_HISTORY_ACK_FALLBACK_WRITE_TIMEOUT => {
            (ClearHistoryDelivery::KnownNotDelivered, CLEAR_HISTORY_FALLBACK_WRITE_TIMEOUT_ERROR)
        }
        CLEAR_HISTORY_ACK_KNOWN_NOT_DELIVERED => (
            ClearHistoryDelivery::KnownNotDelivered,
            "terminal host rejected clear-history before execution",
        ),
        CLEAR_HISTORY_ACK_AMBIGUOUS => (
            ClearHistoryDelivery::Ambiguous,
            "terminal host may have partially applied clear-history",
        ),
        _ => return None,
    };
    let error = anyhow::anyhow!(message);
    Some(match delivery {
        ClearHistoryDelivery::KnownNotDelivered => ClearHistoryFailure::known_not_delivered(error),
        ClearHistoryDelivery::Ambiguous => ClearHistoryFailure::ambiguous(error),
    })
}

pub(crate) fn host_launch_failure(error: &anyhow::Error) -> HostLaunchFailure {
    let kind = if error.chain().any(|cause| {
        cause.downcast_ref::<PtyOpenError>().is_some_and(PtyOpenError::is_capacity_exhausted)
    }) {
        HostLaunchFailureKind::PtyCapacityExhausted
    } else {
        HostLaunchFailureKind::LaunchFailed
    };
    HostLaunchFailure::bounded(kind, format!("terminal launch failed: {error:#}"))
}

pub(crate) fn read_required_frame(reader: &mut impl Read, context: &str) -> anyhow::Result<Frame> {
    read_frame(reader, MAX_FRAME_PAYLOAD)?
        .ok_or_else(|| anyhow::anyhow!("terminal host closed before {context}"))
}
