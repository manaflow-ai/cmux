//! An [`Overlay`] served as an NFSv3 file system (the `nfsserve` crate), for a Mac: macOS mounts
//! it from localhost with its own `mount_nfs`, so a projection there needs no kernel extension, no
//! app extension and no prompt, and a checkout writes no files to the Mac's disk until a path is
//! written (fseventsd journals every path a checkout writes, and keeps each name until reboot).
//!
//! Every call runs the overlay on tokio's blocking pool: the overlay reads git objects and the
//! upper folder with blocking file calls.

use std::ffi::OsStr;
use std::os::unix::ffi::OsStrExt;
use std::path::Path;
use std::sync::Arc;

use async_trait::async_trait;
use nfsserve::nfs::{
    fattr3, fileid3, filename3, ftype3, nfspath3, nfsstat3, nfsstring, nfstime3, sattr3, set_atime,
    set_gid3, set_mode3, set_mtime, set_size3, set_uid3, specdata3,
};
use nfsserve::vfs::{DirEntry, NFSFileSystem, ReadDirResult, VFSCapabilities};

use crate::overlay::{Attr, Overlay, Set, Type, Who};
use crate::upper::SetTime;

/// The file system id every attribute names (one export per server).
const FSID: u64 = 0x636d_7578;

/// What a file the client creates without a mode gets.
const FILE_MODE: u32 = 0o644;
/// What a folder gets: NFSv3 MKDIR's attributes do not reach [`NFSFileSystem::mkdir`].
const DIR_MODE: u32 = 0o755;

/// The NFS face of one overlay. New paths are owned by `who`, the user the server runs as (the
/// client's credentials do not reach the file system trait; the mount is that user's own).
pub struct Nfs {
    overlay: Arc<Overlay>,
    who: Who,
}

impl Nfs {
    #[must_use]
    pub fn new(overlay: Arc<Overlay>, who: Who) -> Self {
        Self { overlay, who }
    }

    async fn run<T: Send + 'static>(
        &self,
        call: impl FnOnce(&Overlay) -> Result<T, i32> + Send + 'static,
    ) -> Result<T, nfsstat3> {
        let overlay = Arc::clone(&self.overlay);
        match tokio::task::spawn_blocking(move || call(&overlay)).await {
            Ok(result) => result.map_err(status),
            Err(_) => Err(nfsstat3::NFS3ERR_SERVERFAULT),
        }
    }
}

/// The NFS status an overlay `errno` answers with.
#[must_use]
pub fn status(errno: i32) -> nfsstat3 {
    match errno {
        libc::EPERM => nfsstat3::NFS3ERR_PERM,
        libc::ENOENT => nfsstat3::NFS3ERR_NOENT,
        libc::EACCES => nfsstat3::NFS3ERR_ACCES,
        libc::EEXIST => nfsstat3::NFS3ERR_EXIST,
        libc::EXDEV => nfsstat3::NFS3ERR_XDEV,
        libc::ENOTDIR => nfsstat3::NFS3ERR_NOTDIR,
        libc::EISDIR => nfsstat3::NFS3ERR_ISDIR,
        libc::EINVAL => nfsstat3::NFS3ERR_INVAL,
        libc::EFBIG => nfsstat3::NFS3ERR_FBIG,
        libc::ENOSPC => nfsstat3::NFS3ERR_NOSPC,
        libc::EROFS => nfsstat3::NFS3ERR_ROFS,
        libc::EMLINK => nfsstat3::NFS3ERR_MLINK,
        libc::ENAMETOOLONG => nfsstat3::NFS3ERR_NAMETOOLONG,
        libc::ENOTEMPTY => nfsstat3::NFS3ERR_NOTEMPTY,
        libc::EDQUOT => nfsstat3::NFS3ERR_DQUOT,
        libc::ESTALE | libc::EBADF => nfsstat3::NFS3ERR_STALE,
        libc::ENOTSUP | libc::ENOSYS => nfsstat3::NFS3ERR_NOTSUPP,
        _ => nfsstat3::NFS3ERR_IO,
    }
}

fn time(ns: i64) -> nfstime3 {
    let seconds = ns.div_euclid(1_000_000_000);
    let nseconds = ns.rem_euclid(1_000_000_000);
    nfstime3 {
        seconds: u32::try_from(seconds).unwrap_or(if seconds < 0 { 0 } else { u32::MAX }),
        nseconds: u32::try_from(nseconds).unwrap_or(0),
    }
}

fn time_ns(time: nfstime3) -> i64 {
    i64::from(time.seconds) * 1_000_000_000 + i64::from(time.nseconds)
}

