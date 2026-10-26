//! The frame-pointer walk the stack sampler runs while its target is suspended (Chromium's
//! base/profiler/frame_pointer_unwinder.cc): it reads only the stack between the stack pointer and
//! the stack's base and writes into a preallocated [`RawStack`], so it takes no lock and allocates
//! nothing. It is portable code; only the macOS sampler calls it.

/// Frames one sample keeps.
pub const MAX_FRAMES: usize = 128;

/// The addresses one sample wrote while the target was suspended, innermost first.
pub struct RawStack {
    addresses: [u64; MAX_FRAMES],
    len: usize,
    truncated: bool,
}

impl Default for RawStack {
    fn default() -> RawStack {
        RawStack::new()
    }
}

impl RawStack {
    pub const fn new() -> RawStack {
        RawStack { addresses: [0; MAX_FRAMES], len: 0, truncated: false }
    }

    pub fn addresses(&self) -> &[u64] {
        &self.addresses[..self.len]
    }

    /// The walk stopped at [`MAX_FRAMES`].
    pub fn truncated(&self) -> bool {
        self.truncated
    }

    pub(crate) fn clear(&mut self) {
        self.len = 0;
        self.truncated = false;
    }

    /// False when full.
    pub(crate) fn push(&mut self, address: u64) -> bool {
        if self.len == MAX_FRAMES {
            self.truncated = true;
            return false;
        }
        self.addresses[self.len] = address;
        self.len += 1;
        true
    }
}

/// The thread's stack, `[low, high)`; high is the stack's base (stacks grow down).
#[derive(Clone, Copy)]
pub(crate) struct Bounds {
    pub(crate) low: u64,
    pub(crate) high: u64,
}

pub(crate) struct Registers {
    pub(crate) pc: u64,
    pub(crate) sp: u64,
    pub(crate) fp: u64,
    /// The arm64 link register: the return address of a leaf function that has no frame record.
    pub(crate) lr: Option<u64>,
}

/// User addresses fit in 47 bits; the bits above hold a pointer-authentication code on arm64e.
#[cfg(target_arch = "aarch64")]
pub(crate) fn strip(address: u64) -> u64 {
    address & 0x0000_7fff_ffff_ffff
}

#[cfg(not(target_arch = "aarch64"))]
pub(crate) fn strip(address: u64) -> u64 {
    address
}

/// The frame record at `fp` (the caller's fp, then the return address), when it lies inside the
/// stack between the stack pointer and the base.
fn frame_record(fp: u64, low: u64, high: u64) -> Option<(u64, u64)> {
    let end = fp.checked_add(16)?;
    if !fp.is_multiple_of(8) || fp < low || end > high {
        return None;
    }
    // SAFETY: [fp, fp + 16) lies inside `[low, high)`, which `walk`'s caller guarantees is mapped
    // stack memory of a thread that cannot unmap it meanwhile (it is suspended).
    let (next, ret) = unsafe {
        (std::ptr::read_volatile(fp as *const u64), std::ptr::read_volatile((fp + 8) as *const u64))
    };
    Some((strip(next), strip(ret)))
}

