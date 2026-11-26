//! The PipeWire half of Wayland capture (feature `portal`): connects to the PipeWire remote
//! the ScreenCast portal opened (src/portal.rs), or to the default remote for a stream mutter
//! cast directly (src/mutter.rs), takes the stream of the shared monitor and
//! keeps its newest picture as BGRX, the same bytes `capture::Capturer::grab` returns on X11.
//!
//! - Formats: BGRx, RGBx, BGRA and RGBA (alpha ignored). No modifier is offered, so the
//!   compositor sends SHM (MemFd or MemPtr) buffers; DMA-BUF import is later work.
//! - Damage: the SPA `VideoDamage` meta when the compositor fills it, else the whole frame.
//! - Threads: the PipeWire main loop runs on its own thread. Each buffer is converted into the
//!   shared frame under a lock, its damage is queued and an eventfd turns readable, so the
//!   host's poll loop wakes on [`PwStream::fd`] as it does on the X connection.
//!
//! No live capture test runs on the fleet (it has no PipeWire session); the conversion and the
//! damage rules are unit-tested below.

use crate::capture::{DamageEvent, Rect};
use crate::Res;
use pipewire as pw;
use pw::spa;
use spa::pod::{ChoiceValue, Object, Property, PropertyFlags, Value};
use spa::utils::{Choice, ChoiceEnum, ChoiceFlags, Id};
use std::os::fd::{AsRawFd, FromRawFd, OwnedFd, RawFd};
use std::sync::{mpsc, Arc, Mutex};
use std::time::Duration;

/// The byte order of one negotiated pixel (4 bytes each; the 4th is padding or alpha).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum PixelFormat {
    /// B, G, R, X in memory (also BGRA): what the encoder path takes as is.
    Bgrx,
    /// R, G, B, X in memory (also RGBA): red and blue swap on the way in.
    Rgbx,
}

impl PixelFormat {
    fn from_spa(f: spa::param::video::VideoFormat) -> Option<Self> {
        use spa::param::video::VideoFormat as F;
        if f == F::BGRx || f == F::BGRA {
            Some(Self::Bgrx)
        } else if f == F::RGBx || f == F::RGBA {
            Some(Self::Rgbx)
        } else {
            None
        }
    }
}

/// Copies rectangle `r` of a source picture (`src_stride` bytes per row, format `fmt`) into
/// the same place of a BGRX picture with `dst_stride` bytes per row. `r` must lie inside both.
pub fn copy_rect_to_bgrx(
    src: &[u8],
    src_stride: usize,
    fmt: PixelFormat,
    r: Rect,
    dst: &mut [u8],
    dst_stride: usize,
) {
    let (x, w) = (r.x as usize * 4, r.w as usize * 4);
    for row in r.y as usize..(r.y + r.h) as usize {
        let s = &src[row * src_stride + x..row * src_stride + x + w];
        let d = &mut dst[row * dst_stride + x..row * dst_stride + x + w];
        match fmt {
            PixelFormat::Bgrx => d.copy_from_slice(s),
            PixelFormat::Rgbx => {
                for (dp, sp) in d.chunks_exact_mut(4).zip(s.chunks_exact(4)) {
                    dp[0] = sp[2];
                    dp[1] = sp[1];
                    dp[2] = sp[0];
                    dp[3] = sp[3];
                }
            }
        }
    }
}

/// The damage of one buffer: its `VideoDamage` regions clipped to the `w` x `h` picture, or
/// the whole picture when the compositor sent none (no meta, or only empty regions).
/// Regions are `(x, y, width, height)`; the list ends at the first empty one, as in SPA.
pub fn damage_rects(regions: Option<&[(i32, i32, u32, u32)]>, w: u32, h: u32) -> Vec<Rect> {
    let full = vec![Rect { x: 0, y: 0, w, h }];
    let Some(regions) = regions else { return full };
    let mut out = Vec::new();
    for &(x, y, rw, rh) in regions {
        if rw == 0 || rh == 0 {
            break;
        }
        let x0 = x.clamp(0, w as i32) as u32;
        let y0 = y.clamp(0, h as i32) as u32;
        let x1 = (i64::from(x) + i64::from(rw)).clamp(0, i64::from(w)) as u32;
        let y1 = (i64::from(y) + i64::from(rh)).clamp(0, i64::from(h)) as u32;
        if x1 > x0 && y1 > y0 {
            out.push(Rect { x: x0, y: y0, w: x1 - x0, h: y1 - y0 });
        }
    }
    if out.is_empty() {
        full
    } else {
        out
    }
}

