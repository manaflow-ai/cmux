//! SFTP version 3 packets (draft-ietf-secsh-filexfer-02), the version
//! OpenSSH's `sftp-server` speaks.

use bytes::{Buf as _, BufMut as _, Bytes, BytesMut};

pub const SSH_FXP_INIT: u8 = 1;
pub const SSH_FXP_VERSION: u8 = 2;
pub const SSH_FXP_OPEN: u8 = 3;
pub const SSH_FXP_CLOSE: u8 = 4;
pub const SSH_FXP_READ: u8 = 5;
pub const SSH_FXP_WRITE: u8 = 6;
pub const SSH_FXP_LSTAT: u8 = 7;
pub const SSH_FXP_FSTAT: u8 = 8;
pub const SSH_FXP_OPENDIR: u8 = 11;
pub const SSH_FXP_READDIR: u8 = 12;
pub const SSH_FXP_REMOVE: u8 = 13;
pub const SSH_FXP_MKDIR: u8 = 14;
pub const SSH_FXP_RMDIR: u8 = 15;
pub const SSH_FXP_REALPATH: u8 = 16;
pub const SSH_FXP_STAT: u8 = 17;
pub const SSH_FXP_RENAME: u8 = 18;
pub const SSH_FXP_STATUS: u8 = 101;
pub const SSH_FXP_HANDLE: u8 = 102;
pub const SSH_FXP_DATA: u8 = 103;
pub const SSH_FXP_NAME: u8 = 104;
pub const SSH_FXP_ATTRS: u8 = 105;
pub const SSH_FXP_EXTENDED: u8 = 200;
pub const SSH_FXP_EXTENDED_REPLY: u8 = 201;

pub const SSH_FXF_READ: u32 = 0x01;
pub const SSH_FXF_WRITE: u32 = 0x02;
pub const SSH_FXF_CREAT: u32 = 0x08;
pub const SSH_FXF_TRUNC: u32 = 0x10;
pub const SSH_FXF_EXCL: u32 = 0x20;

const ATTR_SIZE: u32 = 0x01;
const ATTR_UIDGID: u32 = 0x02;
const ATTR_PERMISSIONS: u32 = 0x04;
const ATTR_ACMODTIME: u32 = 0x08;
const ATTR_EXTENDED: u32 = 0x8000_0000;

/// Largest packet the client accepts: OpenSSH's own limit (256 KiB) plus
/// headroom for headers.
pub const MAX_PACKET_BYTES: usize = 256 * 1024 + 1024;

/// SFTP status codes.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum StatusCode {
    Ok,
    Eof,
    NoSuchFile,
    PermissionDenied,
    Failure,
    BadMessage,
    NoConnection,
    ConnectionLost,
    OpUnsupported,
    Other(u32),
}

impl From<u32> for StatusCode {
    fn from(code: u32) -> Self {
        match code {
            0 => Self::Ok,
            1 => Self::Eof,
            2 => Self::NoSuchFile,
            3 => Self::PermissionDenied,
            4 => Self::Failure,
            5 => Self::BadMessage,
            6 => Self::NoConnection,
            7 => Self::ConnectionLost,
            8 => Self::OpUnsupported,
            other => Self::Other(other),
        }
    }
}

/// File attributes. Every field is optional on the wire.
#[derive(Clone, Debug, Default, PartialEq, Eq)]
pub struct Attrs {
    pub size: Option<u64>,
    pub uid_gid: Option<(u32, u32)>,
    pub permissions: Option<u32>,
    /// Access and modification time, seconds since the epoch.
    pub atime_mtime: Option<(u32, u32)>,
}

const S_IFMT: u32 = 0o170_000;
const S_IFDIR: u32 = 0o040_000;
const S_IFREG: u32 = 0o100_000;
const S_IFLNK: u32 = 0o120_000;

/// What kind of file the permission bits describe.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum FileType {
    File,
    Dir,
    Symlink,
    Other,
}

impl Attrs {
    #[must_use]
    pub fn file_type(&self) -> FileType {
        match self.permissions.map(|mode| mode & S_IFMT) {
            Some(S_IFDIR) => FileType::Dir,
            Some(S_IFREG) => FileType::File,
            Some(S_IFLNK) => FileType::Symlink,
            _ => FileType::Other,
        }
    }

    #[must_use]
    pub fn mtime(&self) -> Option<u32> {
        self.atime_mtime.map(|(_, mtime)| mtime)
    }

    /// Attributes carrying only permission bits, for open and mkdir.
    #[must_use]
    pub fn with_permissions(mode: u32) -> Self {
        Self { permissions: Some(mode), ..Self::default() }
    }

