//! The daemon reads the power source itself (p14-energy-137), so it follows
//! AC and battery after the app quits; the app's `energy.set` stays an
//! override of this reading (server/energy_op.rs).
//!
//! On macOS the daemon registers a notify(3) descriptor for
//! `com.apple.system.powersources.source` (and `.percent` while on battery)
//! on its [`MaintenanceClock`]'s kqueue: no extra thread, no polling. Each post
//! reads AC or battery and the internal battery's charge with
//! `IOPSCopyPowerSourcesInfo`, the same snapshot the app's
//! `PowerSourceMonitor` reads (CmuxNextEnergy), and the reading turns into the
//! daemon's Energy Saver by the app's `auto` rule ([`PowerReading::saver`]).
//! A Mac without an `IOPMPowerSource` service registers nothing, as the app
//! and Chrome do (components/power_monitor/battery_state_sampler_mac.cc). On
//! other systems the daemon reads nothing and follows the app.

use std::io;
use std::sync::{Arc, Weak};

use super::Mux;
use crate::server::energy_op::DaemonEnergy;
#[cfg(target_os = "macos")]
use crate::wake::MaintenanceClock;
use crate::wake::PowerReading;

impl Mux {
    /// Follows this Mac's power source into the daemon's own Energy Saver
    /// reading when `features` turns `energySaver` on. Call once the mux is
    /// built.
    pub fn start_power_source(
        self: &Arc<Self>,
        features: &cmux_features::Snapshot,
    ) -> io::Result<()> {
        if !features.is_enabled(cmux_features::feature::ENERGY_SAVER) {
            return Ok(());
        }
        start(self)
    }

    /// This process's one maintenance clock, started on first use and
    /// following [`DaemonEnergy`]'s mode.
    #[cfg(target_os = "macos")]
    fn maintenance_clock(&self) -> io::Result<&MaintenanceClock> {
        if let Some(clock) = self.maintenance.get() {
            return Ok(clock);
        }
        let clock = MaintenanceClock::start(self.energy.mode())?;
        Ok(self.maintenance.get_or_init(|| clock))
    }
}

#[cfg(target_os = "macos")]
fn start(mux: &Arc<Mux>) -> io::Result<()> {
    if !macos::has_power_source() {
        return Ok(());
    }
    let source = macos::NotifyPowerSource::register()?;
    let mux_ref = Arc::downgrade(mux);
    mux.maintenance_clock()?.follow_power(source, deliver(mux_ref)).map_err(io::Error::other)
}

/// Not macOS: the daemon follows the app's `energy.set` alone.
#[cfg(not(target_os = "macos"))]
fn start(_mux: &Arc<Mux>) -> io::Result<()> {
    Ok(())
}

/// Passes each reading on to `mux`'s energy, while the mux lives.
#[cfg_attr(not(any(test, target_os = "macos")), expect(dead_code, reason = "macOS reads"))]
fn deliver(mux: Weak<Mux>) -> impl FnMut(PowerReading) + Send + 'static {
    move |reading| {
        if let Some(mux) = mux.upgrade() {
            apply(&mux.energy, reading);
        }
    }
}

/// Sets the daemon's own reading from `reading` by the app's rule. An app
/// override still decides the mode until it is cleared or its connection
/// ends. Returns whether the mode changed.
fn apply(energy: &DaemonEnergy, reading: PowerReading) -> bool {
    energy.set_reading(reading.saver())
}

/// `current` as a share of `full`, rounded and clamped to 0..=100; `None`
/// when either is missing or `full` is 0 (the app's `BatteryLevel.percent`).
#[cfg_attr(not(any(test, target_os = "macos")), expect(dead_code, reason = "macOS reads"))]
fn percent(current: Option<i64>, full: Option<i64>) -> Option<u8> {
    let (current, full) = (current?, full?);
    if full <= 0 {
        return None;
    }
    let share = (current as f64 * 100.0 / full as f64).round().clamp(0.0, 100.0);
    Some(share as u8)
}