/// The newest picture and the damage not yet drained, shared with the PipeWire thread.
struct Frame {
    width: u32,
    height: u32,
    /// BGRX, `width * 4` bytes per row; sized at the first negotiated format.
    pixels: Vec<u8>,
    damage: Vec<Rect>,
    error: Option<String>,
}

struct Shared {
    frame: Mutex<Frame>,
    /// eventfd: readable while damage waits in `frame`.
    wake: OwnedFd,
}

impl Shared {
    fn signal(&self) {
        let one: u64 = 1;
        // SAFETY: writes 8 bytes from a live u64 to our own eventfd.
        unsafe { libc::write(self.wake.as_raw_fd(), (&one as *const u64).cast(), 8) };
    }

    fn fail(&self, msg: String) {
        if let Ok(mut f) = self.frame.lock() {
            f.error.get_or_insert(msg);
        }
        self.signal();
    }
}

/// A running PipeWire stream of one screen-cast node.
pub struct PwStream {
    shared: Arc<Shared>,
    quit: Option<pw::channel::Sender<()>>,
    thread: Option<std::thread::JoinHandle<()>>,
    /// The size negotiated first; the picture keeps it (a later resize is clipped or padded).
    pub width: u32,
    pub height: u32,
}

/// Reads the newest picture of a [`PwStream`] from another thread (the session's encode
/// thread) while the stream's owner drains damage.
pub struct PwFrames {
    shared: Arc<Shared>,
    scratch: Vec<u8>,
}

impl PwStream {
    /// Connects to the portal's PipeWire remote `fd` (`None`: the session's default remote,
    /// where mutter's own screen casts live), streams node `node_id` and waits up to `timeout`
    /// for the first negotiated format.
    pub fn start(fd: Option<OwnedFd>, node_id: u32, timeout: Duration) -> Res<Self> {
        // SAFETY: a fresh eventfd; checked below.
        let efd = unsafe { libc::eventfd(0, libc::EFD_NONBLOCK | libc::EFD_CLOEXEC) };
        if efd < 0 {
            return Err(std::io::Error::last_os_error().into());
        }
        // SAFETY: efd is a new descriptor we own.
        let wake = unsafe { OwnedFd::from_raw_fd(efd) };
        let shared = Arc::new(Shared {
            frame: Mutex::new(Frame {
                width: 0,
                height: 0,
                pixels: Vec::new(),
                damage: Vec::new(),
                error: None,
            }),
            wake,
        });
        let (ready_tx, ready_rx) = mpsc::channel::<Result<(u32, u32), String>>();
        let (quit_tx, quit_rx) = pw::channel::channel::<()>();
        let thread_shared = shared.clone();
        let thread =
            std::thread::Builder::new().name("cmux-rd-pipewire".into()).spawn(move || {
                let err_tx = ready_tx.clone();
                if let Err(e) = run_loop(fd, node_id, thread_shared.clone(), ready_tx, quit_rx) {
                    let msg = format!("pipewire: {e}");
                    let _ = err_tx.send(Err(msg.clone()));
                    thread_shared.fail(msg);
                }
            })?;
        let mut me =
            Self { shared, quit: Some(quit_tx), thread: Some(thread), width: 0, height: 0 };
        match ready_rx.recv_timeout(timeout) {
            Ok(Ok((w, h))) => {
                me.width = w;
                me.height = h;
                Ok(me)
            }
            Ok(Err(e)) => Err(e.into()),
            Err(_) => Err(format!(
                "pipewire: no video format from the screen cast within {} s",
                timeout.as_secs()
            )
            .into()),
        }
    }

    /// Readable when [`PwStream::drain`] has damage (or an error) to report.
    pub fn fd(&self) -> RawFd {
        self.shared.wake.as_raw_fd()
    }

    /// Takes the damage queued since the last call, without blocking. Fails once the stream
    /// failed (the portal session ended, the compositor went away).
    pub fn drain(&mut self, out: &mut Vec<DamageEvent>) -> Res<()> {
        let mut buf = [0u8; 8];
        // SAFETY: reads at most 8 bytes into a live buffer from our nonblocking eventfd.
        unsafe { libc::read(self.fd(), buf.as_mut_ptr().cast(), 8) };
        let mut f = self.shared.frame.lock().map_err(|_| "pipewire frame lock poisoned")?;
        if let Some(e) = f.error.take() {
            return Err(e.into());
        }
        out.extend(f.damage.drain(..).map(|rect| DamageEvent { rect }));
        Ok(())
    }

