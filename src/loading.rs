use std::io::{self, IsTerminal, Write};
use std::sync::mpsc::{self, RecvTimeoutError, Sender};
use std::thread::{self, JoinHandle};
use std::time::Duration;

use crossterm::{cursor, execute, terminal};

const INITIAL_DELAY: Duration = Duration::from_millis(250);
const FRAME_DELAY: Duration = Duration::from_millis(80);
const FRAMES: &[char] = &['⠋', '⠙', '⠹', '⠸', '⠼', '⠴', '⠦', '⠧', '⠇', '⠏'];

pub struct DelayedSpinner {
    stop: Option<Sender<()>>,
    thread: Option<JoinHandle<()>>,
}

impl DelayedSpinner {
    pub fn new(message: &'static str) -> Self {
        if !io::stderr().is_terminal() {
            return Self {
                stop: None,
                thread: None,
            };
        }

        let (stop, stopped) = mpsc::channel();
        let thread = thread::spawn(move || {
            if !matches!(
                stopped.recv_timeout(INITIAL_DELAY),
                Err(RecvTimeoutError::Timeout)
            ) {
                return;
            }

            let mut stderr = io::stderr().lock();
            for frame in FRAMES.iter().cycle() {
                let _ = write!(stderr, "\r{frame} {message}…");
                let _ = stderr.flush();
                if !matches!(
                    stopped.recv_timeout(FRAME_DELAY),
                    Err(RecvTimeoutError::Timeout)
                ) {
                    break;
                }
            }
            let _ = execute!(
                stderr,
                cursor::MoveToColumn(0),
                terminal::Clear(terminal::ClearType::CurrentLine)
            );
            let _ = stderr.flush();
        });

        Self {
            stop: Some(stop),
            thread: Some(thread),
        }
    }

    pub fn finish(mut self) {
        self.stop.take();
        if let Some(thread) = self.thread.take() {
            let _ = thread.join();
        }
    }
}

impl Drop for DelayedSpinner {
    fn drop(&mut self) {
        self.stop.take();
        if let Some(thread) = self.thread.take() {
            let _ = thread.join();
        }
    }
}