#[cfg(target_os = "macos")]
mod macos {
    use std::ffi::{CStr, c_char, c_int, c_void};
    use std::io;

    use crate::wake::{PowerReading, PowerSource, RegisterError};

    type CFTypeRef = *const c_void;
    type CFIndex = isize;

    /// `kIOPSNotifyPowerSource`: AC, battery or UPS started providing power.
    const SOURCE_CHANGE: &CStr = c"com.apple.system.powersources.source";
    /// `kIOPSNotifyPercentChange`: the battery's charge changed.
    const PERCENT_CHANGE: &CStr = c"com.apple.system.powersources.percent";
    const NOTIFY_STATUS_OK: u32 = 0;
    /// `NOTIFY_REUSE`: post to the descriptor passed in, not a new one.
    const NOTIFY_REUSE: c_int = 1;
    const UTF8: u32 = 0x0800_0100;
    /// `kCFNumberSInt64Type`.
    const SINT64: CFIndex = 4;
    /// `kIOPMBatteryPowerKey`.
    const BATTERY_POWER: &CStr = c"Battery Power";
    /// `kIOPSTypeKey` and `kIOPSInternalBatteryType`.
    const TYPE_KEY: &CStr = c"Type";
    const INTERNAL_BATTERY: &CStr = c"InternalBattery";
    /// `kIOPSCurrentCapacityKey` and `kIOPSMaxCapacityKey`.
    const CURRENT_CAPACITY: &CStr = c"Current Capacity";
    const MAX_CAPACITY: &CStr = c"Max Capacity";

    // notify(3) is part of libSystem.
    unsafe extern "C" {
        fn notify_register_file_descriptor(
            name: *const c_char,
            notify_fd: *mut c_int,
            flags: c_int,
            out_token: *mut c_int,
        ) -> u32;
        fn notify_cancel(token: c_int) -> u32;
    }

    #[link(name = "CoreFoundation", kind = "framework")]
    unsafe extern "C" {
        fn CFRelease(object: CFTypeRef);
        fn CFGetTypeID(object: CFTypeRef) -> usize;
        fn CFStringGetTypeID() -> usize;
        fn CFNumberGetTypeID() -> usize;
        fn CFArrayGetCount(array: CFTypeRef) -> CFIndex;
        fn CFArrayGetValueAtIndex(array: CFTypeRef, index: CFIndex) -> CFTypeRef;
        fn CFDictionaryGetValue(dictionary: CFTypeRef, key: CFTypeRef) -> CFTypeRef;
        fn CFNumberGetValue(number: CFTypeRef, number_type: CFIndex, value: *mut c_void) -> u8;
        fn CFStringCreateWithCString(
            allocator: CFTypeRef,
            string: *const c_char,
            encoding: u32,
        ) -> CFTypeRef;
        fn CFStringGetCString(
            string: CFTypeRef,
            buffer: *mut c_char,
            size: CFIndex,
            encoding: u32,
        ) -> u8;
    }

    #[link(name = "IOKit", kind = "framework")]
    unsafe extern "C" {
        fn IOPSCopyPowerSourcesInfo() -> CFTypeRef;
        fn IOPSCopyPowerSourcesList(blob: CFTypeRef) -> CFTypeRef;
        fn IOPSGetPowerSourceDescription(blob: CFTypeRef, source: CFTypeRef) -> CFTypeRef;
        fn IOPSGetProvidingPowerSourceType(snapshot: CFTypeRef) -> CFTypeRef;
        fn IOServiceMatching(name: *const c_char) -> CFTypeRef;
        fn IOServiceGetMatchingService(main_port: u32, matching: CFTypeRef) -> u32;
        fn IOObjectRelease(object: u32) -> c_int;
    }