    /// A reader of this stream's newest picture for another thread.
    pub fn frames(&self) -> PwFrames {
        PwFrames { shared: self.shared.clone(), scratch: Vec::new() }
    }
}

impl PwFrames {
    /// Copies `r` of the newest picture out as BGRX rows with stride `r.w * 4`, like
    /// `Capturer::grab`. `r` is clipped to the picture.
    pub fn grab(&mut self, r: Rect) -> Res<&[u8]> {
        let f = self.shared.frame.lock().map_err(|_| "pipewire frame lock poisoned")?;
        let r = clip(r, f.width, f.height);
        let row = r.w as usize * 4;
        self.scratch.clear();
        self.scratch.reserve(row * r.h as usize);
        let stride = f.width as usize * 4;
        for y in r.y as usize..(r.y + r.h) as usize {
            let start = y * stride + r.x as usize * 4;
            self.scratch.extend_from_slice(&f.pixels[start..start + row]);
        }
        Ok(&self.scratch)
    }
}

impl Drop for PwStream {
    fn drop(&mut self) {
        if let Some(q) = self.quit.take() {
            let _ = q.send(());
        }
        if let Some(t) = self.thread.take() {
            let _ = t.join();
        }
    }
}

fn clip(r: Rect, w: u32, h: u32) -> Rect {
    let x = r.x.min(w);
    let y = r.y.min(h);
    Rect { x, y, w: r.w.min(w - x), h: r.h.min(h - y) }
}

struct UserData {
    shared: Arc<Shared>,
    fmt: Option<(PixelFormat, u32, u32)>,
    ready: Option<mpsc::Sender<Result<(u32, u32), String>>>,
}

fn pod_bytes(obj: Object) -> Result<Vec<u8>, String> {
    spa::pod::serialize::PodSerializer::serialize(
        std::io::Cursor::new(Vec::new()),
        &Value::Object(obj),
    )
    .map(|(c, _)| c.into_inner())
    .map_err(|e| format!("pod: {e:?}"))
}

fn prop(key: u32, value: Value) -> Property {
    Property { key, flags: PropertyFlags::empty(), value }
}

/// EnumFormat: raw video in the four 32-bit RGB orders, any size, any rate.
fn enum_format_pod() -> Result<Vec<u8>, String> {
    use spa::sys as s;
    let fmts = [
        s::SPA_VIDEO_FORMAT_BGRx,
        s::SPA_VIDEO_FORMAT_RGBx,
        s::SPA_VIDEO_FORMAT_BGRA,
        s::SPA_VIDEO_FORMAT_RGBA,
    ];
    pod_bytes(Object {
        type_: s::SPA_TYPE_OBJECT_Format,
        id: s::SPA_PARAM_EnumFormat,
        properties: vec![
            prop(s::SPA_FORMAT_mediaType, Value::Id(Id(s::SPA_MEDIA_TYPE_video))),
            prop(s::SPA_FORMAT_mediaSubtype, Value::Id(Id(s::SPA_MEDIA_SUBTYPE_raw))),
            prop(
                s::SPA_FORMAT_VIDEO_format,
                Value::Choice(ChoiceValue::Id(Choice(
                    ChoiceFlags::empty(),
                    ChoiceEnum::Enum {
                        default: Id(fmts[0]),
                        alternatives: fmts.iter().map(|&f| Id(f)).collect(),
                    },
                ))),
            ),
            prop(
                s::SPA_FORMAT_VIDEO_size,
                Value::Choice(ChoiceValue::Rectangle(Choice(
                    ChoiceFlags::empty(),
                    ChoiceEnum::Range {
                        default: spa::utils::Rectangle { width: 1920, height: 1080 },
                        min: spa::utils::Rectangle { width: 1, height: 1 },
                        max: spa::utils::Rectangle { width: 16384, height: 16384 },
                    },
                ))),
            ),
            prop(
                s::SPA_FORMAT_VIDEO_framerate,
                Value::Choice(ChoiceValue::Fraction(Choice(
                    ChoiceFlags::empty(),
                    ChoiceEnum::Range {
                        default: spa::utils::Fraction { num: 60, denom: 1 },
                        min: spa::utils::Fraction { num: 0, denom: 1 },
                        max: spa::utils::Fraction { num: 1000, denom: 1 },
                    },
                ))),
            ),
        ],
    })
}