    fn encode(&self, buffer: &mut BytesMut) {
        let mut flags = 0;
        if self.size.is_some() {
            flags |= ATTR_SIZE;
        }
        if self.uid_gid.is_some() {
            flags |= ATTR_UIDGID;
        }
        if self.permissions.is_some() {
            flags |= ATTR_PERMISSIONS;
        }
        if self.atime_mtime.is_some() {
            flags |= ATTR_ACMODTIME;
        }
        buffer.put_u32(flags);
        if let Some(size) = self.size {
            buffer.put_u64(size);
        }
        if let Some((uid, gid)) = self.uid_gid {
            buffer.put_u32(uid);
            buffer.put_u32(gid);
        }
        if let Some(permissions) = self.permissions {
            buffer.put_u32(permissions);
        }
        if let Some((atime, mtime)) = self.atime_mtime {
            buffer.put_u32(atime);
            buffer.put_u32(mtime);
        }
    }

    fn decode(reader: &mut Reader) -> Result<Self, DecodeError> {
        let flags = reader.u32()?;
        let mut attrs = Self::default();
        if flags & ATTR_SIZE != 0 {
            attrs.size = Some(reader.u64()?);
        }
        if flags & ATTR_UIDGID != 0 {
            attrs.uid_gid = Some((reader.u32()?, reader.u32()?));
        }
        if flags & ATTR_PERMISSIONS != 0 {
            attrs.permissions = Some(reader.u32()?);
        }
        if flags & ATTR_ACMODTIME != 0 {
            attrs.atime_mtime = Some((reader.u32()?, reader.u32()?));
        }
        if flags & ATTR_EXTENDED != 0 {
            for _ in 0..reader.u32()? {
                reader.string()?;
                reader.string()?;
            }
        }
        Ok(attrs)
    }
}

/// One entry of a NAME reply.
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct NameEntry {
    pub filename: Bytes,
    pub longname: Bytes,
    pub attrs: Attrs,
}

/// A reply from the server.
#[derive(Clone, Debug, PartialEq, Eq)]
pub enum Response {
    Status { code: StatusCode, message: String },
    Handle(Bytes),
    Data(Bytes),
    Name(Vec<NameEntry>),
    Attrs(Attrs),
    ExtendedReply(Bytes),
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum DecodeError {
    Truncated,
    TooLarge(usize),
    UnexpectedType(u8),
}

impl std::fmt::Display for DecodeError {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Truncated => formatter.write_str("SFTP packet is truncated"),
            Self::TooLarge(size) => write!(formatter, "SFTP packet of {size} bytes is too large"),
            Self::UnexpectedType(kind) => write!(formatter, "unexpected SFTP packet type {kind}"),
        }
    }
}

impl std::error::Error for DecodeError {}

/// Bounds-checked reader over one packet body.
pub struct Reader {
    bytes: Bytes,
}

impl Reader {
    #[must_use]
    pub fn new(bytes: Bytes) -> Self {
        Self { bytes }
    }

    pub fn u8(&mut self) -> Result<u8, DecodeError> {
        if self.bytes.remaining() < 1 {
            return Err(DecodeError::Truncated);
        }
        Ok(self.bytes.get_u8())
    }

    pub fn u32(&mut self) -> Result<u32, DecodeError> {
        if self.bytes.remaining() < 4 {
            return Err(DecodeError::Truncated);
        }
        Ok(self.bytes.get_u32())
    }

    pub fn u64(&mut self) -> Result<u64, DecodeError> {
        if self.bytes.remaining() < 8 {
            return Err(DecodeError::Truncated);
        }
        Ok(self.bytes.get_u64())
    }

    pub fn string(&mut self) -> Result<Bytes, DecodeError> {
        let length = usize::try_from(self.u32()?).map_err(|_| DecodeError::Truncated)?;
        if self.bytes.remaining() < length {
            return Err(DecodeError::Truncated);
        }
        Ok(self.bytes.split_to(length))
    }

    #[must_use]
    pub fn is_empty(&self) -> bool {
        self.bytes.is_empty()
    }
}

/// Builds one request packet: length, type, request id, then the fields
/// the caller writes.
pub struct PacketBuilder {
    buffer: BytesMut,
}

impl PacketBuilder {
    #[must_use]
    pub fn new(kind: u8, request_id: Option<u32>) -> Self {
        let mut buffer = BytesMut::with_capacity(64);
        buffer.put_u32(0);
        buffer.put_u8(kind);
        if let Some(id) = request_id {
            buffer.put_u32(id);
        }
        Self { buffer }
    }

    #[must_use]
    pub fn u32(mut self, value: u32) -> Self {
        self.buffer.put_u32(value);
        self
    }

