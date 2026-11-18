//! The `fuser::Filesystem` implementation.

use std::ffi::OsStr;
use std::path::Path;
use std::sync::Arc;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use fuser::{
    Errno, FileAttr, FileHandle, FileType, Filesystem, FopenFlags, Generation, INodeNo, LockOwner,
    OpenAccMode, OpenFlags, RenameFlags, ReplyAttr, ReplyCreate, ReplyData, ReplyDirectory,
    ReplyDirectoryPlus, ReplyEmpty, ReplyEntry, ReplyOpen, ReplyWrite, Request, TimeOrNow,
    WriteFlags,
};

use super::MountConfig;
use crate::core::Core;
use crate::manifest::{Entry, Index, Kind, ROOT};

/// The inode number of a manifest index.
pub(super) fn ino(idx: Index) -> INodeNo {
    INodeNo(u64::from(idx) + 1)
}

/// The manifest index of an inode number, if it can be one.
fn index(ino: INodeNo) -> Option<Index> {
    ino.0.checked_sub(1).and_then(|i| Index::try_from(i).ok())
}

fn time(ns: i64) -> SystemTime {
    if ns >= 0 {
        UNIX_EPOCH + Duration::from_nanos(ns as u64)
    } else {
        UNIX_EPOCH - Duration::from_nanos(ns.unsigned_abs())
    }
}

fn file_type(kind: Kind) -> FileType {
    match kind {
        Kind::File => FileType::RegularFile,
        Kind::Dir => FileType::Directory,
        Kind::Symlink => FileType::Symlink,
    }
}

pub(super) struct ProjFs {
    core: Arc<Core>,
    uid: u32,
    gid: u32,
    ttl: Duration,
}

impl ProjFs {
    pub(super) fn new(core: Arc<Core>, config: &MountConfig) -> ProjFs {
        ProjFs { core, uid: config.uid, gid: config.gid, ttl: config.ttl }
    }

    fn attr(&self, idx: Index, e: &Entry) -> FileAttr {
        let s = &e.stat;
        let size = match s.kind {
            Kind::Dir => 4096,
            Kind::Symlink => s.link.as_ref().map_or(0, |l| l.len() as u64),
            Kind::File => s.size,
        };
        FileAttr {
            ino: ino(idx),
            size,
            blocks: size.div_ceil(512),
            atime: time(s.mtime_ns),
            mtime: time(s.mtime_ns),
            ctime: time(s.ctime_ns),
            crtime: time(s.mtime_ns),
            kind: file_type(s.kind),
            perm: (s.mode & 0o7777) as u16,
            nlink: if s.kind == Kind::Dir { 2 } else { 1 },
            uid: self.uid,
            gid: self.gid,
            rdev: 0,
            blksize: 4096,
            flags: 0,
        }
    }

    /// The live entry behind an inode, with its attributes.
    fn live(&self, ino: INodeNo) -> Result<(Index, Entry), Errno> {
        let idx = index(ino).ok_or(Errno::ENOENT)?;
        let m = self.core.manifest();
        match m.entry(idx) {
            Some(e) if !e.gone => Ok((idx, e.clone())),
            _ => Err(Errno::ENOENT),
        }
    }

    /// The directory listing from `offset` on: offsets are 1 for `.`, 2 for `..`, then 3 plus
    /// the child's position, so they stay stable when children go away.
    fn listing(&self, ino: INodeNo, offset: u64) -> Result<Vec<(u64, Index, Entry)>, Errno> {
        let (idx, dir) = self.live(ino)?;
        if dir.stat.kind != Kind::Dir {
            return Err(Errno::ENOTDIR);
        }
        let m = self.core.manifest();
        let parent = if idx == ROOT { ROOT } else { dir.parent };
        let mut out = Vec::new();
        for (off, i) in [(1, idx), (2, parent)] {
            if off > offset
                && let Some(e) = m.entry(i)
            {
                out.push((off, i, e.clone()));
            }
        }
        for (pos, i) in dir.children().enumerate() {
            let off = 3 + pos as u64;
            match m.entry(i) {
                Some(e) if off > offset && !e.gone => out.push((off, i, e.clone())),
                _ => {}
            }
        }
        Ok(out)
    }
}

fn dot_name(off: u64, e: &Entry) -> &str {
    match off {
        1 => ".",
        2 => "..",
        _ => &e.name,
    }
}

impl Filesystem for ProjFs {
    fn lookup(&self, _req: &Request, parent: INodeNo, name: &OsStr, reply: ReplyEntry) {
        let (Some(parent), Some(name)) = (index(parent), name.to_str()) else {
            return reply.error(Errno::ENOENT);
        };
        let m = self.core.manifest();
        match m.lookup(parent, name).and_then(|i| m.entry(i).map(|e| (i, e))) {
            Some((i, e)) => reply.entry(&self.ttl, &self.attr(i, e), Generation(0)),
            None => reply.error(Errno::ENOENT),
        }
    }

    fn getattr(&self, _req: &Request, ino: INodeNo, _fh: Option<FileHandle>, reply: ReplyAttr) {
        match self.live(ino) {
            Ok((idx, e)) => reply.attr(&self.ttl, &self.attr(idx, &e)),
            Err(e) => reply.error(e),
        }
    }

    fn readlink(&self, _req: &Request, ino: INodeNo, reply: ReplyData) {
        match self.live(ino) {
            Ok((_, e)) => match &e.stat.link {
                Some(link) => reply.data(link.as_bytes()),
                None => reply.error(Errno::EINVAL),
            },
            Err(e) => reply.error(e),
        }
    }