/// The NFS attributes of `attr`.
#[must_use]
pub fn fattr(attr: &Attr) -> fattr3 {
    let ftype = match attr.kind {
        Type::File => ftype3::NF3REG,
        Type::Dir => ftype3::NF3DIR,
        Type::Link => ftype3::NF3LNK,
        Type::Fifo => ftype3::NF3FIFO,
        Type::Socket => ftype3::NF3SOCK,
        Type::Char => ftype3::NF3CHR,
        Type::Block => ftype3::NF3BLK,
    };
    fattr3 {
        ftype,
        mode: attr.mode,
        nlink: attr.nlink,
        uid: attr.uid,
        gid: attr.gid,
        size: attr.size,
        used: attr.blocks.saturating_mul(512),
        rdev: specdata3 {
            specdata1: u32::try_from(attr.rdev >> 32).unwrap_or(0),
            specdata2: u32::try_from(attr.rdev & 0xffff_ffff).unwrap_or(0),
        },
        fsid: FSID,
        fileid: attr.ino,
        atime: time(attr.atime_ns),
        mtime: time(attr.mtime_ns),
        ctime: time(attr.ctime_ns),
    }
}

/// The overlay change an NFS `sattr3` asks for.
#[must_use]
pub fn set_of(attr: &sattr3) -> Set {
    Set {
        size: match attr.size {
            set_size3::size(size) => Some(size),
            set_size3::Void => None,
        },
        mode: match attr.mode {
            set_mode3::mode(mode) => Some(mode & 0o7777),
            set_mode3::Void => None,
        },
        uid: match attr.uid {
            set_uid3::uid(uid) => Some(uid),
            set_uid3::Void => None,
        },
        gid: match attr.gid {
            set_gid3::gid(gid) => Some(gid),
            set_gid3::Void => None,
        },
        atime: match attr.atime {
            set_atime::DONT_CHANGE => None,
            set_atime::SET_TO_SERVER_TIME => Some(SetTime::Now),
            set_atime::SET_TO_CLIENT_TIME(at) => Some(SetTime::At(time_ns(at))),
        },
        mtime: match attr.mtime {
            set_mtime::DONT_CHANGE => None,
            set_mtime::SET_TO_SERVER_TIME => Some(SetTime::Now),
            set_mtime::SET_TO_CLIENT_TIME(at) => Some(SetTime::At(time_ns(at))),
        },
    }
}

/// A name off the wire as the overlay's `&str` (a name that is not UTF-8 is never in a git
/// tree's manifest, and the upper folder takes only what the overlay can name).
fn name_of(name: &filename3) -> Result<String, nfsstat3> {
    String::from_utf8(name.0.clone()).map_err(|_| nfsstat3::NFS3ERR_INVAL)
}

/// Which of a folder's `entries` (overlay listing order) come after the entry numbered
/// `start_after` (0: from the start), at most `max` of them, and whether that reaches the end. A
/// cookie no longer in the folder is the client's to restart from.
pub fn page<T>(
    entries: &[(u64, T, String)],
    start_after: u64,
    max: usize,
) -> Result<(std::ops::Range<usize>, bool), nfsstat3> {
    let from = if start_after == 0 {
        0
    } else {
        entries
            .iter()
            .position(|(ino, _, _)| *ino == start_after)
            .map(|at| at + 1)
            .ok_or(nfsstat3::NFS3ERR_BAD_COOKIE)?
    };
    let to = from.saturating_add(max).min(entries.len());
    Ok((from..to, to == entries.len()))
}

#[async_trait]
impl NFSFileSystem for Nfs {
    fn capabilities(&self) -> VFSCapabilities {
        VFSCapabilities::ReadWrite
    }

    fn root_dir(&self) -> fileid3 {
        self.overlay.root()
    }

    async fn lookup(&self, dirid: fileid3, filename: &filename3) -> Result<fileid3, nfsstat3> {
        match filename.0.as_slice() {
            b"." => return Ok(dirid),
            b".." => return self.run(move |overlay| overlay.parent(dirid)).await,
            _ => {}
        }
        let name = name_of(filename)?;
        self.run(move |overlay| overlay.lookup(dirid, &name).map(|attr| attr.ino)).await
    }

    async fn getattr(&self, id: fileid3) -> Result<fattr3, nfsstat3> {
        self.run(move |overlay| overlay.getattr(id)).await.map(|attr| fattr(&attr))
    }

    async fn setattr(&self, id: fileid3, setattr: sattr3) -> Result<fattr3, nfsstat3> {
        let set = set_of(&setattr);
        self.run(move |overlay| overlay.setattr(id, None, set)).await.map(|attr| fattr(&attr))
    }

    async fn read(
        &self,
        id: fileid3,
        offset: u64,
        count: u32,
    ) -> Result<(Vec<u8>, bool), nfsstat3> {
        self.run(move |overlay| {
            let size = overlay.getattr(id)?.size;
            if offset >= size {
                return Ok((Vec::new(), true));
            }
            let bytes = overlay.read(id, offset, count)?;
            let end = offset.saturating_add(bytes.len() as u64) >= size;
            Ok((bytes, end))
        })
        .await
    }

