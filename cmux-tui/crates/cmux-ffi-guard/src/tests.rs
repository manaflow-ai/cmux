use super::*;

fn record_of(ring: &PanicRing) -> Option<CmuxFfiPanic> {
    let mut out = CmuxFfiPanic::EMPTY;
    ring.take(&mut out).then_some(out)
}

/// The only test that drains the process ring (the others build their own);
/// it keeps only its own records, as another test may panic meanwhile.
#[test]
fn a_panic_returns_the_default_and_reaches_the_ring() {
    let hook = std::panic::take_hook();
    std::panic::set_hook(Box::new(|_| {}));
    let before = cmux_ffi_panic_count();
    assert_eq!(ffi_boundary("ring_test_ok", -6, || 7), 7);
    assert_eq!(ffi_boundary("ring_test_str", -6, || -> i32 { panic!("boom") }), -6);
    let text = String::from("formatted 42");
    assert_eq!(ffi_boundary("ring_test_string", None, || -> Option<u8> { panic!("{text}") }), None);
    assert!(ffi_boundary("ring_test_any", true, || -> bool { std::panic::panic_any(5_u32) }));
    std::panic::set_hook(hook);
    assert!(cmux_ffi_panic_count() - before >= 3);

    let mut mine = Vec::new();
    let mut out = CmuxFfiPanic::EMPTY;
    // SAFETY: a writable record.
    while unsafe { cmux_ffi_take_panic(&mut out) } == 1 {
        if out.name().starts_with("ring_test_") {
            mine.push((
                out.sequence,
                out.name().to_owned(),
                out.message().to_owned(),
                out.truncated,
            ));
        }
    }
    let shape: Vec<(&str, &str)> = mine.iter().map(|m| (m.1.as_str(), m.2.as_str())).collect();
    assert_eq!(
        shape,
        [
            ("ring_test_str", "boom"),
            ("ring_test_string", "formatted 42"),
            ("ring_test_any", "panic payload is not a string")
        ]
    );
    assert!(mine.windows(2).all(|w| w[0].0 < w[1].0));
    assert!(mine.iter().all(|m| !m.3));
    // SAFETY: NULL is allowed.
    assert_eq!(unsafe { cmux_ffi_take_panic(std::ptr::null_mut()) }, -1);
}

#[test]
fn records_come_out_oldest_first() {
    let ring = PanicRing::new();
    assert!(record_of(&ring).is_none());
    ring.record("a", "first");
    ring.record("b", "second");
    let first = record_of(&ring).expect("first");
    let second = record_of(&ring).expect("second");
    assert_eq!((first.sequence, first.name(), first.message()), (1, "a", "first"));
    assert_eq!((second.sequence, second.name(), second.message()), (2, "b", "second"));
    assert!(record_of(&ring).is_none());
    assert_eq!(ring.count(), 2);
}

#[test]
fn a_full_ring_keeps_the_newest_and_shows_the_gap() {
    let ring = PanicRing::new();
    let total = RING_SLOTS as u64 + 5;
    for n in 1..=total {
        ring.record("export", &format!("panic {n}"));
    }
    let mut sequences = Vec::new();
    while let Some(record) = record_of(&ring) {
        assert_eq!(record.message(), format!("panic {}", record.sequence));
        sequences.push(record.sequence);
    }
    let expected: Vec<u64> = (total - RING_SLOTS as u64 + 1..=total).collect();
    assert_eq!(sequences, expected);
    assert_eq!(ring.count(), total);
}

#[test]
fn long_text_is_cut_on_a_character_boundary() {
    let ring = PanicRing::new();
    let name = "n".repeat(NAME_CAP + 10);
    // 'é' is 2 bytes: MESSAGE_CAP - 1 ASCII bytes leave room for half of it only.
    let message = format!("{}é tail", "m".repeat(MESSAGE_CAP - 1));
    ring.record(&name, &message);
    let record = record_of(&ring).expect("record");
    assert_eq!(record.name().len(), NAME_CAP);
    assert_eq!(record.message(), "m".repeat(MESSAGE_CAP - 1));
    assert!(record.truncated);
}

