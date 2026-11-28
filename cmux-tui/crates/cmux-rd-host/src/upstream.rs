//! Upstream media streams a viewer opens on this host (rd change C4): the
//! microphone (`up_audio`) or a camera or screen share (`up_video`). The
//! viewer sends `stream_open` only after the user's consent for that kind;
//! this host answers it, registers the stream with the engine (reassembly,
//! FEC, acks and NACKs), hands complete frames to the sink that plays them
//! into the desktop, and forgets every stream when the session ends.
//!
//! A host offers the `up_media` cap only when it has a sink for at least one
//! kind ([`UpstreamSink::accepts`]); a viewer whose welcome does not list
//! `up_media` and `stream.open` sends nothing upstream.

use std::collections::BTreeMap;

use cmux_rd_core::reassembly::CompleteFrame;
use cmux_rd_core::service::caps;
use cmux_rd_engine::MediaEngine;
use cmux_rd_proto::control::{Control, StreamKind};

/// Where the desktop plays upstream media (a virtual microphone or camera).
pub trait UpstreamSink {
    /// This sink can play streams of `kind` (only upstream kinds are asked).
    fn accepts(&self, kind: StreamKind) -> bool;
    /// A stream of `kind` starts; an error refuses it (`unsupported`).
    fn open(&mut self, stream: u16, kind: StreamKind) -> Result<(), String>;
    /// One complete frame of an opened stream, in frame order.
    fn frame(&mut self, stream: u16, frame: &CompleteFrame);
    /// The stream ended (closed by the viewer or the session ended).
    fn close(&mut self, stream: u16);
}

/// No virtual microphone or camera on this host yet: accepts nothing, so the
/// host offers no `up_media` cap.
pub struct NoSink;

impl UpstreamSink for NoSink {
    fn accepts(&self, _kind: StreamKind) -> bool {
        false
    }
    fn open(&mut self, _stream: u16, _kind: StreamKind) -> Result<(), String> {
        Err("no sink".into())
    }
    fn frame(&mut self, _stream: u16, _frame: &CompleteFrame) {}
    fn close(&mut self, _stream: u16) {}
}

/// The host's sink, chosen per session: no sink by default, a recording sink
/// for development (`--upstream-record DIR`).
impl UpstreamSink for Box<dyn UpstreamSink> {
    fn accepts(&self, kind: StreamKind) -> bool {
        (**self).accepts(kind)
    }
    fn open(&mut self, stream: u16, kind: StreamKind) -> Result<(), String> {
        (**self).open(stream, kind)
    }
    fn frame(&mut self, stream: u16, frame: &CompleteFrame) {
        (**self).frame(stream, frame)
    }
    fn close(&mut self, stream: u16) {
        (**self).close(stream)
    }
}

/// FNV-1a over the bytes of every frame of a stream, in frame order: the bench
/// reports the same value for the frames it sent, so a run proves that the
/// host received each sent frame once, whole and in order.
pub fn fnv1a(hash: u64, bytes: &[u8]) -> u64 {
    bytes.iter().fold(hash, |h, &b| (h ^ u64::from(b)).wrapping_mul(0x0000_0100_0000_01b3))
}

/// The FNV-1a start value.
pub const FNV_OFFSET: u64 = 0xcbf2_9ce4_8422_2325;

/// Development sink (`cmux-rd host --upstream-record DIR`): accepts the
/// viewer's microphone, camera and screen share and writes each stream to its
/// own file in `DIR` (owner-only), so a run can check what arrived. Video is
/// the raw Annex-B stream (`.h264`, playable by ffplay); audio is each Opus
/// packet after a little-endian u16 length (`.opus-packets`). Off by default:
/// the files hold the viewer's microphone and screen. Writes are synchronous
/// on the session's media loop (acceptable for a development flag). One
/// session writes at most `max_bytes` and opens at most [`MAX_RECORD_FILES`]
/// files; past that it stops writing and refuses new streams.
pub struct RecordSink {
    dir: std::path::PathBuf,
    max_bytes: u64,
    written: u64,
    files: u32,
    streams: BTreeMap<u16, Recording>,
}

/// Most files one session's [`RecordSink`] opens.
pub const MAX_RECORD_FILES: u32 = 64;

struct Recording {
    kind: StreamKind,
    path: std::path::PathBuf,
    file: std::io::BufWriter<std::fs::File>,
    /// Frames and bytes received; after an error, more than were written.
    frames: u64,
    bytes: u64,
    hash: u64,
    error: Option<String>,
}

