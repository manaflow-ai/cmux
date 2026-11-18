//! The read-only FUSE filesystem over [`Core`]: the overlay's lower layer on the Cloud machine.
//!
//! Metadata comes from the manifest, so `stat`, `readdir` and `readlink` never wait on the Mac.
//! Reads go through [`Core::read`]; a read the cache can answer is answered on the session's own
//! thread, any other on a thread of its own so a fault never holds up other requests. Inode
//! numbers are manifest indexes plus one, inside this process only. When the core reports a
//! changed or gone entry, a separate thread tells the kernel to drop that inode's cached
//! attributes and pages (and a gone entry's name), so a fault in progress is never blocked by its
//! own invalidation.

mod fs;

use std::ffi::OsStr;
use std::io;
use std::path::Path;
use std::sync::mpsc;
use std::sync::{Arc, Condvar, Mutex, PoisonError};
use std::time::{Duration, Instant};

use fuser::{BackgroundSession, Config, MountOption, Notifier, SessionACL};

use crate::core::Core;
use crate::manifest::Index;

/// How to mount the projection.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct MountConfig {
    /// The filesystem's name in the mount table.
    pub fsname: String,
    /// The owner every entry reports (normally the mounting user).
    pub uid: u32,
    pub gid: u32,
    /// Let other users read the mount (needed when root mounts the overlay over it). Needs
    /// `user_allow_other` in `/etc/fuse.conf` when the mounting user is not root.
    pub allow_other: bool,
    /// How long the kernel may keep attributes and names without asking again.
    pub ttl: Duration,
    /// Threads reading requests from the kernel.
    pub threads: usize,
}

impl MountConfig {
    /// The defaults: named `cmux-projfs`, readable by other users, one-hour attribute lifetime
    /// (changes are pushed to the kernel instead of polled), four request threads.
    pub fn new(uid: u32, gid: u32) -> MountConfig {
        MountConfig {
            fsname: "cmux-projfs".into(),
            uid,
            gid,
            allow_other: true,
            ttl: Duration::from_secs(3600),
            threads: 4,
        }
    }
}

#[derive(Default)]
struct Sent {
    count: Mutex<u64>,
    changed: Condvar,
}

/// A mounted projection. Dropping it unmounts too, but [`Mounted::unmount`] reports errors.
pub struct Mounted {
    session: Option<BackgroundSession>,
    core: Arc<Core>,
    sent: Arc<Sent>,
}

/// Mounts `core` read-only at `mountpoint` through `fusermount3`.
pub fn mount(core: Arc<Core>, mountpoint: &Path, config: &MountConfig) -> io::Result<Mounted> {
    let mut options = Config::default();
    options.mount_options = vec![
        MountOption::RO,
        MountOption::FSName(config.fsname.clone()),
        MountOption::Subtype("cmux-projfs".into()),
        MountOption::DefaultPermissions,
        MountOption::NoDev,
        MountOption::NoSuid,
    ];
    options.acl = if config.allow_other { SessionACL::All } else { SessionACL::Owner };
    options.n_threads = Some(config.threads.max(1));
    let filesystem = fs::ProjFs::new(core.clone(), config);
    let session = fuser::spawn_mount(filesystem, mountpoint, &options)?;
    let sent = Arc::new(Sent::default());
    let (tx, rx) = mpsc::channel::<Index>();
    let notifier = session.notifier();
    let (thread_core, thread_sent) = (core.clone(), sent.clone());
    std::thread::Builder::new()
        .name("projfs-invalidate".into())
        .spawn(move || invalidate_loop(&thread_core, &notifier, &rx, &thread_sent))?;
    core.set_invalidate(Some(Arc::new(move |idx| {
        let _ = tx.send(idx);
    })));
    Ok(Mounted { session: Some(session), core, sent })
}

/// Sends the kernel one invalidation per changed entry until the mount goes away.
fn invalidate_loop(core: &Core, notifier: &Notifier, rx: &mpsc::Receiver<Index>, sent: &Sent) {
    for idx in rx {
        let gone_name = {
            let m = core.manifest();
            m.entry(idx).filter(|e| e.gone).map(|e| (e.parent, e.name.clone()))
        };
        if let Some((parent, name)) = gone_name {
            let _ = notifier.inval_entry(fs::ino(parent), OsStr::new(&name));
        }
        let _ = notifier.inval_inode(fs::ino(idx), 0, 0);
        *sent.count.lock().unwrap_or_else(PoisonError::into_inner) += 1;
        sent.changed.notify_all();
    }
}

impl Mounted {
    /// How many invalidations have been sent to the kernel.
    pub fn invalidations_sent(&self) -> u64 {
        *self.sent.count.lock().unwrap_or_else(PoisonError::into_inner)
    }

    /// Waits until at least `n` invalidations have been sent, or `timeout` passes. Returns
    /// whether they were.
    pub fn wait_invalidations(&self, n: u64, timeout: Duration) -> bool {
        let deadline = Instant::now() + timeout;
        let mut count = self.sent.count.lock().unwrap_or_else(PoisonError::into_inner);
        while *count < n {
            let now = Instant::now();
            if now >= deadline {
                return false;
            }
            count = self
                .sent
                .changed
                .wait_timeout(count, deadline - now)
                .unwrap_or_else(PoisonError::into_inner)
                .0;
        }
        true
    }

    /// Unmounts and waits for the session to end.
    pub fn unmount(mut self) -> io::Result<()> {
        self.core.set_invalidate(None);
        match self.session.take() {
            Some(session) => session.umount_and_join(),
            None => Ok(()),
        }
    }
}

impl Drop for Mounted {
    fn drop(&mut self) {
        // Dropping the sender ends the invalidation thread; dropping the session unmounts.
        self.core.set_invalidate(None);
    }
}