    async fn write(&self, id: fileid3, offset: u64, data: &[u8]) -> Result<fattr3, nfsstat3> {
        let data = data.to_vec();
        self.run(move |overlay| {
            overlay.write(id, offset, &data)?;
            overlay.getattr(id)
        })
        .await
        .map(|attr| fattr(&attr))
    }

    async fn create(
        &self,
        dirid: fileid3,
        filename: &filename3,
        attr: sattr3,
    ) -> Result<(fileid3, fattr3), nfsstat3> {
        let name = name_of(filename)?;
        let who = self.who;
        let mut set = set_of(&attr);
        let mode = set.mode.take().unwrap_or(FILE_MODE);
        self.run(move |overlay| {
            let (made, handle) = overlay.create(dirid, &name, mode, who)?;
            overlay.release(handle);
            // A new file is empty and owned by its maker already.
            if set.size == Some(0) {
                set.size = None;
            }
            set.uid = None;
            set.gid = None;
            let made =
                if set == Set::default() { made } else { overlay.setattr(made.ino, None, set)? };
            Ok((made.ino, fattr(&made)))
        })
        .await
    }

    async fn create_exclusive(
        &self,
        dirid: fileid3,
        filename: &filename3,
    ) -> Result<fileid3, nfsstat3> {
        let name = name_of(filename)?;
        let who = self.who;
        self.run(move |overlay| {
            let (made, handle) = overlay.create(dirid, &name, FILE_MODE, who)?;
            overlay.release(handle);
            Ok(made.ino)
        })
        .await
    }

    async fn mkdir(
        &self,
        dirid: fileid3,
        dirname: &filename3,
    ) -> Result<(fileid3, fattr3), nfsstat3> {
        let name = name_of(dirname)?;
        let who = self.who;
        self.run(move |overlay| overlay.mkdir(dirid, &name, DIR_MODE, who))
            .await
            .map(|attr| (attr.ino, fattr(&attr)))
    }

    /// NFS REMOVE and RMDIR both land here: the path's own type picks which.
    async fn remove(&self, dirid: fileid3, filename: &filename3) -> Result<(), nfsstat3> {
        let name = name_of(filename)?;
        self.run(move |overlay| {
            if overlay.lookup(dirid, &name)?.kind == Type::Dir {
                overlay.rmdir(dirid, &name)
            } else {
                overlay.unlink(dirid, &name)
            }
        })
        .await
    }

    async fn rename(
        &self,
        from_dirid: fileid3,
        from_filename: &filename3,
        to_dirid: fileid3,
        to_filename: &filename3,
    ) -> Result<(), nfsstat3> {
        let from = name_of(from_filename)?;
        let to = name_of(to_filename)?;
        self.run(move |overlay| overlay.rename(from_dirid, &from, to_dirid, &to, 0)).await
    }

    async fn readdir(
        &self,
        dirid: fileid3,
        start_after: fileid3,
        max_entries: usize,
    ) -> Result<ReadDirResult, nfsstat3> {
        let listed = self
            .run(move |overlay| {
                let all = overlay.readdir(dirid)?;
                let Ok((range, end)) = page(&all, start_after, max_entries) else {
                    return Ok(None);
                };
                let Some(window) = all.get(range) else {
                    return Ok(None);
                };
                let entries = window
                    .iter()
                    // A path deleted since the listing is left out.
                    .filter_map(|(ino, _, name)| {
                        let attr = overlay.getattr(*ino).ok()?;
                        Some(DirEntry {
                            fileid: *ino,
                            name: nfsstring(name.clone().into_bytes()),
                            attr: fattr(&attr),
                        })
                    })
                    .collect();
                Ok(Some(ReadDirResult { entries, end }))
            })
            .await?;
        listed.ok_or(nfsstat3::NFS3ERR_BAD_COOKIE)
    }

    async fn symlink(
        &self,
        dirid: fileid3,
        linkname: &filename3,
        symlink: &nfspath3,
        _attr: &sattr3,
    ) -> Result<(fileid3, fattr3), nfsstat3> {
        let name = name_of(linkname)?;
        let target = symlink.0.clone();
        let who = self.who;
        self.run(move |overlay| {
            overlay.symlink(dirid, &name, Path::new(OsStr::from_bytes(&target)), who)
        })
        .await
        .map(|attr| (attr.ino, fattr(&attr)))
    }

    async fn readlink(&self, id: fileid3) -> Result<nfspath3, nfsstat3> {
        self.run(move |overlay| overlay.readlink(id)).await.map(nfsstring)
    }
}

