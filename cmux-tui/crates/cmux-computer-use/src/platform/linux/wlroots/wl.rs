//! The Wayland client side of the wlroots backend: outputs (with their
//! logical layout from xdg-output), wlr-screencopy, wlr-virtual-pointer,
//! zwp-virtual-keyboard and wlr-foreign-toplevel. Pure Rust (no libwayland).

use std::os::fd::{AsFd, FromRawFd, OwnedFd};

use wayland_client::globals::{GlobalListContents, registry_queue_init};
use wayland_client::protocol::{wl_buffer, wl_output, wl_registry, wl_seat, wl_shm, wl_shm_pool};
use wayland_client::{
    Connection, Dispatch, EventQueue, Proxy, QueueHandle, WEnum, delegate_noop, event_created_child,
};
use wayland_protocols::xdg::xdg_output::zv1::client::{zxdg_output_manager_v1, zxdg_output_v1};
use wayland_protocols_misc::zwp_virtual_keyboard_v1::client::{
    zwp_virtual_keyboard_manager_v1, zwp_virtual_keyboard_v1,
};
use wayland_protocols_wlr::foreign_toplevel::v1::client::{
    zwlr_foreign_toplevel_handle_v1 as tl_handle, zwlr_foreign_toplevel_manager_v1 as tl_manager,
};
use wayland_protocols_wlr::screencopy::v1::client::{
    zwlr_screencopy_frame_v1 as sc_frame, zwlr_screencopy_manager_v1 as sc_manager,
};
use wayland_protocols_wlr::virtual_pointer::v1::client::{
    zwlr_virtual_pointer_manager_v1 as vp_manager, zwlr_virtual_pointer_v1 as vp,
};

use super::super::WaylandCaps;
use crate::desktop::{DResult, DesktopError, Point, RawFrame, Rect};

#[derive(Clone, Debug, Default)]
pub struct Output {
    pub wl: Option<wl_output::WlOutput>,
    pub name: String,
    pub logical: Rect,
    pub mode: (i32, i32),
    pub scale: i32,
}

#[derive(Clone, Debug, Default)]
pub struct Toplevel {
    pub handle: Option<tl_handle::ZwlrForeignToplevelHandleV1>,
    pub serial: u64,
    pub title: String,
    pub app_id: String,
    pub activated: bool,
    pub minimized: bool,
    pub closed: bool,
}

#[derive(Default)]
struct Capture {
    buffer: Option<(WEnum<wl_shm::Format>, u32, u32, u32)>,
    buffer_done: bool,
    ready: bool,
    failed: bool,
    y_invert: bool,
}

#[derive(Default)]
pub struct State {
    pub outputs: Vec<Output>,
    pub toplevels: Vec<Toplevel>,
    next_serial: u64,
    capture: Capture,
}

pub struct Wl {
    _conn: Connection,
    queue: EventQueue<State>,
    pub state: State,
    qh: QueueHandle<State>,
    shm: wl_shm::WlShm,
    screencopy: Option<(sc_manager::ZwlrScreencopyManagerV1, u32)>,
    pointer: Option<vp::ZwlrVirtualPointerV1>,
    keyboard: Option<zwp_virtual_keyboard_v1::ZwpVirtualKeyboardV1>,
    seat: Option<wl_seat::WlSeat>,
    keymap: Vec<u32>,
    pub caps: WaylandCaps,
    pub toplevel_list: bool,
}

fn werr(e: impl std::fmt::Display) -> DesktopError {
    DesktopError::Failed(format!("Wayland: {e}"))
}