/// Buffers: memory the CPU maps (MemFd, MemPtr), and the VideoDamage meta (up to 16 regions).
fn buffer_pods() -> Result<(Vec<u8>, Vec<u8>), String> {
    use spa::sys as s;
    let types = ((1u32 << s::SPA_DATA_MemFd) | (1u32 << s::SPA_DATA_MemPtr)) as i32;
    let buffers = pod_bytes(Object {
        type_: s::SPA_TYPE_OBJECT_ParamBuffers,
        id: s::SPA_PARAM_Buffers,
        properties: vec![prop(
            s::SPA_PARAM_BUFFERS_dataType,
            Value::Choice(ChoiceValue::Int(Choice(
                ChoiceFlags::empty(),
                ChoiceEnum::Flags { default: types, flags: vec![] },
            ))),
        )],
    })?;
    let region = std::mem::size_of::<s::spa_meta_region>() as i32;
    let meta = pod_bytes(Object {
        type_: s::SPA_TYPE_OBJECT_ParamMeta,
        id: s::SPA_PARAM_Meta,
        properties: vec![
            prop(s::SPA_PARAM_META_type, Value::Id(Id(s::SPA_META_VideoDamage))),
            prop(
                s::SPA_PARAM_META_size,
                Value::Choice(ChoiceValue::Int(Choice(
                    ChoiceFlags::empty(),
                    ChoiceEnum::Range { default: region * 16, min: region, max: region * 16 },
                ))),
            ),
        ],
    })?;
    Ok((buffers, meta))
}

fn run_loop(
    fd: Option<OwnedFd>,
    node_id: u32,
    shared: Arc<Shared>,
    ready: mpsc::Sender<Result<(u32, u32), String>>,
    quit: pw::channel::Receiver<()>,
) -> Result<(), String> {
    pw::init();
    let mainloop = pw::main_loop::MainLoopRc::new(None).map_err(|e| e.to_string())?;
    let context = pw::context::ContextRc::new(&mainloop, None).map_err(|e| e.to_string())?;
    let core = match fd {
        Some(fd) => context
            .connect_fd_rc(fd, None)
            .map_err(|e| format!("connect to the portal's remote: {e}"))?,
        None => context
            .connect_rc(None)
            .map_err(|e| format!("connect to the session's PipeWire: {e}"))?,
    };
    let stream = pw::stream::StreamBox::new(
        &core,
        "cmux-rd-capture",
        pw::properties::properties! {
            *pw::keys::MEDIA_TYPE => "Video",
            *pw::keys::MEDIA_CATEGORY => "Capture",
            *pw::keys::MEDIA_ROLE => "Screen",
        },
    )
    .map_err(|e| e.to_string())?;
    let data = UserData { shared: shared.clone(), fmt: None, ready: Some(ready) };
    let _listener = stream
        .add_local_listener_with_user_data(data)
        .state_changed(|_, ud, _old, new| {
            if let pw::stream::StreamState::Error(e) = new {
                let msg = format!("pipewire stream error: {e}");
                if let Some(r) = ud.ready.take() {
                    let _ = r.send(Err(msg.clone()));
                }
                ud.shared.fail(msg);
            } else if matches!(new, pw::stream::StreamState::Unconnected) && ud.fmt.is_some() {
                ud.shared.fail("the screen cast ended".into());
            }
        })
        .param_changed(|stream, ud, id, param| {
            let Some(param) = param else { return };
            if id != spa::param::ParamType::Format.as_raw() {
                return;
            }
            let mut info = spa::param::video::VideoInfoRaw::default();
            if info.parse(param).is_err() {
                return;
            }
            let size = info.size();
            let Some(pf) = PixelFormat::from_spa(info.format()) else {
                let msg = format!("unsupported pixel format {:?}", info.format());
                if let Some(r) = ud.ready.take() {
                    let _ = r.send(Err(msg.clone()));
                }
                ud.shared.fail(msg);
                return;
            };
            ud.fmt = Some((pf, size.width, size.height));
            if let Ok(mut f) = ud.shared.frame.lock() {
                if f.pixels.is_empty() {
                    f.width = size.width;
                    f.height = size.height;
                    f.pixels = vec![0; size.width as usize * size.height as usize * 4];
                }
            }
            if let Some(r) = ud.ready.take() {
                let _ = r.send(Ok((size.width, size.height)));
            }
            if let Ok((b, m)) = buffer_pods() {
                if let (Some(b), Some(m)) =
                    (spa::pod::Pod::from_bytes(&b), spa::pod::Pod::from_bytes(&m))
                {
                    let _ = stream.update_params(&mut [b, m]);
                }
            }
        })
        .process(|stream, ud| loop {
            // SAFETY: a buffer dequeued from this stream, queued back below.
            let pwb = unsafe { stream.dequeue_raw_buffer() };
            if pwb.is_null() {
                break;
            }
            if let Some(fmt) = ud.fmt {
                // SAFETY: pwb is a live buffer of this stream until it is queued back.
                unsafe { take_buffer(pwb, fmt, &ud.shared) };
            }
            // SAFETY: returns the buffer dequeued above.
            unsafe { stream.queue_raw_buffer(pwb) };
        })
        .register()
        .map_err(|e| e.to_string())?;
    let fmt = enum_format_pod()?;
    let mut params = [spa::pod::Pod::from_bytes(&fmt).ok_or("format pod")?];
    stream
        .connect(
            spa::utils::Direction::Input,
            Some(node_id),
            pw::stream::StreamFlags::AUTOCONNECT | pw::stream::StreamFlags::MAP_BUFFERS,
            &mut params,
        )
        .map_err(|e| format!("connect to node {node_id}: {e}"))?;
    let ml = mainloop.clone();
    let _quit = quit.attach(mainloop.loop_(), move |()| ml.quit());
    mainloop.run();
    Ok(())
}

