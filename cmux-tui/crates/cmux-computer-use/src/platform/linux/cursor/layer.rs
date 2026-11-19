//! The wlroots agent cursor: a 24x24 wlr-layer-shell surface on the overlay
//! layer, anchored top-left and moved by its margins, with an empty input
//! region and no keyboard interactivity.

use std::os::fd::AsFd;
use std::sync::Arc;

use wayland_client::globals::{GlobalListContents, registry_queue_init};
use wayland_client::protocol::{
    wl_buffer, wl_compositor, wl_region, wl_registry, wl_shm, wl_shm_pool, wl_surface,
};
use wayland_client::{Connection, Dispatch, EventQueue, QueueHandle, delegate_noop};
use wayland_protocols_wlr::layer_shell::v1::client::{
    zwlr_layer_shell_v1 as shell, zwlr_layer_surface_v1 as surf,
};

use super::super::wlroots::wl::ShmBuffer;
use super::{Channel, Overlay, SIZE, arrow, channel, run};
use crate::cursor::CursorSink;
use crate::desktop::Point;

#[derive(Default)]
struct St {
    configured: bool,
    closed: bool,
}

struct LayerOverlay {
    queue: EventQueue<St>,
    st: St,
    surface: wl_surface::WlSurface,
    layer: surf::ZwlrLayerSurfaceV1,
    buffer: wl_buffer::WlBuffer,
    _shm: ShmBuffer,
    _conn: Connection,
    shown: bool,
}

pub fn spawn() -> Option<Arc<dyn CursorSink>> {
    let (tx, rx) = channel();
    // Wayland objects stay on the thread that made them.
    let (ok_tx, ok_rx) = std::sync::mpsc::channel();
    std::thread::Builder::new()
        .name("cmux-cu-cursor".into())
        .spawn(move || match LayerOverlay::create() {
            Some(o) => {
                let _ = ok_tx.send(true);
                run(o, rx);
            }
            None => {
                let _ = ok_tx.send(false);
            }
        })
        .ok()?;
    if ok_rx.recv().ok()? { Some(Arc::new(Channel(tx))) } else { None }
}

impl LayerOverlay {
    fn create() -> Option<Self> {
        let conn = Connection::connect_to_env().ok()?;
        let (globals, mut queue) = registry_queue_init::<St>(&conn).ok()?;
        let qh = queue.handle();
        let compositor: wl_compositor::WlCompositor = globals.bind(&qh, 4..=6, ()).ok()?;
        let shm: wl_shm::WlShm = globals.bind(&qh, 1..=1, ()).ok()?;
        let layer_shell: shell::ZwlrLayerShellV1 = globals.bind(&qh, 1..=4, ()).ok()?;
        let surface = compositor.create_surface(&qh, ());
        let layer = layer_shell.get_layer_surface(
            &surface,
            None,
            shell::Layer::Overlay,
            "cmux-agent-cursor".into(),
            &qh,
            (),
        );
        layer.set_size(SIZE, SIZE);
        layer.set_anchor(surf::Anchor::Top | surf::Anchor::Left);
        layer.set_exclusive_zone(-1);
        layer.set_keyboard_interactivity(surf::KeyboardInteractivity::None);
        let region = compositor.create_region(&qh, ());
        surface.set_input_region(Some(&region));
        region.destroy();
        surface.commit();
        let mut st = St::default();
        while !st.configured && !st.closed {
            queue.blocking_dispatch(&mut st).ok()?;
        }
        let (pixels, _) = arrow();
        let len = pixels.len();
        let mem = ShmBuffer::new(len).ok()?;
        mem.write(&pixels);
        let pool = shm.create_pool(mem.fd.as_fd(), len as i32, &qh, ());
        let buffer = pool.create_buffer(
            0,
            SIZE as i32,
            SIZE as i32,
            (SIZE * 4) as i32,
            wl_shm::Format::Argb8888,
            &qh,
            (),
        );
        pool.destroy();
        Some(Self { queue, st, surface, layer, buffer, _shm: mem, _conn: conn, shown: false })
    }
}

impl Overlay for LayerOverlay {
    fn show_at(&mut self, p: Point) {
        if self.st.closed {
            return;
        }
        // Margins are relative to the output the compositor put us on (the
        // focused one); on a single output that is the layout origin.
        self.layer.set_margin((p.y - 1.0).max(0.0) as i32, 0, 0, (p.x - 1.0).max(0.0) as i32);
        if !self.shown {
            self.surface.attach(Some(&self.buffer), 0, 0);
            self.surface.damage_buffer(0, 0, SIZE as i32, SIZE as i32);
            self.shown = true;
        }
        self.surface.commit();
        let _ = self.queue.roundtrip(&mut self.st);
    }

    fn hide(&mut self) {
        if self.shown {
            self.surface.attach(None, 0, 0);
            self.surface.commit();
            let _ = self.queue.roundtrip(&mut self.st);
            self.shown = false;
            // A layer surface unmapped by a null buffer must be configured again.
            self.st.configured = false;
            self.layer.set_size(SIZE, SIZE);
            self.surface.commit();
            while !self.st.configured && !self.st.closed {
                if self.queue.blocking_dispatch(&mut self.st).is_err() {
                    break;
                }
            }
        }
    }
}

impl Dispatch<surf::ZwlrLayerSurfaceV1, ()> for St {
    fn event(
        st: &mut Self,
        s: &surf::ZwlrLayerSurfaceV1,
        e: surf::Event,
        _: &(),
        _: &Connection,
        _: &QueueHandle<Self>,
    ) {
        match e {
            surf::Event::Configure { serial, .. } => {
                s.ack_configure(serial);
                st.configured = true;
            }
            surf::Event::Closed => st.closed = true,
            _ => {}
        }
    }
}

impl Dispatch<wl_registry::WlRegistry, GlobalListContents> for St {
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

delegate_noop!(St: wl_compositor::WlCompositor);
delegate_noop!(St: ignore wl_shm::WlShm);
delegate_noop!(St: wl_shm_pool::WlShmPool);
delegate_noop!(St: ignore wl_buffer::WlBuffer);
delegate_noop!(St: ignore wl_surface::WlSurface);
delegate_noop!(St: wl_region::WlRegion);
delegate_noop!(St: shell::ZwlrLayerShellV1);
