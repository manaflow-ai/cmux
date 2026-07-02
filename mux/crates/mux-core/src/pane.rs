use std::io::{Read, Write};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::{Arc, Mutex, Weak};

use ghostty_vt::{Callbacks, RenderState, Terminal};
use portable_pty::{native_pty_system, ChildKiller, CommandBuilder, MasterPty, PtySize};

use crate::{Mux, MuxEvent, PaneId};

/// How to spawn pane children.
#[derive(Debug, Clone)]
pub struct PaneOptions {
    /// Command argv; defaults to `$SHELL` (interactive) or `/bin/sh`.
    pub command: Option<Vec<String>>,
    pub cwd: Option<String>,
    /// TERM value for children. xterm-256color is the compatible default;
    /// set xterm-ghostty when the ghostty terminfo is installed.
    pub term: String,
    pub cols: u16,
    pub rows: u16,
    pub scrollback: usize,
    /// Extra environment for children (e.g. CMUX_MUX_SOCKET).
    pub extra_env: Vec<(String, String)>,
}

impl Default for PaneOptions {
    fn default() -> Self {
        PaneOptions {
            command: None,
            cwd: None,
            term: std::env::var("CMUX_MUX_TERM").unwrap_or_else(|_| "xterm-256color".into()),
            cols: 80,
            rows: 24,
            scrollback: 10_000,
            extra_env: Vec::new(),
        }
    }
}

/// A single terminal pane: PTY child plus ghostty VT state.
///
/// The terminal is behind a mutex; the pty reader thread holds it only
/// while feeding bytes, renderers hold it only while snapshotting into a
/// [`RenderState`].
pub struct Pane {
    pub id: PaneId,
    term: Mutex<Terminal>,
    writer: Mutex<Box<dyn Write + Send>>,
    master: Mutex<Box<dyn MasterPty + Send>>,
    killer: Mutex<Box<dyn ChildKiller + Send>>,
    dead: AtomicBool,
    /// Set when output arrived since the last render; cleared by the
    /// frontend when it draws.
    dirty: AtomicBool,
    title: Mutex<String>,
    pwd: Mutex<Option<String>>,
    size: Mutex<(u16, u16)>,
}

impl std::fmt::Debug for Pane {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("Pane").field("id", &self.id).finish()
    }
}

