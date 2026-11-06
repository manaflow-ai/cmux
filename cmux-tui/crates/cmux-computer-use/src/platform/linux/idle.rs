//! The person's own input, for pause-on-takeover.
//!
//! - X11: the MIT-SCREEN-SAVER idle time (milliseconds since the last real
//!   input event). XTest input also resets it, so input within
//!   [`OWN_INPUT_GRACE`] of our own injection is not counted as the person.
//! - GNOME on Wayland: `org.gnome.Mutter.IdleMonitor.GetIdletime`.
//! - Other Wayland compositors: `ext-idle-notify-v1` (Sway, Hyprland, KDE,
//!   river, Wayfire). It reports idle after a timeout and resumed on input;
//!   a notification of 1 s idle is subscribed, so "idle" is known within a
//!   second of the person stopping.
//! - Headless sessions and nothing available: [`NoTakeover`].

use std::sync::Arc;
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::time::{Duration, Instant};

use crate::engine::{NoTakeover, PersonActivity};

use super::{last_injection_ms, now_ms};

/// The person counts as idle after this long without input.
pub const IDLE_AFTER: Duration = Duration::from_millis(1500);
/// Input this soon after our own injection is ours.
pub const OWN_INPUT_GRACE: Duration = Duration::from_millis(800);

/// Idle time in milliseconds, from some source.
trait IdleSource: Send + Sync {
    fn idle_ms(&self) -> Option<u64>;
}

pub struct Monitor {
    source: Box<dyn IdleSource>,
}

impl PersonActivity for Monitor {
    fn wait_idle(&self, limit: Duration) -> bool {
        let deadline = Instant::now() + limit;
        loop {
            match self.source.idle_ms() {
                None => return true,
                Some(idle) if person_idle(idle, now_ms(), last_injection_ms()) => return true,
                Some(_) => {}
            }
            if Instant::now() >= deadline {
                return false;
            }
            // Polls the server's idle counter; not a synchronization sleep.
            std::thread::park_timeout(Duration::from_millis(100));
        }
    }
}

/// True when the last input was long enough ago, or was our own.
pub fn person_idle(idle_ms: u64, now: u64, last_injection: u64) -> bool {
    if idle_ms >= IDLE_AFTER.as_millis() as u64 {
        return true;
    }
    let last_input = now.saturating_sub(idle_ms);
    last_injection != 0
        && last_input <= last_injection + OWN_INPUT_GRACE.as_millis() as u64
        && last_input + 50 >= last_injection
}

pub fn open() -> Arc<dyn PersonActivity> {
    let env = super::Env::from_process();
    if std::env::var("CMUX_CU_HEADLESS").is_ok_and(|v| v == "1") {
        return Arc::new(NoTakeover);
    }
    if env.wayland_socket().is_some() {
        if let Some(m) = Mutter::connect() {
            return Arc::new(Monitor { source: Box::new(m) });
        }
        if let Some(n) = ext::IdleNotify::start() {
            return Arc::new(Monitor { source: Box::new(n) });
        }
        return Arc::new(NoTakeover);
    }
    if env.display.is_some()
        && let Some(x) = X11Idle::connect()
    {
        return Arc::new(Monitor { source: Box::new(x) });
    }
    Arc::new(NoTakeover)
}

struct X11Idle {
    conn: x11rb::rust_connection::RustConnection,
    root: u32,
}

impl X11Idle {
    fn connect() -> Option<Self> {
        use x11rb::connection::{Connection as _, RequestConnection as _};
        let (conn, screen) = x11rb::connect(None).ok()?;
        let root = conn.setup().roots.get(screen)?.root;
        conn.extension_information(x11rb::protocol::screensaver::X11_EXTENSION_NAME).ok()??;
        Some(Self { conn, root })
    }
}

impl IdleSource for X11Idle {
    fn idle_ms(&self) -> Option<u64> {
        use x11rb::protocol::screensaver::ConnectionExt as _;
        let r = self.conn.screensaver_query_info(self.root).ok()?.reply().ok()?;
        Some(u64::from(r.ms_since_user_input))
    }
}

