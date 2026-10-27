//! The macOS stack sampler: one stack of a hung thread, taken from the watcher thread (p09 task 072).
//!
//! It follows Chrome's `SuspendableThreadDelegateMac` and `StackSamplerImpl::CopyStack`
//! (base/profiler/suspendable_thread_delegate_mac.cc, base/profiler/stack_sampler_impl.cc): while the
//! target is suspended the sampler takes no lock and allocates nothing, because the target may hold
//! the malloc lock or any other. Between `thread_suspend` and `thread_resume` it only reads the
//! registers and walks the frame-pointer chain (Chrome's base/profiler/frame_pointer_unwinder.cc)
//! inside the thread's stack bounds into a preallocated [`RawStack`]. A guard resumes the thread on
//! every path. Everything that can lock or allocate (the stack bounds, which take pthread's list
//! lock, and the mapping to images) runs before the suspend or after the resume.
//!
//! Addresses map to an image UUID and offset through a table that dyld's add-image callback fills
//! (Chrome's base/profiler/module_cache_mac.cc reads the same `LC_UUID`). The callback has no context
//! argument, so the table is a process static; it is append-only and lock-free, and it keeps each
//! image's file name, so mapping a stack never calls into dyld (a thread hung inside dlopen holds
//! dyld's lock). [`install_image_table`] fills it when the watcher starts.
//!
//! Frame pointers: x86_64-apple-darwin and aarch64-apple-darwin both keep them (rustc's Apple target
//! specs set `frame-pointer` to `always` and `non-leaf`). The walk starts at fp and never reads the
//! arm64 link register, as Chrome's unwinder does: lr is the caller only in a leaf or before a
//! prologue, and after any call returns it is a stale address that would add a frame that is not
//! there. A leaf's caller is the one frame this loses.

use std::ffi::{c_char, c_int, c_void};
use std::sync::Once;
use std::sync::atomic::{AtomicU64, AtomicUsize, Ordering};

#[cfg(target_arch = "aarch64")]
use crate::frame_walk::strip;
use crate::frame_walk::{Bounds, Registers, walk};
pub use crate::frame_walk::{MAX_FRAMES, RawStack};
use crate::stack::{Stack, StackFrame, StackImage};

/// Images the image table holds; an image loaded past this is counted and its frames stay unmapped.
pub const MAX_IMAGES: usize = 2048;

type KernReturn = c_int;
type MachPort = libc::mach_port_t;

const KERN_SUCCESS: KernReturn = 0;
const MACH_PORT_RIGHT_SEND: u32 = 0;

unsafe extern "C" {
    static mach_task_self_: MachPort;
    fn _NSGetExecutablePath(buf: *mut c_char, bufsize: *mut u32) -> c_int;
    fn thread_suspend(thread: MachPort) -> KernReturn;
    fn thread_resume(thread: MachPort) -> KernReturn;
    fn thread_get_state(
        thread: MachPort,
        flavor: c_int,
        state: *mut u32,
        count: *mut u32,
    ) -> KernReturn;
    fn mach_port_mod_refs(task: MachPort, name: MachPort, right: u32, delta: i32) -> KernReturn;
    fn mach_port_deallocate(task: MachPort, name: MachPort) -> KernReturn;
    fn _dyld_register_func_for_add_image(callback: extern "C" fn(*const c_void, isize));
    fn _dyld_register_func_for_remove_image(callback: extern "C" fn(*const c_void, isize));
}

/// Why a sample was not taken. Every variant leaves the target running.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum SampleError {
    /// The slot holds no thread port.
    NoThread,
    /// A thread cannot suspend itself to sample.
    SelfThread,
    /// The port no longer names a live thread.
    DeadThread(KernReturn),
    /// The slot changed owner before the walk (checked again while the thread is suspended).
    Unregistered,
    /// `thread_suspend` failed.
    Suspend(KernReturn),
    /// `thread_get_state` failed.
    State(KernReturn),
}

impl std::fmt::Display for SampleError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            SampleError::NoThread => f.write_str("no thread port to sample"),
            SampleError::SelfThread => f.write_str("a thread cannot sample itself"),
            SampleError::DeadThread(code) => write!(f, "the thread is gone (kern_return {code})"),
            SampleError::Unregistered => f.write_str("the thread unregistered before the sample"),
            SampleError::Suspend(code) => write!(f, "thread_suspend failed (kern_return {code})"),
            SampleError::State(code) => write!(f, "thread_get_state failed (kern_return {code})"),
        }
    }
}