impl Wl {
    pub fn connect() -> Result<Self, String> {
        let conn = Connection::connect_to_env().map_err(|e| format!("Wayland: {e}"))?;
        let (globals, mut queue) =
            registry_queue_init::<State>(&conn).map_err(|e| format!("Wayland registry: {e}"))?;
        let qh = queue.handle();
        let mut state = State::default();
        let shm: wl_shm::WlShm =
            globals.bind(&qh, 1..=1, ()).map_err(|e| format!("wl_shm: {e}"))?;
        let seat: Option<wl_seat::WlSeat> = globals.bind(&qh, 1..=1, ()).ok();
        let xdg: Option<zxdg_output_manager_v1::ZxdgOutputManagerV1> =
            globals.bind(&qh, 2..=3, ()).ok();
        let list = globals.contents().clone_list();
        for g in list.iter().filter(|g| g.interface == wl_output::WlOutput::interface().name) {
            let idx = state.outputs.len();
            let out: wl_output::WlOutput =
                globals.registry().bind(g.name, g.version.min(4), &qh, idx);
            if let Some(m) = &xdg {
                m.get_xdg_output(&out, &qh, idx);
            }
            state.outputs.push(Output { wl: Some(out), scale: 1, ..Output::default() });
        }
        let screencopy = list
            .iter()
            .find(|g| g.interface == sc_manager::ZwlrScreencopyManagerV1::interface().name)
            .map(|g| {
                let v = g.version.min(3);
                (
                    globals.registry().bind::<sc_manager::ZwlrScreencopyManagerV1, _, _>(
                        g.name,
                        v,
                        &qh,
                        (),
                    ),
                    v,
                )
            });
        let vpm: Option<vp_manager::ZwlrVirtualPointerManagerV1> =
            globals.bind(&qh, 1..=2, ()).ok();
        let vkm: Option<zwp_virtual_keyboard_manager_v1::ZwpVirtualKeyboardManagerV1> =
            globals.bind(&qh, 1..=1, ()).ok();
        let tlm: Option<tl_manager::ZwlrForeignToplevelManagerV1> =
            globals.bind(&qh, 1..=3, ()).ok();
        let pointer = vpm.as_ref().map(|m| m.create_virtual_pointer(seat.as_ref(), &qh, ()));
        let keyboard = match (&vkm, &seat) {
            (Some(m), Some(s)) => Some(m.create_virtual_keyboard(s, &qh, ())),
            _ => None,
        };
        queue.roundtrip(&mut state).map_err(|e| format!("Wayland: {e}"))?;
        queue.roundtrip(&mut state).map_err(|e| format!("Wayland: {e}"))?;
        let caps = WaylandCaps {
            screencopy: screencopy.is_some(),
            virtual_pointer: pointer.is_some(),
            virtual_keyboard: keyboard.is_some(),
        };
        Ok(Self {
            _conn: conn,
            queue,
            state,
            qh,
            shm,
            screencopy,
            pointer,
            keyboard,
            seat,
            keymap: Vec::new(),
            caps,
            toplevel_list: tlm.is_some(),
        })
    }

    /// Activates a foreign toplevel (Foreground, or a headless session).
    pub fn activate(&mut self, serial: u64) -> DResult<()> {
        let seat =
            self.seat.clone().ok_or_else(|| DesktopError::Unsupported("no Wayland seat".into()))?;
        let t = self.state.toplevels.iter().find(|t| t.serial == serial && !t.closed);
        let h = t
            .and_then(|t| t.handle.clone())
            .ok_or_else(|| DesktopError::TargetNotFound("the window is gone".into()))?;
        h.activate(&seat);
        self.sync()?;
        self.sync()
    }

    pub fn sync(&mut self) -> DResult<()> {
        self.queue.roundtrip(&mut self.state).map_err(werr)?;
        Ok(())
    }

    /// The bounding box of every output, in layout coordinates.
    pub fn layout(&self) -> Rect {
        let rects: Vec<Rect> = self.state.outputs.iter().map(|o| o.logical).collect();
        super::super::union(&rects).unwrap_or_default()
    }

