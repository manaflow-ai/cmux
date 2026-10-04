//! One writer per chat (section 2): the process listens on a Unix socket
//! named `lock` in the chat directory for its whole life. A second process
//! that can connect knows the chat is taken. A socket that refuses
//! connections is stale (the OS closes it when its owner dies): it is
//! deleted and taken over. No PID files, no timeouts.

use std::fs;
use std::io;
use std::os::unix::fs::MetadataExt;
use std::os::unix::net::{UnixListener, UnixStream};
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, AtomicU64, Ordering};
use std::sync::Arc;
use std::thread::{self, JoinHandle};

/// Why the lock was not taken.
#[derive(Debug)]
pub enum LockError {
    /// Another live process (or another `OptChat` in this one) holds the chat.
    Held,
    Io(io::Error),
}

/// The held lock. Dropping it closes the socket; the file is left for the
/// next owner to find stale and take over, because unlinking it here could
/// race with a newcomer that already took it.
pub struct ChatLock {
    path: PathBuf,
    stop: Arc<AtomicBool>,
    acceptor: Option<JoinHandle<()>>,
}

static ASIDE: AtomicU64 = AtomicU64::new(0);

impl ChatLock {
    pub fn acquire(dir: &Path) -> Result<ChatLock, LockError> {
        let path = dir.join("lock");
        loop {
            // bind creates the socket file and fails if the path exists, so
            // it is the exclusive create.
            match UnixListener::bind(&path) {
                Ok(listener) => return Ok(ChatLock::hold(path, listener)),
                Err(e) if e.kind() == io::ErrorKind::AddrInUse => {}
                Err(e) => return Err(LockError::Io(e)),
            }
            let ino = match fs::symlink_metadata(&path) {
                Ok(m) => m.ino(),
                Err(e) if e.kind() == io::ErrorKind::NotFound => continue,
                Err(e) => return Err(LockError::Io(e)),
            };
            match UnixStream::connect(&path) {
                Ok(_) => return Err(LockError::Held),
                Err(e) if e.kind() == io::ErrorKind::ConnectionRefused => {}
                Err(e) if e.kind() == io::ErrorKind::NotFound => continue,
                Err(e) => return Err(LockError::Io(e)),
            }
            // Stale. Two processes can find the same stale socket; deleting it
            // by name could delete the one the other just bound. Renaming is
            // atomic, so each inode is moved aside by exactly one of them, and
            // the mover checks it moved the stale inode it probed.
            let aside = dir.join(format!(
                "lock.stale.{}.{}",
                std::process::id(),
                ASIDE.fetch_add(1, Ordering::Relaxed)
            ));
            match fs::rename(&path, &aside) {
                Ok(()) => {}
                Err(e) if e.kind() == io::ErrorKind::NotFound => continue,
                Err(e) => return Err(LockError::Io(e)),
            }
            let moved = fs::symlink_metadata(&aside).map(|m| m.ino()).ok();
            if moved != Some(ino) {
                // We moved a live lock that another process took in between:
                // put it back (hard_link fails rather than overwrite), then retry.
                let _ = fs::hard_link(&aside, &path);
            }
            let _ = fs::remove_file(&aside);
        }
    }

    fn hold(path: PathBuf, listener: UnixListener) -> ChatLock {
        let stop = Arc::new(AtomicBool::new(false));
        let flag = stop.clone();
        // Accept and drop every probe: unaccepted connections fill the listen
        // backlog, and a full backlog refuses connections, which would make a
        // live lock look stale.
        let acceptor = thread::Builder::new()
            .name("optchat-lock".into())
            .spawn(move || {
                for conn in listener.incoming() {
                    drop(conn);
                    if flag.load(Ordering::SeqCst) {
                        break;
                    }
                }
            })
            .ok();
        ChatLock {
            path,
            stop,
            acceptor,
        }
    }
}

impl Drop for ChatLock {
    fn drop(&mut self) {
        self.stop.store(true, Ordering::SeqCst);
        // Wake the acceptor so it closes the listener now; join only when the
        // wake reached it (otherwise our path is gone and nothing can).
        if UnixStream::connect(&self.path).is_ok() {
            if let Some(t) = self.acceptor.take() {
                let _ = t.join();
            }
        }
    }
}
