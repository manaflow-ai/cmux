#![cfg_attr(
    not(test),
    deny(
        clippy::expect_used,
        clippy::panic,
        clippy::todo,
        clippy::unimplemented,
        clippy::unwrap_used
    )
)]

use serde::{Deserialize, Serialize};
use tokio::io::{AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt};

pub const PROTOCOL_VERSION: u32 = 1;
pub const MAX_FRAME_BYTES: u32 = 16 * 1024 * 1024;

pub type ClientId = u64;
pub type WorkspaceId = u64;
pub type SpaceId = u64;
pub type PaneId = u64;
pub type TerminalId = u64;
pub type Seq = u64;

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub struct Viewport {
    pub cols: u16,
    pub rows: u16,
}

impl Viewport {
    #[must_use]
    pub fn clamp_min(self) -> Self {
        Self {
            cols: self.cols.max(1),
            rows: self.rows.max(1),
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Workspace {
    pub id: WorkspaceId,
    pub title: String,
    pub active_space_id: SpaceId,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Space {
    pub id: SpaceId,
    pub workspace_id: WorkspaceId,
    pub title: String,
    pub root_pane_id: PaneId,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Pane {
    pub id: PaneId,
    pub space_id: SpaceId,
    pub active_terminal_id: TerminalId,
    pub terminal_ids: Vec<TerminalId>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Terminal {
    pub id: TerminalId,
    pub pane_id: PaneId,
    pub title: String,
    pub size: Viewport,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub struct Focus {
    pub workspace_id: WorkspaceId,
    pub space_id: SpaceId,
    pub pane_id: PaneId,
    pub terminal_id: TerminalId,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Snapshot {
    pub seq: Seq,
    pub workspaces: Vec<Workspace>,
    pub spaces: Vec<Space>,
    pub panes: Vec<Pane>,
    pub terminals: Vec<Terminal>,
    pub focus: Focus,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum Delta {
    WorkspaceUpsert { seq: Seq, workspace: Workspace },
    SpaceUpsert { seq: Seq, space: Space },
    PaneUpsert { seq: Seq, pane: Pane },
    TerminalUpsert { seq: Seq, terminal: Terminal },
    FocusChanged { seq: Seq, focus: Focus },
}

impl Delta {
    #[must_use]
    pub fn seq(&self) -> Seq {
        match self {
            Self::WorkspaceUpsert { seq, .. }
            | Self::SpaceUpsert { seq, .. }
            | Self::PaneUpsert { seq, .. }
            | Self::TerminalUpsert { seq, .. }
            | Self::FocusChanged { seq, .. } => *seq,
        }
    }
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "name", rename_all = "kebab-case")]
pub enum Command {
    CreateWorkspace { title: String },
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum ClientMsg {
    Hello {
        version: u32,
        viewport: Viewport,
    },
    Command {
        id: u64,
        command: Command,
    },
    TerminalInput {
        terminal_id: TerminalId,
        input_seq: u64,
        #[serde(with = "serde_bytes")]
        data: Vec<u8>,
    },
    VisibleTerminals {
        terminals: Vec<VisibleTerminal>,
    },
    Ping {
        ping_id: u64,
        client_sent_monotonic_ns: u64,
    },
    Detach,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
pub struct VisibleTerminal {
    pub client_id: ClientId,
    pub terminal_id: TerminalId,
    pub cols: u16,
    pub rows: u16,
    pub visible: bool,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(tag = "kind", rename_all = "snake_case")]
pub enum ServerMsg {
    Welcome {
        client_id: ClientId,
        snapshot: Snapshot,
    },
    Delta {
        delta: Delta,
    },
    TerminalOutput {
        terminal_id: TerminalId,
        #[serde(with = "serde_bytes")]
        data: Vec<u8>,
    },
    CommandAck {
        id: u64,
        seq: Seq,
    },
    Pong {
        ping_id: u64,
        client_sent_monotonic_ns: u64,
        node_sent_monotonic_ns: u64,
    },
    Bye,
    Error {
        message: String,
    },
}

#[derive(Debug, thiserror::Error)]
pub enum CodecError {
    #[error("io error: {0}")]
    Io(#[from] std::io::Error),
    #[error("encode error: {0}")]
    Encode(#[from] rmp_serde::encode::Error),
    #[error("decode error: {0}")]
    Decode(#[from] rmp_serde::decode::Error),
    #[error("frame too large: {0} bytes")]
    FrameTooLarge(u32),
}

pub async fn write_msg<W, T>(writer: &mut W, msg: &T) -> Result<(), CodecError>
where
    W: AsyncWrite + Unpin,
    T: Serialize,
{
    let bytes = rmp_serde::to_vec_named(msg)?;
    let len = u32::try_from(bytes.len()).map_err(|_| CodecError::FrameTooLarge(u32::MAX))?;
    if len > MAX_FRAME_BYTES {
        return Err(CodecError::FrameTooLarge(len));
    }
    writer.write_u32(len).await?;
    writer.write_all(&bytes).await?;
    writer.flush().await?;
    Ok(())
}

pub async fn read_msg<R, T>(reader: &mut R) -> Result<Option<T>, CodecError>
where
    R: AsyncRead + Unpin,
    T: for<'de> Deserialize<'de>,
{
    let len = match reader.read_u32().await {
        Ok(len) => len,
        Err(err) if err.kind() == std::io::ErrorKind::UnexpectedEof => return Ok(None),
        Err(err) => return Err(err.into()),
    };
    if len > MAX_FRAME_BYTES {
        return Err(CodecError::FrameTooLarge(len));
    }
    let mut buf = vec![0; len as usize];
    reader.read_exact(&mut buf).await?;
    Ok(Some(rmp_serde::from_slice(&buf)?))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test]
    async fn messagepack_frame_round_trips_terminal_input() {
        let msg = ClientMsg::TerminalInput {
            terminal_id: 7,
            input_seq: 9,
            data: b"echo hi\n".to_vec(),
        };
        let (mut writer, mut reader) = tokio::io::duplex(1024);
        write_msg(&mut writer, &msg).await.expect("write");
        let decoded = read_msg::<_, ClientMsg>(&mut reader)
            .await
            .expect("read")
            .expect("message");
        assert_eq!(decoded, msg);
    }
}