    /// One output's pixels.
    pub fn capture_output(&mut self, idx: usize) -> DResult<RawFrame> {
        let (mgr, version) = self.screencopy.clone().ok_or_else(|| {
            DesktopError::Unsupported("this compositor does not offer wlr-screencopy".into())
        })?;
        let out = self
            .state
            .outputs
            .get(idx)
            .cloned()
            .ok_or_else(|| DesktopError::TargetNotFound("output".into()))?;
        let wl = out.wl.clone().ok_or_else(|| DesktopError::TargetNotFound("output".into()))?;
        self.state.capture = Capture::default();
        let frame = mgr.capture_output(0, &wl, &self.qh, ());
        let result = self.copy_frame(&frame, version);
        frame.destroy();
        let (rgba, w, h) = result?;
        let scale = if out.logical.width > 0.0 { f64::from(w) / out.logical.width } else { 1.0 };
        Ok(RawFrame {
            width: w,
            height: h,
            rgba,
            scale,
            origin: Point { x: out.logical.x, y: out.logical.y },
        })
    }

    fn copy_frame(
        &mut self,
        frame: &sc_frame::ZwlrScreencopyFrameV1,
        version: u32,
    ) -> DResult<(Vec<u8>, u32, u32)> {
        while !(self.state.capture.failed
            || (self.state.capture.buffer.is_some()
                && (version < 3 || self.state.capture.buffer_done)))
        {
            self.queue.blocking_dispatch(&mut self.state).map_err(werr)?;
        }
        let (format, w, h, stride) =
            self.state.capture.buffer.ok_or_else(|| {
                DesktopError::Failed("the compositor refused the screen copy".into())
            })?;
        let size = (stride * h) as usize;
        let shm = ShmBuffer::new(size)?;
        let pool = self.shm.create_pool(shm.fd.as_fd(), size as i32, &self.qh, ());
        let fmt = match format {
            WEnum::Value(f) => f,
            WEnum::Unknown(_) => {
                return Err(DesktopError::Unsupported("unknown screencopy pixel format".into()));
            }
        };
        let buffer = pool.create_buffer(0, w as i32, h as i32, stride as i32, fmt, &self.qh, ());
        frame.copy(&buffer);
        while !(self.state.capture.ready || self.state.capture.failed) {
            if let Err(e) = self.queue.blocking_dispatch(&mut self.state) {
                buffer.destroy();
                pool.destroy();
                return Err(werr(e));
            }
        }
        let failed = self.state.capture.failed;
        let rgba = if failed {
            None
        } else {
            Some(to_rgba(shm.bytes(), fmt, w, h, stride, self.state.capture.y_invert))
        };
        buffer.destroy();
        pool.destroy();
        match rgba {
            Some(Ok(rgba)) => Ok((rgba, w, h)),
            Some(Err(e)) => Err(e),
            None => Err(DesktopError::Failed("the compositor failed the screen copy".into())),
        }
    }

    fn pointer(&self) -> DResult<&vp::ZwlrVirtualPointerV1> {
        self.pointer.as_ref().ok_or_else(|| {
            DesktopError::Unsupported("this compositor does not offer wlr-virtual-pointer".into())
        })
    }

    pub fn motion(&mut self, p: Point) -> DResult<()> {
        let l = self.layout();
        let ptr = self.pointer()?;
        let x = (p.x - l.x).clamp(0.0, l.width - 1.0) as u32;
        let y = (p.y - l.y).clamp(0.0, l.height - 1.0) as u32;
        super::super::mark_injection();
        ptr.motion_absolute(ms(), x, y, l.width as u32, l.height as u32);
        ptr.frame();
        Ok(())
    }

    pub fn button(&mut self, code: u32, press: bool) -> DResult<()> {
        let ptr = self.pointer()?;
        super::super::mark_injection();
        let state = if press {
            wayland_client::protocol::wl_pointer::ButtonState::Pressed
        } else {
            wayland_client::protocol::wl_pointer::ButtonState::Released
        };
        ptr.button(ms(), code, state);
        ptr.frame();
        Ok(())
    }