    /// The Mac has an `IOPMPowerSource` service (a Mac mini, Studio or Pro
    /// has none): the app's `PowerSourceMonitor.hasPowerSourceService`.
    pub(super) fn has_power_source() -> bool {
        // SAFETY: the class name is a NUL-terminated literal; the matching
        // dictionary is consumed by IOServiceGetMatchingService (also when it
        // is null); a found service is released once.
        unsafe {
            let service =
                IOServiceGetMatchingService(0, IOServiceMatching(c"IOPMPowerSource".as_ptr()));
            if service == 0 {
                return false;
            }
            IOObjectRelease(service);
        }
        true
    }

    /// notify(3)'s power-source posts on one non-blocking descriptor, with
    /// the charge posts on it too while on battery.
    pub(super) struct NotifyPowerSource {
        descriptor: c_int,
        source: c_int,
        percent: Option<c_int>,
    }

    impl NotifyPowerSource {
        pub(super) fn register() -> io::Result<Self> {
            let (mut descriptor, mut token) = (-1, 0);
            // SAFETY: the name is a NUL-terminated literal; notify writes the
            // new descriptor and token to the two locals before it returns.
            let status = unsafe {
                notify_register_file_descriptor(
                    SOURCE_CHANGE.as_ptr(),
                    &raw mut descriptor,
                    0,
                    &raw mut token,
                )
            };
            if status != NOTIFY_STATUS_OK {
                return Err(io::Error::other(RegisterError::PowerSource(status)));
            }
            let source = Self { descriptor, source: token, percent: None };
            // The first read drains a descriptor nothing was posted to yet.
            // SAFETY: fcntl reads and sets the flags of a descriptor we own.
            let blocking = unsafe {
                let flags = libc::fcntl(descriptor, libc::F_GETFL);
                flags < 0 || libc::fcntl(descriptor, libc::F_SETFL, flags | libc::O_NONBLOCK) < 0
            };
            if blocking { Err(io::Error::last_os_error()) } else { Ok(source) }
        }

        /// Reads every posted token (four bytes each) until none is left.
        fn drain(&self) {
            let mut tokens = [0_u8; 64];
            loop {
                // SAFETY: `tokens` is writable for its length; the descriptor
                // is non-blocking, so the read returns at once.
                let read = unsafe {
                    libc::read(self.descriptor, tokens.as_mut_ptr().cast(), tokens.len())
                };
                if read > 0
                    || (read < 0 && io::Error::last_os_error().kind() == io::ErrorKind::Interrupted)
                {
                    continue;
                }
                return;
            }
        }

        /// The charge posts only while on battery, as the app subscribes.
        fn follow_percent(&mut self, on_battery: bool) {
            match (on_battery, self.percent) {
                (true, None) => {
                    let (mut descriptor, mut token) = (self.descriptor, 0);
                    // SAFETY: as in `register`; NOTIFY_REUSE posts to the
                    // descriptor passed in, which this source owns.
                    let status = unsafe {
                        notify_register_file_descriptor(
                            PERCENT_CHANGE.as_ptr(),
                            &raw mut descriptor,
                            NOTIFY_REUSE,
                            &raw mut token,
                        )
                    };
                    if status == NOTIFY_STATUS_OK {
                        self.percent = Some(token);
                    }
                }
                (false, Some(token)) => {
                    // SAFETY: `token` is this source's live registration.
                    unsafe { notify_cancel(token) };
                    self.percent = None;
                }
                _ => {}
            }
        }
    }

    impl PowerSource for NotifyPowerSource {
        fn descriptor(&self) -> c_int {
            self.descriptor
        }

        fn read(&mut self) -> PowerReading {
            self.drain();
            let reading = read();
            self.follow_percent(reading.on_battery);
            reading
        }
    }

    impl Drop for NotifyPowerSource {
        /// notify(3) closes the descriptor when its last token is cancelled.
        fn drop(&mut self) {
            // SAFETY: both tokens are this source's live registrations.
            unsafe {
                if let Some(token) = self.percent.take() {
                    notify_cancel(token);
                }
                notify_cancel(self.source);
            }
        }
    }