impl RecordSink {
    /// Creates `dir` (owner-only) when it is missing. Refuses a path that is
    /// a symlink, not a directory, owned by another user, or open to group
    /// or others.
    pub fn new(dir: &std::path::Path, max_bytes: u64) -> std::io::Result<Self> {
        use std::os::unix::fs::{DirBuilderExt, MetadataExt};
        std::fs::DirBuilder::new().recursive(true).mode(0o700).create(dir)?;
        let meta = std::fs::symlink_metadata(dir)?;
        // SAFETY: geteuid has no preconditions and cannot fail.
        let euid = unsafe { libc::geteuid() };
        if !meta.file_type().is_dir() || meta.uid() != euid || meta.mode() & 0o077 != 0 {
            return Err(std::io::Error::other(format!(
                "{} must be a real directory owned by this user with mode 0700",
                dir.display()
            )));
        }
        Ok(Self {
            dir: dir.to_path_buf(),
            max_bytes,
            written: 0,
            files: 0,
            streams: BTreeMap::new(),
        })
    }

    fn fail(stream: u16, rec: &mut Recording, error: String) {
        if rec.error.is_none() {
            eprintln!("upstream record stream {stream}: {error}; writing stops");
            rec.error = Some(error);
        }
    }

    fn finish(stream: u16, mut rec: Recording) {
        use std::io::Write;
        if let Err(e) = rec.file.flush() {
            rec.error.get_or_insert(e.to_string());
        }
        eprintln!(
            "{}",
            serde_json::json!({
                "upstream_recorded": {
                    "stream": stream,
                    "kind": format!("{:?}", rec.kind),
                    "path": rec.path.display().to_string(),
                    "frames": rec.frames,
                    "bytes": rec.bytes,
                    "fnv1a": format!("{:016x}", rec.hash),
                    "error": rec.error,
                }
            })
        );
    }
}

impl Drop for RecordSink {
    fn drop(&mut self) {
        for (stream, rec) in std::mem::take(&mut self.streams) {
            Self::finish(stream, rec);
        }
    }
}

impl UpstreamSink for RecordSink {
    fn accepts(&self, kind: StreamKind) -> bool {
        kind.is_upstream()
    }

    fn open(&mut self, stream: u16, kind: StreamKind) -> Result<(), String> {
        use std::os::unix::fs::OpenOptionsExt;
        if self.files >= MAX_RECORD_FILES || self.written >= self.max_bytes {
            return Err("record limit reached".into());
        }
        self.files += 1;
        let millis = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .map_or(0, |d| d.as_millis());
        let ext = if kind == StreamKind::UpAudio { "opus-packets" } else { "h264" };
        let path = self.dir.join(format!("up-{millis}-{stream}-{}.{ext}", self.files));
        let file = std::fs::OpenOptions::new()
            .write(true)
            .create_new(true)
            .mode(0o600)
            .open(&path)
            .map_err(|e| format!("{}: {e}", path.display()))?;
        if let Some(old) = self.streams.insert(
            stream,
            Recording {
                kind,
                path,
                file: std::io::BufWriter::new(file),
                frames: 0,
                bytes: 0,
                hash: FNV_OFFSET,
                error: None,
            },
        ) {
            Self::finish(stream, old);
        }
        Ok(())
    }

    fn frame(&mut self, stream: u16, frame: &CompleteFrame) {
        use std::io::Write;
        let Some(rec) = self.streams.get_mut(&stream) else { return };
        let au = &frame.body.access_unit;
        rec.frames += 1;
        rec.bytes += au.len() as u64;
        rec.hash = fnv1a(rec.hash, au);
        if rec.error.is_some() {
            return;
        }
        let audio = rec.kind == StreamKind::UpAudio;
        let cost = au.len() as u64 + if audio { 2 } else { 0 };
        if self.written + cost > self.max_bytes {
            Self::fail(stream, rec, format!("record limit of {} bytes reached", self.max_bytes));
            return;
        }
        let written = if audio {
            // An Opus packet is at most 1275 bytes; a longer frame is not Opus.
            match u16::try_from(au.len()) {
                Ok(len) => {
                    rec.file.write_all(&len.to_le_bytes()).and_then(|()| rec.file.write_all(au))
                }
                Err(_) => Err(std::io::Error::other("audio frame longer than 65535 bytes")),
            }
        } else {
            rec.file.write_all(au)
        };
        match written {
            Ok(()) => self.written += cost,
            Err(e) => Self::fail(stream, rec, e.to_string()),
        }
    }

    fn close(&mut self, stream: u16) {
        if let Some(rec) = self.streams.remove(&stream) {
            Self::finish(stream, rec);
        }
    }
}