struct Mutter {
    conn: zbus::blocking::Connection,
}

impl Mutter {
    fn connect() -> Option<Self> {
        let conn = zbus::blocking::Connection::session().ok()?;
        let me = Self { conn };
        me.idle_ms()?;
        Some(me)
    }
}

impl IdleSource for Mutter {
    fn idle_ms(&self) -> Option<u64> {
        let m = self
            .conn
            .call_method(
                Some("org.gnome.Mutter.IdleMonitor"),
                "/org/gnome/Mutter/IdleMonitor/Core",
                Some("org.gnome.Mutter.IdleMonitor"),
                "GetIdletime",
                &(),
            )
            .ok()?;
        m.body().deserialize::<u64>().ok()
    }
}

mod ext {
    //! ext-idle-notify-v1 on its own connection and thread.
    use super::*;
    use wayland_client::globals::{GlobalListContents, registry_queue_init};
    use wayland_client::protocol::{wl_registry, wl_seat};
    use wayland_client::{Connection, Dispatch, QueueHandle, delegate_noop};
    use wayland_protocols::ext::idle_notify::v1::client::{
        ext_idle_notification_v1 as note, ext_idle_notifier_v1 as notifier,
    };

    pub struct IdleNotify {
        idle: Arc<AtomicBool>,
        since: Arc<AtomicU64>,
    }

    struct St {
        idle: Arc<AtomicBool>,
        since: Arc<AtomicU64>,
    }

    impl IdleNotify {
        pub fn start() -> Option<Self> {
            let conn = Connection::connect_to_env().ok()?;
            let (globals, mut queue) = registry_queue_init::<St>(&conn).ok()?;
            let qh = queue.handle();
            let seat: wl_seat::WlSeat = globals.bind(&qh, 1..=1, ()).ok()?;
            let n: notifier::ExtIdleNotifierV1 = globals.bind(&qh, 1..=1, ()).ok()?;
            n.get_idle_notification(IDLE_AFTER.as_millis() as u32, &seat, &qh, ());
            let idle = Arc::new(AtomicBool::new(false));
            let since = Arc::new(AtomicU64::new(now_ms()));
            let mut st = St { idle: idle.clone(), since: since.clone() };
            std::thread::Builder::new()
                .name("cmux-cu-idle".into())
                .spawn(move || while queue.blocking_dispatch(&mut st).is_ok() {})
                .ok()?;
            Some(Self { idle, since })
        }
    }

    impl IdleSource for IdleNotify {
        fn idle_ms(&self) -> Option<u64> {
            if self.idle.load(Ordering::Relaxed) {
                // Idle at least IDLE_AFTER, plus the time since the notice.
                let since = self.since.load(Ordering::Relaxed);
                return Some(IDLE_AFTER.as_millis() as u64 + now_ms().saturating_sub(since));
            }
            Some(
                now_ms()
                    .saturating_sub(self.since.load(Ordering::Relaxed))
                    .min(IDLE_AFTER.as_millis() as u64 - 1),
            )
        }
    }

    impl Dispatch<note::ExtIdleNotificationV1, ()> for St {
        fn event(
            st: &mut Self,
            _: &note::ExtIdleNotificationV1,
            e: note::Event,
            _: &(),
            _: &Connection,
            _: &QueueHandle<Self>,
        ) {
            match e {
                note::Event::Idled => {
                    st.idle.store(true, Ordering::Relaxed);
                    st.since.store(now_ms(), Ordering::Relaxed);
                }
                note::Event::Resumed => {
                    st.idle.store(false, Ordering::Relaxed);
                    st.since.store(now_ms(), Ordering::Relaxed);
                }
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

    delegate_noop!(St: ignore wl_seat::WlSeat);
    delegate_noop!(St: notifier::ExtIdleNotifierV1);
}