impl std::error::Error for SampleError {}

/// The calling thread's Mach port, as the slot table records it (no new port right).
pub fn current_thread_port() -> u32 {
    // SAFETY: pthread_self has no preconditions and names the calling thread.
    unsafe { libc::pthread_mach_thread_np(libc::pthread_self()) }
}

/// Samples the thread `port` names and maps its frames to images.
pub fn sample(port: u32) -> Result<Stack, SampleError> {
    sample_checked(port, || true)
}

/// [`sample`] that first takes a reference on the port, then asks `still_valid` whether the port is
/// still the thread the caller means (the hang watch checks the slot's generation): once before the
/// suspend, and once more after it, before it reads the thread's stack. `still_valid` runs while the
/// thread is suspended, so it must not lock or allocate (one atomic load).
pub fn sample_checked(port: u32, still_valid: impl Fn() -> bool) -> Result<Stack, SampleError> {
    let mut raw = RawStack::new();
    sample_raw_checked(port, &mut raw, still_valid)?;
    Ok(resolve(&raw))
}

/// The suspended part of a sample, into `out`. It allocates nothing at all, so a target that holds
/// the malloc lock cannot block it.
pub fn sample_raw(port: u32, out: &mut RawStack) -> Result<(), SampleError> {
    sample_raw_checked(port, out, || true)
}

/// [`sample_raw`] with the two `still_valid` checks of [`sample_checked`]; `out` stays empty when
/// either says no.
pub fn sample_raw_checked(
    port: u32,
    out: &mut RawStack,
    still_valid: impl Fn() -> bool,
) -> Result<(), SampleError> {
    out.clear();
    if port == 0 {
        return Err(SampleError::NoThread);
    }
    if port == current_thread_port() {
        return Err(SampleError::SelfThread);
    }
    // Our own send right keeps the port name from naming another thread until the sample ends.
    let _retained = RetainedPort::new(port)?;
    if !still_valid() {
        return Err(SampleError::Unregistered);
    }
    let bounds = stack_bounds(port);
    let mut state = ThreadState::default();
    let mut count = STATE_COUNT;
    let suspended = Suspended::new(port)?;
    // Suspended: register reads and stack loads only, until `suspended` drops. The thread unregisters
    // (its Guard drops) before it exits and pthread_exit frees its stack, so an unchanged generation
    // now means the stack stays mapped through the walk.
    if !still_valid() {
        return Err(SampleError::Unregistered);
    }
    // SAFETY: `state` is a THREAD_STATE_FLAVOR struct of `count` 32-bit words.
    let read = unsafe {
        thread_get_state(port, THREAD_STATE_FLAVOR, (&raw mut state).cast::<u32>(), &mut count)
    };
    if read == KERN_SUCCESS {
        walk(state.registers(), bounds, out);
    }
    drop(suspended);
    if read == KERN_SUCCESS { Ok(()) } else { Err(SampleError::State(read)) }
}

/// This task's port (what `mach_task_self()` reads).
fn task() -> MachPort {
    // SAFETY: libSystem sets `mach_task_self_` before any Rust code runs and never changes it.
    unsafe { mach_task_self_ }
}

/// A send right on a thread port, released when it drops.
struct RetainedPort(MachPort);

impl RetainedPort {
    fn new(port: MachPort) -> Result<RetainedPort, SampleError> {
        // SAFETY: adds one send right to a port name of this task; a dead name only fails.
        let code = unsafe { mach_port_mod_refs(task(), port, MACH_PORT_RIGHT_SEND, 1) };
        if code == KERN_SUCCESS {
            Ok(RetainedPort(port))
        } else {
            Err(SampleError::DeadThread(code))
        }
    }
}

impl Drop for RetainedPort {
    fn drop(&mut self) {
        // SAFETY: releases the one send right `new` added.
        let _ = unsafe { mach_port_deallocate(task(), self.0) };
    }
}

/// A suspended thread, resumed when it drops, on every path.
struct Suspended(MachPort);

impl Suspended {
    fn new(port: MachPort) -> Result<Suspended, SampleError> {
        // SAFETY: `port` is a live thread port of this task (retained by the caller), not ours.
        let code = unsafe { thread_suspend(port) };
        if code == KERN_SUCCESS { Ok(Suspended(port)) } else { Err(SampleError::Suspend(code)) }
    }
}