    pub fn axis(&mut self, vertical: bool, lines: i32) -> DResult<()> {
        use wayland_client::protocol::wl_pointer::{Axis, AxisSource};
        let ptr = self.pointer()?;
        super::super::mark_injection();
        let axis = if vertical { Axis::VerticalScroll } else { Axis::HorizontalScroll };
        ptr.axis_source(AxisSource::Wheel);
        ptr.axis_discrete(ms(), axis, f64::from(lines) * 15.0, lines);
        ptr.frame();
        Ok(())
    }

    /// Uploads a keymap holding exactly `syms`, then presses and releases
    /// them per `plan` (index into `syms`, press or release).
    pub fn keys(&mut self, syms: &[u32], plan: &[(usize, bool)]) -> DResult<()> {
        let kb = self.ensure_keymap(syms)?;
        for (i, press) in plan {
            let Some(at) = syms.get(*i).and_then(|s| self.keymap.iter().position(|k| k == s))
            else {
                continue;
            };
            super::super::mark_injection();
            kb.key(ms(), super::super::keysym::evdev_code(at), u32::from(*press));
        }
        self.sync()
    }

    /// Makes the virtual keyboard's keymap hold `syms`. Call it before
    /// moving focus: a client that gets keyboard focus and a new keymap in
    /// the same burst drops the first keys (seen with foot on Sway).
    pub fn ensure_keymap(
        &mut self,
        syms: &[u32],
    ) -> DResult<zwp_virtual_keyboard_v1::ZwpVirtualKeyboardV1> {
        let kb = self.keyboard.clone().ok_or_else(|| {
            DesktopError::Unsupported("this compositor does not offer a virtual keyboard".into())
        })?;
        // A new keymap resets the compositor's key state, so modifiers held
        // across calls (click with modifiers) keep the map they went down with.
        if !syms.iter().all(|s| self.keymap.contains(s)) {
            let mut all = self.keymap.clone();
            all.extend(syms.iter().filter(|s| !self.keymap.contains(s)));
            if all.len() > 200 {
                all = syms.to_vec();
            }
            let mut bytes = super::super::keysym::keymap_for(&all).into_bytes();
            bytes.push(0);
            let shm = ShmBuffer::new(bytes.len())?;
            shm.write(&bytes);
            kb.keymap(1, shm.fd.as_fd(), bytes.len() as u32);
            self.keymap = all;
            self.sync()?;
        }
        Ok(kb)
    }
}

fn ms() -> u32 {
    super::super::now_ms() as u32
}

/// Screencopy formats to RGBA (little-endian 32-bit formats).
fn to_rgba(
    src: &[u8],
    fmt: wl_shm::Format,
    w: u32,
    h: u32,
    stride: u32,
    y_invert: bool,
) -> DResult<Vec<u8>> {
    use wl_shm::Format as F;
    let order: [usize; 3] = match fmt {
        F::Argb8888 | F::Xrgb8888 => [2, 1, 0],
        F::Abgr8888 | F::Xbgr8888 => [0, 1, 2],
        other => return Err(DesktopError::Unsupported(format!("screencopy format {other:?}"))),
    };
    let mut out = Vec::with_capacity((w * h * 4) as usize);
    for row in 0..h {
        let r = if y_invert { h - 1 - row } else { row };
        let line = &src[(r * stride) as usize..];
        for x in 0..w as usize {
            let p = &line[x * 4..x * 4 + 4];
            out.extend_from_slice(&[p[order[0]], p[order[1]], p[order[2]], 255]);
        }
    }
    Ok(out)
}

/// An anonymous shared-memory file, mapped.
pub struct ShmBuffer {
    pub fd: OwnedFd,
    ptr: *mut u8,
    len: usize,
}

