use super::*;

#[derive(PartialEq, Eq, PartialOrd, Ord, Clone, Copy)]
struct Key {
    id: usize,
}

#[test]
fn packet_assembler_overlap() {
    let mut p_assembler = PacketAssembler::<Key>::new();

    p_assembler.set_total_size(5).unwrap();

    let data = b"Rust";
    p_assembler.add(&data[..], 0);
    p_assembler.add(&data[..], 1);

    assert_eq!(p_assembler.assemble(), Some(&b"RRust"[..]))
}

#[test]
fn packet_assembler_assemble() {
    let mut p_assembler = PacketAssembler::<Key>::new();

    let data = b"Hello World!";

    p_assembler.set_total_size(data.len()).unwrap();

    p_assembler.add(b"Hello ", 0).unwrap();
    assert_eq!(p_assembler.assemble(), None);

    p_assembler.add(b"World!", b"Hello ".len()).unwrap();

    assert_eq!(p_assembler.assemble(), Some(&b"Hello World!"[..]));
}

#[test]
fn packet_assembler_out_of_order_assemble() {
    let mut p_assembler = PacketAssembler::<Key>::new();

    let data = b"Hello World!";

    p_assembler.set_total_size(data.len()).unwrap();

    p_assembler.add(b"World!", b"Hello ".len()).unwrap();
    assert_eq!(p_assembler.assemble(), None);

    p_assembler.add(b"Hello ", 0).unwrap();

    assert_eq!(p_assembler.assemble(), Some(&b"Hello World!"[..]));
}

#[test]
fn packet_assembler_set() {
    let key = Key { id: 1 };

    let mut set = PacketAssemblerSet::new();

    assert!(set.get(&key, Instant::ZERO).is_ok());
}

#[test]
fn packet_assembler_set_full() {
    let mut set = PacketAssemblerSet::new();
    for i in 0..REASSEMBLY_BUFFER_COUNT {
        set.get(&Key { id: i }, Instant::ZERO).unwrap();
    }
    assert!(set.get(&Key { id: 4 }, Instant::ZERO).is_err());
}

#[test]
fn packet_assembler_set_assembling_many() {
    let mut set = PacketAssemblerSet::new();

    let key = Key { id: 0 };
    let assr = set.get(&key, Instant::ZERO).unwrap();
    assert_eq!(assr.assemble(), None);
    assr.set_total_size(0).unwrap();
    assr.assemble().unwrap();

    // Test that `.assemble()` effectively deletes it.
    let assr = set.get(&key, Instant::ZERO).unwrap();
    assert_eq!(assr.assemble(), None);
    assr.set_total_size(0).unwrap();
    assr.assemble().unwrap();

    let key = Key { id: 1 };
    let assr = set.get(&key, Instant::ZERO).unwrap();
    assr.set_total_size(0).unwrap();
    assr.assemble().unwrap();

    let key = Key { id: 2 };
    let assr = set.get(&key, Instant::ZERO).unwrap();
    assr.set_total_size(0).unwrap();
    assr.assemble().unwrap();

    let key = Key { id: 2 };
    let assr = set.get(&key, Instant::ZERO).unwrap();
    assr.set_total_size(2).unwrap();
    assr.add(&[0x00], 0).unwrap();
    assert_eq!(assr.assemble(), None);
    let assr = set.get(&key, Instant::ZERO).unwrap();
    assr.add(&[0x01], 1).unwrap();
    assert_eq!(assr.assemble(), Some(&[0x00, 0x01][..]));
}