impl Drop for Suspended {
    fn drop(&mut self) {
        // SAFETY: undoes the one suspend `new` made.
        let _ = unsafe { thread_resume(self.0) };
    }
}

/// Before the suspend: pthread's lookups take its list lock.
fn stack_bounds(port: MachPort) -> Option<Bounds> {
    // SAFETY: returns 0 when the port is not a pthread of this process.
    let thread = unsafe { libc::pthread_from_mach_thread_np(port) };
    if thread == 0 {
        return None;
    }
    // SAFETY: both validate `thread` under pthread's list lock and return ESRCH (a tiny value) when
    // it exited meanwhile.
    let (top, size) = unsafe {
        (
            libc::pthread_get_stackaddr_np(thread) as u64,
            libc::pthread_get_stacksize_np(thread) as u64,
        )
    };
    (top >= 0x10000 && size >= 0x1000 && size <= top)
        .then_some(Bounds { low: top - size, high: top })
}

#[cfg(target_arch = "aarch64")]
const THREAD_STATE_FLAVOR: c_int = 6; // ARM_THREAD_STATE64

/// `arm_thread_state64_t`.
#[cfg(target_arch = "aarch64")]
#[repr(C)]
#[derive(Default)]
struct ThreadState {
    x: [u64; 29],
    fp: u64,
    lr: u64,
    sp: u64,
    pc: u64,
    cpsr: u32,
    flags: u32,
}

#[cfg(target_arch = "aarch64")]
impl ThreadState {
    fn registers(&self) -> Registers {
        Registers { pc: strip(self.pc), sp: strip(self.sp), fp: strip(self.fp) }
    }
}

#[cfg(target_arch = "x86_64")]
const THREAD_STATE_FLAVOR: c_int = 4; // x86_THREAD_STATE64

/// `x86_thread_state64_t`: rax rbx rcx rdx rdi rsi rbp rsp r8-r15 rip rflags cs fs gs.
#[cfg(target_arch = "x86_64")]
#[repr(C)]
#[derive(Default)]
struct ThreadState {
    words: [u64; 21],
}

#[cfg(target_arch = "x86_64")]
impl ThreadState {
    fn registers(&self) -> Registers {
        Registers { pc: self.words[16], sp: self.words[7], fp: self.words[6] }
    }
}

const STATE_COUNT: u32 = (size_of::<ThreadState>() / size_of::<u32>()) as u32;

/// Maps the addresses to images, after the resume (it allocates).
pub fn resolve(raw: &RawStack) -> Stack {
    install_image_table();
    let mut stack = Stack { truncated: raw.truncated(), ..Stack::default() };
    for &address in raw.addresses() {
        let image = image_for(address).map(|found| {
            let index = match stack.images.iter().position(|i| i.load_address == found.load_address)
            {
                Some(index) => index,
                None => {
                    stack.images.push(found);
                    stack.images.len() - 1
                }
            };
            u32::try_from(index).unwrap_or(u32::MAX)
        });
        stack.frames.push(StackFrame { address, image });
    }
    stack
}

/// The loaded image that holds `address`.
pub fn image_for(address: u64) -> Option<StackImage> {
    install_image_table();
    let count = IMAGE_SLOTS.load(Ordering::Acquire).min(MAX_IMAGES);
    IMAGES[..count].iter().find_map(|entry| {
        let start = entry.start.load(Ordering::Acquire);
        let size = entry.size.load(Ordering::Relaxed);
        (start != 0 && address >= start && address - start < size).then(|| StackImage {
            uuid: entry.uuid(),
            load_address: start,
            size,
            name: entry.name(),
        })
    })
}

/// Images that did not fit in the table.
pub fn image_overflow() -> u64 {
    IMAGE_OVERFLOW.load(Ordering::Relaxed)
}

/// Bytes of an image's file name the table keeps.
const IMAGE_NAME_BYTES: usize = 48;

/// One image: its header address (0 while unwritten or after the image unloads), its `__TEXT` size,
/// its UUID and its file name.
struct ImageEntry {
    start: AtomicU64,
    size: AtomicU64,
    uuid: [AtomicU64; 2],
    name: [AtomicU64; IMAGE_NAME_BYTES / 8],
}