// SAFETY: the mapping is owned by this value and only read or written
// through &self methods while the compositor is not writing (after Ready).
unsafe impl Send for ShmBuffer {}

impl ShmBuffer {
    pub fn new(len: usize) -> DResult<Self> {
        // SAFETY: plain syscalls; every result is checked.
        unsafe {
            let raw = libc::memfd_create(c"cmux-computer-use".as_ptr(), libc::MFD_CLOEXEC);
            if raw < 0 {
                return Err(DesktopError::Failed("memfd_create failed".into()));
            }
            let fd = OwnedFd::from_raw_fd(raw);
            if libc::ftruncate(raw, len as libc::off_t) != 0 {
                return Err(DesktopError::Failed("ftruncate failed".into()));
            }
            let ptr = libc::mmap(
                std::ptr::null_mut(),
                len,
                libc::PROT_READ | libc::PROT_WRITE,
                libc::MAP_SHARED,
                raw,
                0,
            );
            if ptr == libc::MAP_FAILED {
                return Err(DesktopError::Failed("mmap failed".into()));
            }
            Ok(Self { fd, ptr: ptr.cast(), len })
        }
    }

    pub fn bytes(&self) -> &[u8] {
        // SAFETY: ptr..ptr+len is our live mapping.
        unsafe { std::slice::from_raw_parts(self.ptr, self.len) }
    }

    pub fn write(&self, data: &[u8]) {
        let n = data.len().min(self.len);
        // SAFETY: n bytes fit in the mapping; the source does not overlap it.
        unsafe { std::ptr::copy_nonoverlapping(data.as_ptr(), self.ptr, n) };
    }
}

impl Drop for ShmBuffer {
    fn drop(&mut self) {
        // SAFETY: unmaps the mapping made in new().
        unsafe { libc::munmap(self.ptr.cast(), self.len) };
    }
}

// ----- dispatch -------------------------------------------------------------

impl Dispatch<wl_registry::WlRegistry, GlobalListContents> for State {
    fn event(
        _: &mut Self,
        _: &wl_registry::WlRegistry,
        _: wl_registry::Event,
        _: &GlobalListContents,
        _: &Connection,
        _: &QueueHandle<Self>,
    ) {
    }
}

impl Dispatch<wl_output::WlOutput, usize> for State {
    fn event(
        state: &mut Self,
        _: &wl_output::WlOutput,
        event: wl_output::Event,
        idx: &usize,
        _: &Connection,
        _: &QueueHandle<Self>,
    ) {
        let Some(o) = state.outputs.get_mut(*idx) else { return };
        match event {
            wl_output::Event::Mode { width, height, .. } => o.mode = (width, height),
            wl_output::Event::Scale { factor } => o.scale = factor,
            wl_output::Event::Name { name } => o.name = name,
            wl_output::Event::Geometry { x, y, .. } if o.logical.width == 0.0 => {
                o.logical.x = f64::from(x);
                o.logical.y = f64::from(y);
            }
            _ => {}
        }
        if o.logical.width == 0.0 && o.mode.0 > 0 {
            let s = f64::from(o.scale.max(1));
            o.logical.width = f64::from(o.mode.0) / s;
            o.logical.height = f64::from(o.mode.1) / s;
        }
    }
}

impl Dispatch<zxdg_output_v1::ZxdgOutputV1, usize> for State {
    fn event(
        state: &mut Self,
        _: &zxdg_output_v1::ZxdgOutputV1,
        event: zxdg_output_v1::Event,
        idx: &usize,
        _: &Connection,
        _: &QueueHandle<Self>,
    ) {
        let Some(o) = state.outputs.get_mut(*idx) else { return };
        match event {
            zxdg_output_v1::Event::LogicalPosition { x, y } => {
                o.logical.x = f64::from(x);
                o.logical.y = f64::from(y);
            }
            zxdg_output_v1::Event::LogicalSize { width, height } => {
                o.logical.width = f64::from(width);
                o.logical.height = f64::from(height);
            }
            zxdg_output_v1::Event::Name { name } if o.name.is_empty() => o.name = name,
            _ => {}
        }
    }
}