    fn open(&self, _req: &Request, ino: INodeNo, flags: OpenFlags, reply: ReplyOpen) {
        if flags.acc_mode() != OpenAccMode::O_RDONLY {
            return reply.error(Errno::EROFS);
        }
        match self.live(ino) {
            Ok((_, e)) if e.stat.kind == Kind::Dir => reply.error(Errno::EISDIR),
            Ok((_, e)) if e.stat.withheld => reply.error(Errno::EACCES),
            Ok(_) => reply.opened(FileHandle(0), FopenFlags::FOPEN_KEEP_CACHE),
            Err(e) => reply.error(e),
        }
    }

    fn read(
        &self,
        _req: &Request,
        ino: INodeNo,
        _fh: FileHandle,
        offset: u64,
        size: u32,
        _flags: OpenFlags,
        _lock_owner: Option<LockOwner>,
        reply: ReplyData,
    ) {
        let Some(idx) = index(ino) else {
            return reply.error(Errno::ENOENT);
        };
        if let Some(bytes) = self.core.read_cached(idx, offset, size) {
            return reply.data(&bytes);
        }
        let core = self.core.clone();
        let answer = move || match core.read(idx, offset, size) {
            Ok(bytes) => reply.data(&bytes),
            Err(e) => reply.error(Errno::from_i32(e.errno())),
        };
        // A fault can wait seconds on the Mac; it gets its own thread so other requests go on.
        // The closure is moved into the thread, so the request is answered either way.
        if let Err(e) = std::thread::Builder::new().name("projfs-read".into()).spawn(answer) {
            // The closure (and with it the reply) is gone; fuser answers a dropped reply with EIO.
            drop(e);
        }
    }

    fn readdir(
        &self,
        _req: &Request,
        ino: INodeNo,
        _fh: FileHandle,
        offset: u64,
        mut reply: ReplyDirectory,
    ) {
        match self.listing(ino, offset) {
            Ok(list) => {
                for (off, i, e) in list {
                    if reply.add(self::ino(i), off, file_type(e.stat.kind), dot_name(off, &e)) {
                        break;
                    }
                }
                reply.ok();
            }
            Err(e) => reply.error(e),
        }
    }

    fn readdirplus(
        &self,
        _req: &Request,
        ino: INodeNo,
        _fh: FileHandle,
        offset: u64,
        mut reply: ReplyDirectoryPlus,
    ) {
        match self.listing(ino, offset) {
            Ok(list) => {
                for (off, i, e) in list {
                    let attr = self.attr(i, &e);
                    if reply.add(
                        self::ino(i),
                        off,
                        dot_name(off, &e),
                        &self.ttl,
                        &attr,
                        Generation(0),
                    ) {
                        break;
                    }
                }
                reply.ok();
            }
            Err(e) => reply.error(e),
        }
    }

    fn setattr(
        &self,
        _req: &Request,
        _ino: INodeNo,
        _mode: Option<u32>,
        _uid: Option<u32>,
        _gid: Option<u32>,
        _size: Option<u64>,
        _atime: Option<TimeOrNow>,
        _mtime: Option<TimeOrNow>,
        _ctime: Option<SystemTime>,
        _fh: Option<FileHandle>,
        _crtime: Option<SystemTime>,
        _chgtime: Option<SystemTime>,
        _bkuptime: Option<SystemTime>,
        _flags: Option<fuser::BsdFileFlags>,
        reply: ReplyAttr,
    ) {
        reply.error(Errno::EROFS);
    }

    fn mknod(
        &self,
        _req: &Request,
        _parent: INodeNo,
        _name: &OsStr,
        _mode: u32,
        _umask: u32,
        _rdev: u32,
        reply: ReplyEntry,
    ) {
        reply.error(Errno::EROFS);
    }

    fn mkdir(
        &self,
        _req: &Request,
        _parent: INodeNo,
        _name: &OsStr,
        _mode: u32,
        _umask: u32,
        reply: ReplyEntry,
    ) {
        reply.error(Errno::EROFS);
    }

    fn unlink(&self, _req: &Request, _parent: INodeNo, _name: &OsStr, reply: ReplyEmpty) {
        reply.error(Errno::EROFS);
    }

    fn rmdir(&self, _req: &Request, _parent: INodeNo, _name: &OsStr, reply: ReplyEmpty) {
        reply.error(Errno::EROFS);
    }

    fn symlink(
        &self,
        _req: &Request,
        _parent: INodeNo,
        _name: &OsStr,
        _target: &Path,
        reply: ReplyEntry,
    ) {
        reply.error(Errno::EROFS);
    }

    fn rename(
        &self,
        _req: &Request,
        _parent: INodeNo,
        _name: &OsStr,
        _newparent: INodeNo,
        _newname: &OsStr,
        _flags: RenameFlags,
        reply: ReplyEmpty,
    ) {
        reply.error(Errno::EROFS);
    }

    fn link(
        &self,
        _req: &Request,
        _ino: INodeNo,
        _newparent: INodeNo,
        _newname: &OsStr,
        reply: ReplyEntry,
    ) {
        reply.error(Errno::EROFS);
    }

    fn write(
        &self,
        _req: &Request,
        _ino: INodeNo,
        _fh: FileHandle,
        _offset: u64,
        _data: &[u8],
        _write_flags: WriteFlags,
        _flags: OpenFlags,
        _lock_owner: Option<LockOwner>,
        reply: ReplyWrite,
    ) {
        reply.error(Errno::EROFS);
    }

    fn create(
        &self,
        _req: &Request,
        _parent: INodeNo,
        _name: &OsStr,
        _mode: u32,
        _umask: u32,
        _flags: i32,
        reply: ReplyCreate,
    ) {
        reply.error(Errno::EROFS);
    }
}