    /// The power source now, from one IOKit snapshot: the app's
    /// `PowerSourceMonitor.read`.
    fn read() -> PowerReading {
        // SAFETY: the snapshot is released once; the providing type and the
        // descriptions are owned by the snapshot and read before it goes.
        unsafe {
            let info = IOPSCopyPowerSourcesInfo();
            if info.is_null() {
                return PowerReading::default();
            }
            let on_battery = string_is(IOPSGetProvidingPowerSourceType(info), BATTERY_POWER);
            let battery = internal_battery(info);
            CFRelease(info);
            PowerReading {
                on_battery,
                has_battery: battery.is_some(),
                battery_percent: battery.flatten(),
            }
        }
    }

    /// The first internal battery's charge in `info`: `None` without one,
    /// `Some(None)` without a capacity.
    ///
    /// # Safety
    /// `info` is a live `IOPSCopyPowerSourcesInfo` snapshot.
    unsafe fn internal_battery(info: CFTypeRef) -> Option<Option<u8>> {
        // SAFETY: the caller's snapshot; the list is released once and each
        // description belongs to the snapshot.
        unsafe {
            let list = IOPSCopyPowerSourcesList(info);
            if list.is_null() {
                return None;
            }
            let mut found = None;
            for index in 0..CFArrayGetCount(list) {
                let description =
                    IOPSGetPowerSourceDescription(info, CFArrayGetValueAtIndex(list, index));
                if !description.is_null()
                    && string_is(value(description, TYPE_KEY), INTERNAL_BATTERY)
                {
                    found = Some(super::percent(
                        number(value(description, CURRENT_CAPACITY)),
                        number(value(description, MAX_CAPACITY)),
                    ));
                    break;
                }
            }
            CFRelease(list);
            found
        }
    }

    /// `dictionary[key]`, owned by the dictionary; null when absent.
    ///
    /// # Safety
    /// `dictionary` is a live CFDictionary.
    unsafe fn value(dictionary: CFTypeRef, key: &CStr) -> CFTypeRef {
        // SAFETY: the key string is created and released here; the value
        // belongs to the caller's dictionary.
        unsafe {
            let key = CFStringCreateWithCString(std::ptr::null(), key.as_ptr(), UTF8);
            if key.is_null() {
                return std::ptr::null();
            }
            let found = CFDictionaryGetValue(dictionary, key);
            CFRelease(key);
            found
        }
    }

    /// Whether `string` is a CFString equal to `expected`.
    ///
    /// # Safety
    /// `string` is null or a live CF object.
    unsafe fn string_is(string: CFTypeRef, expected: &CStr) -> bool {
        let mut buffer: [c_char; 64] = [0; 64];
        // SAFETY: the type is checked before the copy, which writes at most
        // the buffer's length including the NUL.
        unsafe {
            !string.is_null()
                && CFGetTypeID(string) == CFStringGetTypeID()
                && CFStringGetCString(string, buffer.as_mut_ptr(), 64, UTF8) != 0
                && CStr::from_ptr(buffer.as_ptr()) == expected
        }
    }

    /// `number` as an integer when it is a CFNumber.
    ///
    /// # Safety
    /// `number` is null or a live CF object.
    unsafe fn number(number: CFTypeRef) -> Option<i64> {
        let mut out: i64 = 0;
        // SAFETY: the type is checked before CFNumberGetValue writes one
        // i64 to `out`.
        let read = unsafe {
            !number.is_null()
                && CFGetTypeID(number) == CFNumberGetTypeID()
                && CFNumberGetValue(number, SINT64, (&raw mut out).cast()) != 0
        };
        read.then_some(out)
    }
}

#[cfg(test)]
#[path = "power_source_tests.rs"]
mod tests;
