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

use std::path::Path;

use anyhow::{Context, Result, anyhow};
use comeup_protocol::{
    ClientAuth, ClientId, ClientMsg, PROTOCOL_VERSION, ServerMsg, Snapshot, Viewport, read_msg,
    write_msg,
};
use tokio::io::BufReader;
use tokio::net::UnixStream;
use tokio::net::unix::{OwnedReadHalf, OwnedWriteHalf};

pub struct UnixClient {
    client_id: ClientId,
    snapshot: Snapshot,
    reader: BufReader<OwnedReadHalf>,
    writer: OwnedWriteHalf,
}

impl UnixClient {
    pub async fn connect(socket_path: impl AsRef<Path>, viewport: Viewport) -> Result<Self> {
        Self::connect_with_auth(socket_path, viewport, None).await
    }

    pub async fn connect_with_auth(
        socket_path: impl AsRef<Path>,
        viewport: Viewport,
        auth: Option<ClientAuth>,
    ) -> Result<Self> {
        let stream = UnixStream::connect(socket_path.as_ref())
            .await
            .with_context(|| format!("connect {}", socket_path.as_ref().display()))?;
        let (read_half, mut writer) = stream.into_split();
        let mut reader = BufReader::new(read_half);

        write_msg(
            &mut writer,
            &ClientMsg::Hello {
                version: PROTOCOL_VERSION,
                viewport,
                auth,
            },
        )
        .await
        .context("send hello")?;

        let Some(msg) = read_msg::<_, ServerMsg>(&mut reader)
            .await
            .context("read welcome")?
        else {
            return Err(anyhow!("comeup server closed before welcome"));
        };

        let ServerMsg::Welcome {
            client_id,
            snapshot,
        } = msg
        else {
            return Err(anyhow!("expected welcome, got {msg:?}"));
        };

        Ok(Self {
            client_id,
            snapshot,
            reader,
            writer,
        })
    }

    #[must_use]
    pub fn client_id(&self) -> ClientId {
        self.client_id
    }

    #[must_use]
    pub fn snapshot(&self) -> &Snapshot {
        &self.snapshot
    }

    pub async fn send(&mut self, msg: &ClientMsg) -> Result<()> {
        write_msg(&mut self.writer, msg)
            .await
            .context("send client message")
    }

    pub async fn recv(&mut self) -> Result<Option<ServerMsg>> {
        read_msg(&mut self.reader)
            .await
            .context("read server message")
    }
}