#[test]
fn concurrent_panics_never_block_and_never_tear() {
    let ring = PanicRing::new();
    std::thread::scope(|scope| {
        for thread in 0..8 {
            let ring = &ring;
            scope.spawn(move || {
                for n in 0..200 {
                    ring.record("export", &format!("thread {thread} panic {n}"));
                }
            });
        }
        scope.spawn(|| {
            for _ in 0..400 {
                if let Some(record) = record_of(&ring) {
                    assert!(record.message().starts_with("thread "), "{}", record.message());
                }
            }
        });
    });
    while let Some(record) = record_of(&ring) {
        assert!(record.message().contains(" panic "), "{}", record.message());
    }
    assert_eq!(ring.count(), 1600);
}

#[test]
fn the_header_matches_the_rust_layout() {
    let header = include_str!("../include/cmux_ffi_guard.h");
    for (name, value) in
        [("CMUX_FFI_PANIC_NAME_CAP", NAME_CAP), ("CMUX_FFI_PANIC_MESSAGE_CAP", MESSAGE_CAP)]
    {
        assert!(header.contains(&format!("#define {name} {value}")), "{name} = {value}");
    }
    for function in ["cmux_ffi_take_panic(", "cmux_ffi_panic_count("] {
        assert!(header.contains(function), "{function}");
    }
    assert_eq!(std::mem::offset_of!(CmuxFfiPanic, name_len), 8);
    assert_eq!(std::mem::offset_of!(CmuxFfiPanic, message_len), 12);
    assert_eq!(std::mem::offset_of!(CmuxFfiPanic, truncated), 16);
    assert_eq!(std::mem::offset_of!(CmuxFfiPanic, name), 17);
    assert_eq!(std::mem::offset_of!(CmuxFfiPanic, message), 17 + NAME_CAP);
    assert_eq!(size_of::<CmuxFfiPanic>(), (17 + NAME_CAP + MESSAGE_CAP).next_multiple_of(8));
}

#[cfg(feature = "testing")]
#[test]
fn panic_through_reaches_the_boundary_of_the_export() {
    fn export() -> i32 {
        ffi_boundary("cmux_test_export", -4, || 0)
    }
    assert_eq!(export(), 0);
    let (code, name) = testing::panic_through(export);
    assert_eq!((code, name.as_deref()), (-4, Some("cmux_test_export")));
    assert_eq!(export(), 0, "only the next boundary panics");
    let (code, name) = testing::panic_through(|| 9);
    assert_eq!((code, name), (9, None));
}

#[cfg(feature = "testing")]
#[test]
fn unguarded_exports_names_each_bare_export() {
    let source = r#"
#[unsafe(no_mangle)]
pub extern "C" fn guarded(a: u32) -> u32 {
    ffi_boundary("guarded", 0, || { if a > 1 { a } else { 1 } })
}
pub extern "C" fn reasoned() -> u32 {
    // ffi-nopanic: a constant.
    3
}
pub unsafe extern "C" fn bare(p: *mut u8) -> i32 {
    if p.is_null() { return -1; }
    0
}
pub extern "C" fn $name(mirror: *mut Mirror) -> i32 {
    unsafe { helper(mirror) }
}
pub extern "C" fn $wrapped(mirror: *mut Mirror) -> i32 {
    ffi_boundary(stringify!($wrapped), -4, || unsafe { helper(mirror) })
}
pub extern "C" fn misnamed() -> i32 {
    ffi_boundary("other", -4, || 0)
}
fn helper() { ffi_boundary("helper", 0, || 0); }
"#;
    assert_eq!(testing::unguarded_exports(source), ["bare", "$name", "misnamed"]);
}
