use super::*;

pub(super) struct ImagePasteRequest {
    pub surface: SurfaceId,
    pub terminal_id: String,
    pub lease: String,
    pub upload_id: String,
    pub op: String,
    pub mime: Option<String>,
    pub size: Option<usize>,
    pub offset: Option<usize>,
    pub data: Option<String>,
}

impl ImagePasteRequest {
    #[cfg(unix)]
    pub(super) fn handle(self, mux: &Arc<Mux>, client: u64) -> anyhow::Result<Value> {
        let Self { surface: surface_id, terminal_id, lease, upload_id, .. } = self;
        // This is the same authenticated mux client and lease used by the native
        // terminal attachment. Fence detach/replacement through the shared lifecycle.
        let _lifecycle = mux.lock_client_sizing_lifecycle();
        let stream = mux
            .control_clients
            .view_stream(client, surface_id, &lease)
            .map_err(|_| anyhow::anyhow!("image-link-unavailable"))?;
        anyhow::ensure!(stream.is_some(), "image-link-unavailable");
        let surface =
            mux.surface(surface_id).ok_or_else(|| anyhow::anyhow!("image-link-unavailable"))?;
        anyhow::ensure!(
            surface.kind() == SurfaceKind::Pty && surface.terminal_exit().is_none(),
            "image-link-unavailable"
        );
        anyhow::ensure!(
            surface.terminal_public_id().is_some_and(|id| id.as_str() == terminal_id),
            "image-owner-mismatch"
        );
        let resolved = mux
            .resolve_terminal(&terminal_id)
            .map_err(|_| anyhow::anyhow!("image-link-unavailable"))?
            .ok_or_else(|| anyhow::anyhow!("image-link-unavailable"))?;
        // A terminal can have several leased views. Its representative placement
        // is not an authorization boundary; the requested view's public identity
        // and current connection-owned lease were checked above.
        let owner = crate::image_paste::ImagePasteOwner {
            client,
            surface: surface_id,
            terminal: terminal_id,
            workspace: resolved.terminal.workspace_key,
            lease,
        };
        match (self.op.as_str(), self.mime, self.size, self.offset, self.data) {
            ("begin", Some(mime), Some(size), None, None) => {
                mux.image_pastes.begin(owner, &upload_id, &mime, size)?;
            }
            ("chunk", None, None, Some(offset), Some(data)) => {
                mux.image_pastes.append(&owner, &upload_id, offset, &data)?;
            }
            ("commit", None, None, None, None) => {
                mux.image_pastes
                    .commit(&owner, &upload_id, |path| surface.write_paste(path.as_bytes()))?;
            }
            ("cancel", None, None, None, None) => mux.image_pastes.cancel(&owner, &upload_id)?,
            _ => anyhow::bail!("image-invalid-request"),
        }
        Ok(json!({ "accepted": true }))
    }

    #[cfg(not(unix))]
    pub(super) fn handle(self, _mux: &Arc<Mux>, _client: u64) -> anyhow::Result<Value> {
        let Self { surface, terminal_id, lease, upload_id, op, mime, size, offset, data } = self;
        let _ = (surface, terminal_id, lease, upload_id, op, mime, size, offset, data);
        anyhow::bail!("image-unsupported")
    }
}