    #[must_use]
    pub fn u64(mut self, value: u64) -> Self {
        self.buffer.put_u64(value);
        self
    }

    #[must_use]
    pub fn string(mut self, value: &[u8]) -> Self {
        let length = u32::try_from(value.len()).expect("SFTP strings are below 4 GiB");
        self.buffer.put_u32(length);
        self.buffer.put_slice(value);
        self
    }

    #[must_use]
    pub fn attrs(mut self, attrs: &Attrs) -> Self {
        attrs.encode(&mut self.buffer);
        self
    }

    #[must_use]
    pub fn finish(mut self) -> Bytes {
        let length = u32::try_from(self.buffer.len() - 4).expect("SFTP packets are below 4 GiB");
        self.buffer[..4].copy_from_slice(&length.to_be_bytes());
        self.buffer.freeze()
    }
}

/// Decodes the VERSION reply: the version and the extension names.
pub fn decode_version(body: Bytes) -> Result<(u32, Vec<String>), DecodeError> {
    let mut reader = Reader::new(body);
    let kind = reader.u8()?;
    if kind != SSH_FXP_VERSION {
        return Err(DecodeError::UnexpectedType(kind));
    }
    let version = reader.u32()?;
    let mut extensions = Vec::new();
    while !reader.is_empty() {
        let name = reader.string()?;
        reader.string()?;
        extensions.push(String::from_utf8_lossy(&name).into_owned());
    }
    Ok((version, extensions))
}

/// Decodes one reply body (after the length): its request id and content.
pub fn decode_response(body: Bytes) -> Result<(u32, Response), DecodeError> {
    let mut reader = Reader::new(body);
    let kind = reader.u8()?;
    let id = reader.u32()?;
    let response = match kind {
        SSH_FXP_STATUS => {
            let code = StatusCode::from(reader.u32()?);
            // Version 3 servers may omit the message and language tag.
            let message = if reader.is_empty() {
                String::new()
            } else {
                String::from_utf8_lossy(&reader.string()?).into_owned()
            };
            Response::Status { code, message }
        }
        SSH_FXP_HANDLE => Response::Handle(reader.string()?),
        SSH_FXP_DATA => Response::Data(reader.string()?),
        SSH_FXP_NAME => {
            let count = reader.u32()?;
            let mut entries = Vec::new();
            for _ in 0..count {
                entries.push(NameEntry {
                    filename: reader.string()?,
                    longname: reader.string()?,
                    attrs: Attrs::decode(&mut reader)?,
                });
            }
            Response::Name(entries)
        }
        SSH_FXP_ATTRS => Response::Attrs(Attrs::decode(&mut reader)?),
        SSH_FXP_EXTENDED_REPLY => {
            let rest = reader.bytes.split_off(0);
            Response::ExtendedReply(rest)
        }
        other => return Err(DecodeError::UnexpectedType(other)),
    };
    Ok((id, response))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn packets_round_trip_through_the_decoder() {
        let attrs = Attrs {
            size: Some(5),
            uid_gid: Some((1, 2)),
            permissions: Some(0o100_644),
            atime_mtime: Some((3, 4)),
        };
        let packet = PacketBuilder::new(SSH_FXP_NAME, Some(9))
            .u32(1)
            .string(b"a.txt")
            .string(b"-rw-r--r-- a.txt")
            .attrs(&attrs)
            .finish();
        assert_eq!(u32::from_be_bytes(packet[..4].try_into().unwrap()) as usize, packet.len() - 4);
        let (id, response) = decode_response(packet.slice(4..)).unwrap();
        assert_eq!(id, 9);
        let Response::Name(entries) = response else { panic!("{response:?}") };
        assert_eq!(entries[0].filename, Bytes::from_static(b"a.txt"));
        assert_eq!(entries[0].attrs, attrs);
        assert_eq!(entries[0].attrs.file_type(), FileType::File);
    }

    #[test]
    fn truncated_and_unknown_packets_are_errors() {
        let packet = PacketBuilder::new(SSH_FXP_HANDLE, Some(1)).u32(10).finish();
        assert_eq!(decode_response(packet.slice(4..)), Err(DecodeError::Truncated));
        let packet = PacketBuilder::new(99, Some(1)).finish();
        assert_eq!(decode_response(packet.slice(4..)), Err(DecodeError::UnexpectedType(99)));
        let status = PacketBuilder::new(SSH_FXP_STATUS, Some(2)).u32(2).finish();
        assert_eq!(
            decode_response(status.slice(4..)).unwrap().1,
            Response::Status { code: StatusCode::NoSuchFile, message: String::new() }
        );
    }
}