/// The sink for one session: a [`RecordSink`] in `record_dir` (at most
/// `max_bytes` per session), else [`NoSink`]. A recording sink that cannot
/// start is logged and the session gets [`NoSink`] (no upstream caps), so a
/// viewer that asked for no upstream media still connects.
pub fn session_sink(record_dir: Option<&std::path::Path>, max_bytes: u64) -> Box<dyn UpstreamSink> {
    match record_dir.map(|dir| (dir, RecordSink::new(dir, max_bytes))) {
        Some((_, Ok(sink))) => Box::new(sink),
        Some((dir, Err(e))) => {
            eprintln!(
                "upstream record {}: {e}; this session offers no upstream media",
                dir.display()
            );
            Box::new(NoSink)
        }
        None => Box::new(NoSink),
    }
}

/// The caps a host with `sink` adds to its welcome offer.
pub fn offered_caps(sink: &dyn UpstreamSink) -> Vec<&'static str> {
    if [StreamKind::UpAudio, StreamKind::UpVideo].into_iter().any(|k| sink.accepts(k)) {
        vec![caps::UP_MEDIA, caps::STREAM_OPEN]
    } else {
        Vec::new()
    }
}

/// The upstream streams of one session.
pub struct Upstreams<S: UpstreamSink> {
    sink: S,
    /// Both `up_media` and `stream.open` were negotiated.
    enabled: bool,
    open: BTreeMap<u16, StreamKind>,
}

impl<S: UpstreamSink> Upstreams<S> {
    /// `negotiated` is the welcome's caps list.
    pub fn new(sink: S, negotiated: &[String]) -> Self {
        let has = |cap: &str| negotiated.iter().any(|c| c == cap);
        Self { sink, enabled: has(caps::UP_MEDIA) && has(caps::STREAM_OPEN), open: BTreeMap::new() }
    }

    /// Handles a control message from the viewer; returns the answer to send.
    /// Messages that are not about upstream streams return `None`.
    /// `may_control`: the viewer holds control of this desktop now; a
    /// view-only viewer may not feed a microphone or camera into it.
    pub fn on_control(
        &mut self,
        engine: &mut MediaEngine,
        control: &Control,
        may_control: bool,
    ) -> Option<Control> {
        match control {
            Control::StreamOpen { stream, kind, codec, of } => {
                let stream = *stream;
                let answer = match self.open(engine, stream, *kind, codec, *of, may_control) {
                    Ok(()) => Control::StreamOpened { stream },
                    Err(reason) => Control::StreamRefused { stream, reason: reason.into() },
                };
                Some(answer)
            }
            Control::StreamClose { stream } => {
                self.close(engine, *stream);
                None
            }
            _ => None,
        }
    }

    fn open(
        &mut self,
        engine: &mut MediaEngine,
        stream: u16,
        kind: StreamKind,
        codec: &str,
        of: Option<u16>,
        may_control: bool,
    ) -> Result<(), &'static str> {
        if !self.enabled {
            return Err("caps");
        }
        // Host-to-viewer kinds are the host's to open, never the viewer's;
        // only tile streams name a surface.
        if !kind.is_upstream() || of.is_some() {
            return Err("kind");
        }
        if !may_control {
            return Err("view_only");
        }
        if kind.codec() != Some(codec) {
            return Err("codec");
        }
        if !self.sink.accepts(kind) {
            return Err("unsupported");
        }
        engine.add_upstream(stream).map_err(|e| e.reason())?;
        if self.sink.open(stream, kind).is_err() {
            engine.remove_upstream(stream);
            return Err("unsupported");
        }
        self.open.insert(stream, kind);
        Ok(())
    }

    fn close(&mut self, engine: &mut MediaEngine, stream: u16) {
        if self.open.remove(&stream).is_some() {
            engine.remove_upstream(stream);
            self.sink.close(stream);
        }
    }

    /// Hands the engine's complete upstream frames to the sink (frames of a
    /// stream that is no longer open are dropped).
    pub fn deliver(&mut self, frames: &[(u16, CompleteFrame)]) {
        for (stream, frame) in frames {
            if self.open.contains_key(stream) {
                self.sink.frame(*stream, frame);
            }
        }
    }

    /// Ends every stream (session end, host stop, disconnect, or the viewer
    /// lost control); returns the streams it closed.
    pub fn close_all(&mut self, engine: &mut MediaEngine) -> Vec<u16> {
        let streams: Vec<u16> = self.open.keys().copied().collect();
        for &stream in &streams {
            self.close(engine, stream);
        }
        streams
    }
}