impl Dispatch<sc_frame::ZwlrScreencopyFrameV1, ()> for State {
    fn event(
        state: &mut Self,
        _: &sc_frame::ZwlrScreencopyFrameV1,
        event: sc_frame::Event,
        _: &(),
        _: &Connection,
        _: &QueueHandle<Self>,
    ) {
        let c = &mut state.capture;
        match event {
            sc_frame::Event::Buffer { format, width, height, stride } => {
                c.buffer = Some((format, width, height, stride))
            }
            sc_frame::Event::BufferDone => c.buffer_done = true,
            sc_frame::Event::Flags { flags } => {
                c.y_invert =
                    matches!(flags, WEnum::Value(f) if f.contains(sc_frame::Flags::YInvert));
            }
            sc_frame::Event::Ready { .. } => c.ready = true,
            sc_frame::Event::Failed => c.failed = true,
            _ => {}
        }
    }
}

impl Dispatch<tl_manager::ZwlrForeignToplevelManagerV1, ()> for State {
    fn event(
        state: &mut Self,
        _: &tl_manager::ZwlrForeignToplevelManagerV1,
        event: tl_manager::Event,
        _: &(),
        _: &Connection,
        _: &QueueHandle<Self>,
    ) {
        if let tl_manager::Event::Toplevel { toplevel } = event {
            state.next_serial += 1;
            state.toplevels.push(Toplevel {
                handle: Some(toplevel),
                serial: state.next_serial,
                ..Toplevel::default()
            });
        }
    }

    event_created_child!(State, tl_manager::ZwlrForeignToplevelManagerV1, [
        tl_manager::EVT_TOPLEVEL_OPCODE => (tl_handle::ZwlrForeignToplevelHandleV1, ()),
    ]);
}

impl Dispatch<tl_handle::ZwlrForeignToplevelHandleV1, ()> for State {
    fn event(
        state: &mut Self,
        h: &tl_handle::ZwlrForeignToplevelHandleV1,
        event: tl_handle::Event,
        _: &(),
        _: &Connection,
        _: &QueueHandle<Self>,
    ) {
        let Some(t) = state.toplevels.iter_mut().find(|t| t.handle.as_ref() == Some(h)) else {
            return;
        };
        match event {
            tl_handle::Event::Title { title } => t.title = title,
            tl_handle::Event::AppId { app_id } => t.app_id = app_id,
            tl_handle::Event::State { state: s } => {
                let words: Vec<u32> = s
                    .chunks_exact(4)
                    .map(|c| u32::from_ne_bytes([c[0], c[1], c[2], c[3]]))
                    .collect();
                t.activated = words.contains(&(tl_handle::State::Activated as u32));
                t.minimized = words.contains(&(tl_handle::State::Minimized as u32));
            }
            tl_handle::Event::Closed => t.closed = true,
            _ => {}
        }
    }
}

delegate_noop!(State: ignore wl_shm::WlShm);
delegate_noop!(State: ignore wl_seat::WlSeat);
delegate_noop!(State: ignore wl_buffer::WlBuffer);
delegate_noop!(State: wl_shm_pool::WlShmPool);
delegate_noop!(State: zxdg_output_manager_v1::ZxdgOutputManagerV1);
delegate_noop!(State: sc_manager::ZwlrScreencopyManagerV1);
delegate_noop!(State: vp_manager::ZwlrVirtualPointerManagerV1);
delegate_noop!(State: vp::ZwlrVirtualPointerV1);
delegate_noop!(State: zwp_virtual_keyboard_manager_v1::ZwpVirtualKeyboardManagerV1);
delegate_noop!(State: zwp_virtual_keyboard_v1::ZwpVirtualKeyboardV1);
