//! The task that runs a [`crate::WgMesh`]. Not implemented yet.

use tokio::net::UdpSocket;
use tokio::sync::mpsc;
use tokio::task::JoinHandle;

use crate::error::WgError;
use crate::mesh::{MeshCommand, WgMeshConfig};

pub(crate) fn spawn(
    _config: WgMeshConfig,
    _socket: UdpSocket,
    _commands: mpsc::Receiver<MeshCommand>,
) -> Result<JoinHandle<()>, WgError> {
    Err(WgError::Stack("the mesh engine is not implemented yet".into()))
}