/// Runs while the target is suspended: no lock, no allocation, no call that could take either.
pub(crate) fn walk(registers: Registers, bounds: Option<Bounds>, out: &mut RawStack) {
    out.push(registers.pc);
    // A stack pointer outside the thread's stack (a signal stack) leaves only the registers.
    let bounds = bounds.filter(|b| registers.sp >= b.low && registers.sp < b.high);
    let Some(Bounds { high, .. }) = bounds else {
        if let Some(lr) = registers.lr.filter(|lr| *lr != 0) {
            out.push(lr);
        }
        return;
    };
    let low = registers.sp;
    let mut fp = registers.fp;
    let mut record = frame_record(fp, low, high);
    // A leaf (or a function before its prologue) has no record yet: its caller is in lr. When the
    // top record already returns to lr, lr is that frame and is not repeated.
    if let Some(lr) = registers.lr.filter(|lr| *lr != 0 && Some(*lr) != record.map(|r| r.1)) {
        out.push(lr);
    }
    while let Some((next, ret)) = record {
        if ret == 0 || !out.push(ret) || next <= fp {
            break;
        }
        fp = next;
        record = frame_record(fp, low, high);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn raw_stack_caps_at_max_frames() {
        let mut raw = RawStack::new();
        for address in 0..MAX_FRAMES as u64 {
            assert!(raw.push(address + 1));
        }
        assert!(!raw.push(9));
        assert!(raw.truncated());
        assert_eq!(raw.addresses().len(), MAX_FRAMES);
        raw.clear();
        assert!(raw.addresses().is_empty() && !raw.truncated());
    }

    #[test]
    fn walk_follows_records_inside_the_bounds_only() {
        // A fake stack: three records chained upward, the last pointing outside the bounds.
        let mut words = [0u64; 16];
        let base = words.as_mut_ptr() as u64;
        let at = |index: usize| base + 8 * index as u64;
        words[2] = at(6);
        words[3] = 0x1111;
        words[6] = at(10);
        words[7] = 0x2222;
        words[10] = at(40);
        words[11] = 0x3333;
        let bounds = Bounds { low: base, high: base + 8 * 16 };
        let registers = Registers { pc: 0x9999, sp: base, fp: at(2), lr: None };
        let mut raw = RawStack::new();
        walk(registers, Some(bounds), &mut raw);
        std::hint::black_box(&words);
        assert_eq!(raw.addresses(), [0x9999, 0x1111, 0x2222, 0x3333]);
    }

    #[test]
    fn walk_stops_at_the_frame_cap() {
        // Records that chain upward forever: the walk stops at MAX_FRAMES, marked truncated.
        let mut words = [0u64; 2 * (MAX_FRAMES + 8)];
        let base = words.as_mut_ptr() as u64;
        for record in 0..MAX_FRAMES + 7 {
            words[2 * record] = base + 16 * (record as u64 + 1);
            words[2 * record + 1] = 0x1000 + record as u64;
        }
        let bounds = Bounds { low: base, high: base + 8 * words.len() as u64 };
        let mut raw = RawStack::new();
        walk(Registers { pc: 0x9, sp: base, fp: base, lr: None }, Some(bounds), &mut raw);
        std::hint::black_box(&words);
        assert_eq!(raw.addresses().len(), MAX_FRAMES);
        assert!(raw.truncated());
    }

    #[test]
    fn walk_outside_the_stack_keeps_only_the_registers() {
        let words = [0u64; 4];
        let base = words.as_ptr() as u64;
        let bounds = Bounds { low: base, high: base + 32 };
        let mut raw = RawStack::new();
        let off_stack = Registers { pc: 0x9, sp: base + 64, fp: base, lr: Some(0x7) };
        walk(off_stack, Some(bounds), &mut raw);
        assert_eq!(raw.addresses(), [0x9, 0x7]);
    }

    #[test]
    fn walk_keeps_a_leaf_link_register_once() {
        let mut words = [0u64; 4];
        let base = words.as_mut_ptr() as u64;
        words[0] = 0;
        words[1] = 0x2222;
        let bounds = Bounds { low: base, high: base + 32 };
        let mut raw = RawStack::new();
        walk(Registers { pc: 0x9, sp: base, fp: base, lr: Some(0x2222) }, Some(bounds), &mut raw);
        assert_eq!(raw.addresses(), [0x9, 0x2222], "lr equals the top record: not repeated");
        raw.clear();
        walk(Registers { pc: 0x9, sp: base, fp: base, lr: Some(0x1111) }, Some(bounds), &mut raw);
        assert_eq!(raw.addresses(), [0x9, 0x1111, 0x2222], "a leaf's caller comes from lr");
        std::hint::black_box(&words);
    }
}