impl Pane {
    pub(crate) fn spawn(
        id: PaneId,
        opts: PaneOptions,
        mux: Weak<Mux>,
    ) -> anyhow::Result<Arc<Pane>> {
        let pty = native_pty_system().openpty(PtySize {
            rows: opts.rows,
            cols: opts.cols,
            pixel_width: 0,
            pixel_height: 0,
        })?;

        let argv = opts.command.clone().unwrap_or_else(|| {
            vec![std::env::var("SHELL").unwrap_or_else(|_| "/bin/sh".into())]
        });
        let mut cmd = CommandBuilder::new(&argv[0]);
        cmd.args(&argv[1..]);
        cmd.env("TERM", &opts.term);
        for (k, v) in &opts.extra_env {
            cmd.env(k, v);
        }
        if let Some(cwd) = opts.cwd.as_deref() {
            cmd.cwd(cwd);
        } else if let Ok(home) = std::env::var("HOME") {
            cmd.cwd(home);
        }

        let mut child = pty.slave.spawn_command(cmd)?;
        drop(pty.slave);
        let killer = child.clone_killer();
        let mut reader = pty.master.try_clone_reader()?;
        let writer = pty.master.take_writer()?;

        // Query responses generated while parsing pty output are queued
        // here and flushed to the pty after each vt_write (the callback
        // runs under the terminal lock; writing to the pty from inside it
        // is fine, but keeping it queued makes the locking obvious).
        let pending_responses: Arc<Mutex<Vec<u8>>> = Arc::new(Mutex::new(Vec::new()));
        let title_changed = Arc::new(AtomicBool::new(false));

        let callbacks = Callbacks {
            on_pty_write: Some(Box::new({
                let pending = pending_responses.clone();
                move |bytes| pending.lock().unwrap().extend_from_slice(bytes)
            })),
            on_title_changed: Some(Box::new({
                let flag = title_changed.clone();
                move || flag.store(true, Ordering::Relaxed)
            })),
            on_bell: Some(Box::new({
                let mux = mux.clone();
                move || {
                    if let Some(mux) = mux.upgrade() {
                        mux.emit(MuxEvent::Bell(id));
                    }
                }
            })),
        };

        let term = Terminal::new(opts.cols, opts.rows, opts.scrollback, callbacks)?;
        let pane = Arc::new(Pane {
            id,
            term: Mutex::new(term),
            writer: Mutex::new(writer),
            master: Mutex::new(pty.master),
            killer: Mutex::new(killer),
            dead: AtomicBool::new(false),
            dirty: AtomicBool::new(false),
            title: Mutex::new(String::new()),
            pwd: Mutex::new(None),
            size: Mutex::new((opts.cols, opts.rows)),
        });

        // PTY reader: pty bytes → terminal state → PaneOutput events.
        std::thread::Builder::new()
            .name(format!("pane-{id}-reader"))
            .spawn({
                let pane = pane.clone();
                let mux = mux.clone();
                move || {
                    let mut buf = [0u8; 64 * 1024];
                    loop {
                        let n = match reader.read(&mut buf) {
                            Ok(0) | Err(_) => break,
                            Ok(n) => n,
                        };
                        {
                            let mut term = pane.term.lock().unwrap();
                            term.vt_write(&buf[..n]);
                            if title_changed.swap(false, Ordering::Relaxed) {
                                let title = term.title().unwrap_or_default();
                                *pane.title.lock().unwrap() = title;
                                if let Some(mux) = mux.upgrade() {
                                    mux.emit(MuxEvent::TitleChanged(pane.id));
                                }
                            }
                            if let Some(pwd) = term.pwd() {
                                *pane.pwd.lock().unwrap() = Some(pwd);
                            }
                        }
                        let responses = std::mem::take(&mut *pending_responses.lock().unwrap());
                        if !responses.is_empty() {
                            let _ = pane.write_bytes(&responses);
                        }
                        if !pane.dirty.swap(true, Ordering::AcqRel) {
                            if let Some(mux) = mux.upgrade() {
                                mux.emit(MuxEvent::PaneOutput(pane.id));
                            }
                        }
                    }
                    pane.dead.store(true, Ordering::Release);
                    if let Some(mux) = mux.upgrade() {
                        mux.pane_exited(pane.id);
                    }
                }
            })?;

        // Child reaper: avoid zombies; the reader thread handles EOF.
        std::thread::Builder::new()
            .name(format!("pane-{id}-wait"))
            .spawn(move || {
                let _ = child.wait();
            })?;

        Ok(pane)
    }

    /// Write input bytes to the child.
    pub fn write_bytes(&self, bytes: &[u8]) -> std::io::Result<()> {
        let mut writer = self.writer.lock().unwrap();
        writer.write_all(bytes)?;
        writer.flush()
    }

    /// Run `f` with exclusive access to the terminal state.
    pub fn with_terminal<R>(&self, f: impl FnOnce(&mut Terminal) -> R) -> R {
        f(&mut self.term.lock().unwrap())
    }

    /// Snapshot the terminal into `rs` (holds the terminal lock only for
    /// the duration of the update).
    pub fn snapshot(&self, rs: &mut RenderState) -> ghostty_vt::Result<()> {
        rs.update(&mut self.term.lock().unwrap())
    }

    /// Resize both the PTY and the terminal state.
    pub fn resize(&self, cols: u16, rows: u16) {
        let (cols, rows) = (cols.max(1), rows.max(1));
        {
            let mut size = self.size.lock().unwrap();
            if *size == (cols, rows) {
                return;
            }
            *size = (cols, rows);
        }
        let _ = self.master.lock().unwrap().resize(PtySize {
            rows,
            cols,
            pixel_width: 0,
            pixel_height: 0,
        });
        // Nominal cell metrics; only pixel size reports observe these.
        let _ = self.term.lock().unwrap().resize(cols, rows, 8, 16);
    }

    pub fn size(&self) -> (u16, u16) {
        *self.size.lock().unwrap()
    }

    pub fn title(&self) -> String {
        self.title.lock().unwrap().clone()
    }

    pub fn pwd(&self) -> Option<String> {
        self.pwd.lock().unwrap().clone()
    }

    pub fn is_dead(&self) -> bool {
        self.dead.load(Ordering::Acquire)
    }

    /// Clear the coalesced output flag; returns whether output was pending.
    pub fn take_dirty(&self) -> bool {
        self.dirty.swap(false, Ordering::AcqRel)
    }

    pub fn kill(&self) {
        let _ = self.killer.lock().unwrap().kill();
    }
}
