//! PDFs a prompt sends to an agent without a `document` block, saved in the chat's project
//! folder (moved from `turns.rs`).

use super::super::*;
use super::pdf_attachments_root;
use std::path::{Path, PathBuf};

/// Session `id`'s folder of PDFs under `root` (`<cwd>/.cmux/attachments`); none for an id that is
/// not one plain path component.
fn pdf_attachments_dir(root: &Path, id: &str) -> Option<PathBuf> {
    let plain =
        !id.is_empty() && id.bytes().all(|b| b.is_ascii_alphanumeric() || b == b'-' || b == b'_');
    plain.then(|| root.join(id))
}

/// Deletes the PDFs session `id` saved in its project (`acp_prompt_blocks`): the chat was
/// deleted. They were never removed, so every PDF sent to a deleted chat stayed in the project.
/// Never follows a symlink (`remove_dir_all` removes the link). Blocking: run it off the runtime.
pub(in crate::hub) fn remove_pdf_attachments(cwd: &Path, id: &str) {
    let Some(dir) = pdf_attachments_dir(&pdf_attachments_root(cwd), id) else {
        return;
    };
    match crate::home_fs::remove_dir_all(&dir) {
        Ok(()) => {}
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => {}
        Err(e) => tracing::warn!(session = id, "PDF attachments not deleted: {e}"),
    }
}

/// ACP v1 does not define a `document` content block. Claude's translator can
/// turn our internal document block into Anthropic's native document. Strict
/// ACP adapters (including Codex) instead get a stable workspace file and a
/// resource link, plus a short note telling the agent where to open it.
pub(in crate::hub) fn acp_prompt_blocks(
    session: &Session,
    blocks: &[Value],
) -> Result<Vec<Value>, RpcError> {
    let is_claude = session.meta().family.as_deref() == Some("claude");
    let mut out = Vec::with_capacity(blocks.len());
    for block in blocks {
        if block.get("type").and_then(Value::as_str) != Some("document") || is_claude {
            out.push(block.clone());
            continue;
        }
        let name = block.get("name").and_then(Value::as_str).unwrap_or("document.pdf");
        let safe_name: String = name
            .chars()
            .map(
                |c| if c.is_ascii_alphanumeric() || matches!(c, '.' | '-' | '_') { c } else { '_' },
            )
            .collect();
        let safe_name = if safe_name.is_empty() { "document.pdf" } else { &safe_name };
        let root = pdf_attachments_root(&session.meta().cwd);
        // The chat's own folder, so deleting the chat deletes its PDFs (`remove_pdf_attachments`).
        let dir = pdf_attachments_dir(&root, &session.id).ok_or_else(|| {
            RpcError::internal("cannot create PDF attachment directory: bad session id")
        })?;
        crate::home_fs::create_dirs(&dir).map_err(|e| {
            RpcError::internal(format!("cannot create PDF attachment directory: {e}"))
        })?;
        // The folder sits in the user's project; keep it out of their commits.
        let ignore = root.join(".gitignore");
        if !ignore.exists() {
            let _ = crate::home_fs::write(&ignore, "*\n");
        }
        let path = dir.join(format!("{}-{safe_name}", uuid::Uuid::now_v7()));
        let encoded = block.get("data").and_then(Value::as_str).unwrap_or("");
        use base64::Engine;
        let bytes = base64::engine::general_purpose::STANDARD
            .decode(encoded)
            .map_err(|e| RpcError::invalid_params(format!("invalid PDF attachment: {e}")))?;
        crate::home_fs::write(&path, bytes)
            .map_err(|e| RpcError::internal(format!("cannot save PDF attachment: {e}")))?;
        let uri = file_uri(&path);
        out.push(json!({
            "type": "text",
            "text": format!("PDF attachment saved at {}; open it with your tools.", path.display())
        }));
        out.push(json!({
            "type": "resource_link",
            "uri": uri,
            "name": name,
            "mimeType": "application/pdf"
        }));
    }
    Ok(out)
}

/// A `file://` URI for the saved file, percent-encoded so a project folder with
/// spaces or non-ASCII letters still names a valid link (and a Windows path
/// gets its drive form).
fn file_uri(path: &std::path::Path) -> String {
    reqwest::Url::from_file_path(path)
        .map(String::from)
        .unwrap_or_else(|()| format!("file://{}", path.display()))
}
