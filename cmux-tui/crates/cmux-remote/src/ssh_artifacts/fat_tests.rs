//! Reading this client's own Mach-O header: a short or malformed file means
//! no matching build, never a panic.

use std::io::Write as _;

use super::*;

fn architecture(bytes: &[u8], arch: &str) -> Option<(bool, u64, u64)> {
    let mut file = tempfile::NamedTempFile::new().unwrap();
    file.write_all(bytes).unwrap();
    client_architecture(file.path(), arch).unwrap().map(|found| match found {
        ClientArchitecture::Whole => (true, 0, 0),
        ClientArchitecture::Slice { offset, size } => (false, offset, size),
    })
}

fn fat(entries: &[(u32, u64, u64)], wide: bool) -> Vec<u8> {
    let magic = if wide { FAT_MAGIC_64 } else { FAT_MAGIC };
    let mut bytes = magic.to_be_bytes().to_vec();
    bytes.extend_from_slice(&u32::try_from(entries.len()).unwrap().to_be_bytes());
    for (cpu, offset, size) in entries {
        bytes.extend_from_slice(&cpu.to_be_bytes());
        bytes.extend_from_slice(&0_u32.to_be_bytes());
        if wide {
            bytes.extend_from_slice(&offset.to_be_bytes());
            bytes.extend_from_slice(&size.to_be_bytes());
            bytes.extend_from_slice(&[0; 8]);
        } else {
            bytes.extend_from_slice(&u32::try_from(*offset).unwrap().to_be_bytes());
            bytes.extend_from_slice(&u32::try_from(*size).unwrap().to_be_bytes());
            bytes.extend_from_slice(&[0; 4]);
        }
    }
    bytes.resize(256, 0);
    bytes
}

#[test]
fn a_thin_binary_matches_its_own_cpu() {
    let mut thin = MH_MAGIC_64.to_le_bytes().to_vec();
    thin.extend_from_slice(&CPU_TYPE_ARM64.to_le_bytes());
    assert_eq!(architecture(&thin, "aarch64"), Some((true, 0, 0)));
    assert_eq!(architecture(&thin, "x86_64"), None);
}

#[test]
fn fat_binaries_find_the_slice_for_the_cpu() {
    for wide in [false, true] {
        let bytes = fat(&[(CPU_TYPE_X86_64, 64, 32), (CPU_TYPE_ARM64, 128, 64)], wide);
        assert_eq!(architecture(&bytes, "aarch64"), Some((false, 128, 64)), "wide {wide}");
        assert_eq!(architecture(&bytes, "x86_64"), Some((false, 64, 32)), "wide {wide}");
    }
}

#[test]
fn a_slice_outside_the_file_does_not_match() {
    let bytes = fat(&[(CPU_TYPE_ARM64, 200, 100)], false);
    assert_eq!(architecture(&bytes, "aarch64"), None);
}

#[test]
fn short_and_unknown_headers_do_not_match() {
    assert_eq!(architecture(b"", "aarch64"), None);
    assert_eq!(architecture(&FAT_MAGIC.to_be_bytes(), "aarch64"), None);
    assert_eq!(architecture(&[0xff; 64], "aarch64"), None);
    let mut truncated = fat(&[(CPU_TYPE_ARM64, 64, 32)], true);
    truncated.truncate(8 + 16);
    assert_eq!(architecture(&truncated, "aarch64"), None);
    assert_eq!(architecture(&fat(&[(CPU_TYPE_ARM64, 64, 32)], false), "riscv64"), None);
}