/// The `mount_nfs` options for a server on localhost `port`. The client keeps its own caches
/// (nothing else writes the export); `nobrowse` keeps the mount out of Finder and Spotlight;
/// `soft` and `deadtimeout` let a mount whose server died fail its calls, not hang them.
/// `CMUX_PROJECTION_NFS_OPTS` adds options after these (a later option wins).
#[must_use]
pub fn mount_options(port: u16) -> String {
    let mut options = format!(
        "vers=3,tcp,noresvport,port={port},mountport={port},locallocks,rsize=1048576,wsize=1048576,\
         readahead=16,nobrowse,soft,intr,timeo=10,retrans=3,deadtimeout=30"
    );
    if let Ok(extra) = std::env::var("CMUX_PROJECTION_NFS_OPTS")
        && !extra.is_empty()
    {
        options.push(',');
        options.push_str(&extra);
    }
    options
}

/// Whether `at` is a mount point itself (its own file system, not its parent's).
#[cfg(target_os = "macos")]
#[must_use]
pub fn is_mount_point(at: &Path) -> bool {
    let (Ok(path), Some(parent)) = (std::fs::metadata(at), at.parent()) else { return false };
    let Ok(parent) = std::fs::metadata(parent) else { return false };
    std::os::unix::fs::MetadataExt::dev(&path) != std::os::unix::fs::MetadataExt::dev(&parent)
}

/// Unmounts what an earlier server left mounted at `at` (its server gone, the mount dead).
#[cfg(target_os = "macos")]
pub fn unmount_stale(at: &Path) {
    if is_mount_point(at) {
        let _ = std::process::Command::new("/sbin/umount").arg("-f").arg(at).status();
    }
}

/// Serves `overlay` on a localhost port, mounts it at `at` with `mount_nfs`, calls `on_ready`
/// once the mount is up, and serves until the mount is gone (an unmount of `at` from anywhere) or
/// the process is asked to stop (SIGTERM, SIGINT: it unmounts `at` itself; a mount still busy
/// stays served, never pulled from under its writers).
#[cfg(target_os = "macos")]
pub fn serve(overlay: Arc<Overlay>, at: &Path, on_ready: impl FnOnce()) -> anyhow::Result<()> {
    use nfsserve::tcp::{NFSTcp, NFSTcpListener};
    use tokio::signal::unix::{SignalKind, signal};

    let runtime = tokio::runtime::Builder::new_multi_thread().enable_all().build()?;
    runtime.block_on(async move {
        // SAFETY: geteuid and getegid cannot fail.
        let who = unsafe { Who { uid: libc::geteuid(), gid: libc::getegid() } };
        let mut listener = NFSTcpListener::bind("127.0.0.1:0", Nfs::new(overlay, who)).await?;
        let port = listener.get_listen_port();
        let (mounts, mut mounted) = tokio::sync::mpsc::channel(16);
        listener.set_mount_listener(mounts);
        // Served on this task, polled beside every wait below (mount_nfs and umount need it
        // answering); it ends when this function returns.
        let serving = listener.handle_forever();
        tokio::pin!(serving);
        let stopped = |result: std::io::Result<()>| match result {
            Ok(()) => anyhow::anyhow!("the NFS server stopped"),
            Err(error) => anyhow::anyhow!("the NFS server failed: {error}"),
        };

        let options = mount_options(port);
        let mount = tokio::process::Command::new("/sbin/mount_nfs")
            .arg("-o")
            .arg(&options)
            .arg("localhost:/")
            .arg(at)
            .status();
        let status = tokio::select! {
            status = mount => status?,
            result = &mut serving => return Err(stopped(result)),
        };
        anyhow::ensure!(
            status.success(),
            "mount_nfs -o {options} localhost:/ {} failed",
            at.display()
        );
        on_ready();

        let mut term = signal(SignalKind::terminate())?;
        let mut int = signal(SignalKind::interrupt())?;
        loop {
            let stop = tokio::select! {
                signal = mounted.recv() => match signal {
                    // An unmount's UMNT: done once `at` is no mount any more.
                    Some(false) => !is_mount_point(at),
                    Some(true) => false,
                    None => true,
                },
                _ = term.recv() => true,
                _ = int.recv() => true,
                result = &mut serving => return Err(stopped(result)),
            };
            if !stop {
                continue;
            }
            if !is_mount_point(at) {
                break;
            }
            let unmount = tokio::process::Command::new("/sbin/umount").arg(at).status();
            let unmounted = tokio::select! {
                status = unmount => status?,
                result = &mut serving => return Err(stopped(result)),
            };
            if unmounted.success() {
                break;
            }
            eprintln!("cmux-projection: {} is busy; still serving it", at.display());
        }
        Ok(())
    })
}

#[cfg(test)]
#[path = "nfs_tests.rs"]
mod tests;