/// Converts the damaged part of one SHM buffer into the shared picture and queues its damage.
///
/// # Safety
/// `pwb` must be a buffer dequeued from the stream and not yet queued back.
// Bindgen's integer types for SPA macros differ between libspa versions.
#[allow(clippy::unnecessary_cast)]
unsafe fn take_buffer(
    pwb: *mut pw::sys::pw_buffer,
    (fmt, w, h): (PixelFormat, u32, u32),
    shared: &Shared,
) {
    use spa::sys as s;
    let sb = (*pwb).buffer;
    if sb.is_null() || (*sb).n_datas == 0 || (*sb).datas.is_null() {
        return;
    }
    let d = &*(*sb).datas;
    if d.data.is_null() || d.chunk.is_null() {
        // Not CPU-mapped (DMA-BUF): not negotiated by this backend.
        return;
    }
    let chunk = &*d.chunk;
    if chunk.size == 0 || (chunk.flags as u32 & s::SPA_CHUNK_FLAG_CORRUPTED as u32) != 0 {
        return;
    }
    let stride = if chunk.stride > 0 { chunk.stride as usize } else { w as usize * 4 };
    let offset = (chunk.offset % d.maxsize.max(1)) as usize;
    let len = (d.maxsize as usize).saturating_sub(offset);
    let src = std::slice::from_raw_parts((d.data as *const u8).add(offset), len);
    let mut regions: Option<Vec<(i32, i32, u32, u32)>> = None;
    for i in 0..(*sb).n_metas as usize {
        let m = &*(*sb).metas.add(i);
        if m.type_ == s::SPA_META_VideoDamage && !m.data.is_null() {
            let n = m.size as usize / std::mem::size_of::<s::spa_meta_region>();
            let rs = std::slice::from_raw_parts(m.data as *const s::spa_meta_region, n);
            regions = Some(
                rs.iter()
                    .map(|r| {
                        (
                            r.region.position.x,
                            r.region.position.y,
                            r.region.size.width,
                            r.region.size.height,
                        )
                    })
                    .collect(),
            );
        }
    }
    let Ok(mut f) = shared.frame.lock() else { return };
    // The rows the buffer really holds, and the part of it inside the picture.
    let rows = (len / stride.max(1)).min(h as usize) as u32;
    let (cw, ch) = (w.min(f.width).min((stride / 4) as u32), rows.min(f.height));
    let dst_stride = f.width as usize * 4;
    let mut queued = false;
    for r in damage_rects(regions.as_deref(), w, h) {
        let r = clip(r, cw, ch);
        if r.w == 0 || r.h == 0 {
            continue;
        }
        copy_rect_to_bgrx(src, stride, fmt, r, &mut f.pixels, dst_stride);
        f.damage.push(r);
        queued = true;
    }
    drop(f);
    if queued {
        shared.signal();
    }
}

#[cfg(test)]
#[path = "pipewire_capture_tests.rs"]
mod tests;
