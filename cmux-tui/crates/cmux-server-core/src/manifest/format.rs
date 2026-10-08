//! Package archive format (decision SV-R3): store packages are gzip
//! compressed tar archives only; CI wraps a single binary in one. The I/O
//! crate sniffs the first bytes of every verified download and unpacks
//! only [`PackageFormat::TarGz`]; everything else is refused by name.

/// Bytes [`PackageFormat::sniff`] reads: a plain tar is recognized by the
/// `ustar` magic at offset 257.
pub const FORMAT_SNIFF_LEN: usize = 262;

/// Mach-O magics: 32 and 64 bit in both byte orders, and universal.
const MACH_O: [[u8; 4]; 5] = [
    [0xfe, 0xed, 0xfa, 0xce],
    [0xfe, 0xed, 0xfa, 0xcf],
    [0xce, 0xfa, 0xed, 0xfe],
    [0xcf, 0xfa, 0xed, 0xfe],
    [0xca, 0xfe, 0xba, 0xbe],
];

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum PackageFormat {
    /// gzip (the tar inside is checked while unpacking).
    TarGz,
    /// An uncompressed tar.
    Tar,
    Zip,
    Xz,
    Zstd,
    Bzip2,
    /// A bare ELF executable.
    Elf,
    /// A bare Mach-O executable (thin or universal).
    MachO,
    /// A bare Windows executable.
    Pe,
    Unknown,
}

impl PackageFormat {
    /// The format of an archive from its first bytes (up to
    /// [`FORMAT_SNIFF_LEN`]).
    pub fn sniff(head: &[u8]) -> PackageFormat {
        let starts = |magic: &[u8]| head.starts_with(magic);
        if starts(&[0x1f, 0x8b]) {
            PackageFormat::TarGz
        } else if starts(b"PK\x03\x04") || starts(b"PK\x05\x06") {
            PackageFormat::Zip
        } else if starts(&[0xfd, b'7', b'z', b'X', b'Z', 0x00]) {
            PackageFormat::Xz
        } else if starts(&[0x28, 0xb5, 0x2f, 0xfd]) {
            PackageFormat::Zstd
        } else if starts(b"BZh") {
            PackageFormat::Bzip2
        } else if starts(b"\x7fELF") {
            PackageFormat::Elf
        } else if MACH_O.iter().any(|m| starts(m)) {
            PackageFormat::MachO
        } else if starts(b"MZ") {
            PackageFormat::Pe
        } else if head.len() >= FORMAT_SNIFF_LEN && &head[257..262] == b"ustar" {
            PackageFormat::Tar
        } else {
            PackageFormat::Unknown
        }
    }

    /// A name for error messages.
    pub fn describe(self) -> &'static str {
        match self {
            PackageFormat::TarGz => "a tar.gz archive",
            PackageFormat::Tar => "an uncompressed tar archive",
            PackageFormat::Zip => "a zip archive",
            PackageFormat::Xz => "an xz stream",
            PackageFormat::Zstd => "a zstd stream",
            PackageFormat::Bzip2 => "a bzip2 stream",
            PackageFormat::Elf => "a bare ELF binary",
            PackageFormat::MachO => "a bare Mach-O binary",
            PackageFormat::Pe => "a bare Windows executable",
            PackageFormat::Unknown => "an unknown format",
        }
    }

    /// `Ok` for the only accepted format; else the refusal text.
    pub fn require_tar_gz(self) -> Result<(), String> {
        match self {
            PackageFormat::TarGz => Ok(()),
            other => Err(format!(
                "store packages are tar.gz only (a single binary is wrapped in one); this is {}",
                other.describe()
            )),
        }
    }
}

#[cfg(test)]
mod tests {
    use super::PackageFormat::{self, *};

    #[test]
    fn sniffs_every_named_format_and_accepts_only_tar_gz() {
        let mut tar = vec![0u8; 512];
        tar[257..262].copy_from_slice(b"ustar");
        let cases: [(&[u8], PackageFormat); 11] = [
            (&[0x1f, 0x8b, 8, 0], TarGz),
            (&tar, Tar),
            (b"PK\x03\x04rest", Zip),
            (&[0xfd, b'7', b'z', b'X', b'Z', 0, 1], Xz),
            (&[0x28, 0xb5, 0x2f, 0xfd, 0], Zstd),
            (b"BZh91AY", Bzip2),
            (b"\x7fELF\x02\x01", Elf),
            (&[0xcf, 0xfa, 0xed, 0xfe, 7], MachO),
            (&[0xca, 0xfe, 0xba, 0xbe, 0], MachO),
            (b"MZ\x90\x00", Pe),
            (b"#!/bin/sh\n", Unknown),
        ];
        for (head, want) in cases {
            assert_eq!(PackageFormat::sniff(head), want, "{head:?}");
            assert_eq!(want.require_tar_gz().is_ok(), want == TarGz);
        }
        assert_eq!(PackageFormat::sniff(&[]), Unknown);
        assert_eq!(PackageFormat::sniff(&[0x1f]), Unknown);
        let message = Elf.require_tar_gz().unwrap_err();
        assert!(message.contains("tar.gz only") && message.contains("ELF"), "{message}");
    }
}