impl ImageEntry {
    const fn new() -> ImageEntry {
        ImageEntry {
            start: AtomicU64::new(0),
            size: AtomicU64::new(0),
            uuid: [AtomicU64::new(0), AtomicU64::new(0)],
            name: [const { AtomicU64::new(0) }; IMAGE_NAME_BYTES / 8],
        }
    }

    fn set_name(&self, name: &[u8]) {
        let mut bytes = [0u8; IMAGE_NAME_BYTES];
        let length = name.len().min(IMAGE_NAME_BYTES);
        bytes[..length].copy_from_slice(&name[..length]);
        for (word, chunk) in self.name.iter().zip(bytes.chunks_exact(8)) {
            let mut le = [0u8; 8];
            le.copy_from_slice(chunk);
            word.store(u64::from_le_bytes(le), Ordering::Relaxed);
        }
    }

    fn name(&self) -> String {
        let mut bytes = [0u8; IMAGE_NAME_BYTES];
        for (word, chunk) in self.name.iter().zip(bytes.chunks_exact_mut(8)) {
            chunk.copy_from_slice(&word.load(Ordering::Relaxed).to_le_bytes());
        }
        let end = bytes.iter().position(|byte| *byte == 0).unwrap_or(IMAGE_NAME_BYTES);
        String::from_utf8_lossy(&bytes[..end]).into_owned()
    }

    fn uuid(&self) -> [u8; 16] {
        let mut uuid = [0u8; 16];
        uuid[..8].copy_from_slice(&self.uuid[0].load(Ordering::Relaxed).to_ne_bytes());
        uuid[8..].copy_from_slice(&self.uuid[1].load(Ordering::Relaxed).to_ne_bytes());
        uuid
    }
}

static IMAGES: [ImageEntry; MAX_IMAGES] = [const { ImageEntry::new() }; MAX_IMAGES];
/// Entries claimed; an entry is readable once its `start` is non-zero.
static IMAGE_SLOTS: AtomicUsize = AtomicUsize::new(0);
static IMAGE_OVERFLOW: AtomicU64 = AtomicU64::new(0);
static INSTALL: Once = Once::new();

/// Registers the dyld callbacks once; dyld calls the add callback for every image already loaded
/// before this returns. The hang watcher calls it at start, so a hang's mapping finds it filled.
pub fn install_image_table() {
    INSTALL.call_once(|| {
        // SAFETY: both callbacks are `extern "C"` functions that live for the whole process.
        unsafe {
            _dyld_register_func_for_add_image(image_added);
            _dyld_register_func_for_remove_image(image_removed);
        }
    });
}

extern "C" fn image_added(header: *const c_void, _slide: isize) {
    // SAFETY: dyld passes the header of a mapped image.
    let Some(image) = (unsafe { parse_image(header) }) else { return };
    let index = IMAGE_SLOTS.fetch_add(1, Ordering::AcqRel);
    let Some(entry) = IMAGES.get(index) else {
        IMAGE_OVERFLOW.fetch_add(1, Ordering::Relaxed);
        return;
    };
    let mut words = [[0u8; 8]; 2];
    words[0].copy_from_slice(&image.uuid[..8]);
    words[1].copy_from_slice(&image.uuid[8..]);
    match image.id_name {
        Some(path) => entry.set_name(file_name(path)),
        None if image.filetype == MH_EXECUTE => {
            let mut path = [0 as c_char; 1024];
            let mut length = path.len() as u32;
            // SAFETY: writes at most `length` bytes, NUL included, into `path`.
            if unsafe { _NSGetExecutablePath(path.as_mut_ptr(), &mut length) } == 0 {
                let bytes = path.map(|byte| byte as u8);
                let end = bytes.iter().position(|byte| *byte == 0).unwrap_or(bytes.len());
                entry.set_name(file_name(&bytes[..end]));
            }
        }
        None => {}
    }
    entry.size.store(image.text_size, Ordering::Relaxed);
    entry.uuid[0].store(u64::from_ne_bytes(words[0]), Ordering::Relaxed);
    entry.uuid[1].store(u64::from_ne_bytes(words[1]), Ordering::Relaxed);
    entry.start.store(header as u64, Ordering::Release);
}

extern "C" fn image_removed(header: *const c_void, _slide: isize) {
    let start = header as u64;
    let count = IMAGE_SLOTS.load(Ordering::Acquire).min(MAX_IMAGES);
    if let Some(entry) = IMAGES[..count].iter().find(|e| e.start.load(Ordering::Relaxed) == start) {
        entry.start.store(0, Ordering::Release);
    }
}

