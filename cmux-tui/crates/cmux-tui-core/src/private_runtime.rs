//! Shared fencing and retained-byte accounting for connection-private runtimes.

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) struct ConnectionPrivateOwner {
    pub client_uuid: uuid::Uuid,
    pub process_instance_uuid: uuid::Uuid,
    pub connection_id: u64,
}

pub(crate) fn retained_bytes_after_replacing(
    retained_bytes: usize,
    replaced_bytes: usize,
    replacement_bytes: usize,
    maximum_bytes: usize,
    description: &str,
) -> anyhow::Result<usize> {
    let retained_bytes = retained_bytes
        .checked_sub(replaced_bytes)
        .and_then(|bytes| bytes.checked_add(replacement_bytes))
        .ok_or_else(|| anyhow::anyhow!("{description} retained source accounting overflow"))?;
    if retained_bytes > maximum_bytes {
        anyhow::bail!("{description} retained sources exceed {maximum_bytes} bytes");
    }
    Ok(retained_bytes)
}

pub(crate) fn validate_private_request_id(
    request_id: uuid::Uuid,
    description: &str,
) -> anyhow::Result<()> {
    if request_id.is_nil() {
        anyhow::bail!("{description} request_id must be nonzero");
    }
    Ok(())
}