/// The part of a path after its last `/` (a directory can hold the person's name).
fn file_name(path: &[u8]) -> &[u8] {
    path.rsplit(|byte| *byte == b'/').next().unwrap_or(path)
}

const MH_MAGIC_64: u32 = 0xfeed_facf;
const MH_EXECUTE: u32 = 0x2;
const LC_ID_DYLIB: u32 = 0xd;
const LC_SEGMENT_64: u32 = 0x19;
const LC_UUID: u32 = 0x1b;

/// What the table keeps of one image's header.
struct ParsedImage<'a> {
    filetype: u32,
    text_size: u64,
    uuid: [u8; 16],
    /// A dylib's install name (`LC_ID_DYLIB`), inside the mapped header.
    id_name: Option<&'a [u8]>,
}

/// `mach_header_64`.
#[repr(C)]
struct MachHeader64 {
    magic: u32,
    cputype: i32,
    cpusubtype: i32,
    filetype: u32,
    ncmds: u32,
    sizeofcmds: u32,
    flags: u32,
    reserved: u32,
}

/// `load_command`.
#[repr(C)]
struct LoadCommand {
    cmd: u32,
    cmdsize: u32,
}

/// `segment_command_64`, up to `vmsize`.
#[repr(C)]
struct SegmentCommand64 {
    cmd: u32,
    cmdsize: u32,
    segname: [u8; 16],
    vmaddr: u64,
    vmsize: u64,
}

/// The image's type, `__TEXT` size, `LC_UUID` and install name; None for a 32-bit or UUID-less
/// image.
///
/// # Safety
/// `header` is null or the Mach-O header of a mapped image, its load commands right after it, and
/// it stays mapped for `'a`.
unsafe fn parse_image<'a>(header: *const c_void) -> Option<ParsedImage<'a>> {
    if header.is_null() {
        return None;
    }
    // SAFETY: the caller passes a mapped image header.
    let mach = unsafe { header.cast::<MachHeader64>().read_unaligned() };
    if mach.magic != MH_MAGIC_64 {
        return None;
    }
    let commands = header.cast::<u8>().wrapping_add(size_of::<MachHeader64>());
    let end = usize::try_from(mach.sizeofcmds).ok()?;
    let (mut offset, mut size, mut uuid, mut id_name) = (0usize, None, None, None);
    for _ in 0..mach.ncmds {
        if offset + size_of::<LoadCommand>() > end {
            break;
        }
        let command = commands.wrapping_add(offset);
        // SAFETY: inside the header's `sizeofcmds` bytes of load commands.
        let load = unsafe { command.cast::<LoadCommand>().read_unaligned() };
        let length = usize::try_from(load.cmdsize).ok()?;
        if length < size_of::<LoadCommand>() || offset + length > end {
            break;
        }
        if load.cmd == LC_UUID && length >= size_of::<LoadCommand>() + 16 {
            // SAFETY: an LC_UUID command holds 16 UUID bytes after its 8-byte head.
            uuid = Some(unsafe {
                command.wrapping_add(size_of::<LoadCommand>()).cast::<[u8; 16]>().read_unaligned()
            });
        } else if load.cmd == LC_SEGMENT_64 && length >= size_of::<SegmentCommand64>() {
            // SAFETY: an LC_SEGMENT_64 command starts with a segment_command_64.
            let segment = unsafe { command.cast::<SegmentCommand64>().read_unaligned() };
            if segment.segname.starts_with(b"__TEXT\0") {
                size = Some(segment.vmsize);
            }
        } else if load.cmd == LC_ID_DYLIB && length > size_of::<LoadCommand>() + 4 {
            // SAFETY: a dylib_command's `name.offset` (a u32) follows its 8-byte head, and the
            // command's `length` bytes are mapped.
            let (name_offset, all) = unsafe {
                (
                    command.wrapping_add(size_of::<LoadCommand>()).cast::<u32>().read_unaligned(),
                    std::slice::from_raw_parts(command, length),
                )
            };
            let name = usize::try_from(name_offset).ok().and_then(|start| all.get(start..));
            id_name = name.map(|name| {
                let end = name.iter().position(|byte| *byte == 0).unwrap_or(name.len());
                &name[..end]
            });
        }
        offset += length;
    }
    Some(ParsedImage { filetype: mach.filetype, text_size: size?, uuid: uuid?, id_name })
}
