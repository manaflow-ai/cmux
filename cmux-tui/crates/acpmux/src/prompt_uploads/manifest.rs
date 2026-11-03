//! File lists too large for a frame stay complete in an owner-only JSONL file.
//! The queue, transcript and agent carry one authenticated reference. Each row
//! keeps the original block index and its validated display metadata; readers
//! page by byte offset, so reading the list is linear and uses bounded memory.

use super::*;
use crate::hub::file_uploads;
use std::collections::HashMap;
use std::fs::File;
use std::io::{BufRead, BufReader, BufWriter, Seek, SeekFrom, Write};
use std::path::PathBuf;

const MARKER: &str = ".manifest-proof";
const FIELD: &str = "/_meta/acpmux/uploadManifest";

pub(crate) fn is_manifest(block: &Value) -> bool {
    block.pointer(FIELD).is_some()
}

fn invalid() -> RpcError {
    refused("upload.remote", "the attachment manifest does not belong to this chat".into())
}

fn io(error: impl std::fmt::Display) -> RpcError {
    refused("upload.unreadable", format!("cannot read or save the attachment manifest: {error}"))
}

/// Opens a daemon-issued manifest. Local forks may retain their parent's link;
/// Web can read only a manifest minted under Web control for this same session.
fn open(session: &str, web: bool, block: &Value) -> Result<(File, PathBuf), RpcError> {
    let _held = file_uploads::IN_USE.lock().unwrap_or_else(std::sync::PoisonError::into_inner);
    let reference = block.pointer(FIELD).ok_or_else(invalid)?;
    let id = reference.get("uploadId").and_then(Value::as_str).ok_or_else(invalid)?;
    let name = reference.get("fileName").and_then(Value::as_str).ok_or_else(invalid)?;
    let proof = reference.get("proof").and_then(Value::as_str).ok_or_else(invalid)?;
    let claimed = block
        .pointer("/_meta/acpmux/uploadPath")
        .and_then(Value::as_str)
        .map(Path::new)
        .ok_or_else(invalid)?;
    let owner = claimed
        .parent()
        .and_then(Path::parent)
        .and_then(Path::file_name)
        .and_then(|name| name.to_str())
        .ok_or_else(invalid)?;
    // A local fork retains its parent's resolved file links, just as ordinary
    // uploadPath blocks do. Web never inherits that local filesystem authority.
    if web && owner != session {
        return Err(invalid());
    }
    let path = file_uploads::finished_path(owner, id, name).ok_or_else(invalid)?;
    if path != claimed {
        return Err(invalid());
    }
    if block.get("type").and_then(Value::as_str) != Some("resource_link")
        || block.get("uri").and_then(Value::as_str) != Some(file_uri(&path).as_str())
        || block.pointer("/_meta/acpmux/uploadPath").and_then(Value::as_str) != path.to_str()
    {
        return Err(invalid());
    }
    let parent = path.parent().ok_or_else(invalid)?;
    let marker = crate::config::private_state_file(&parent.join(MARKER)).map_err(|_| invalid())?;
    let marker: Value = serde_json::from_reader(marker.take(256)).map_err(|_| invalid())?;
    let expected = marker.get("proof").and_then(Value::as_str).ok_or_else(invalid)?;
    if !cmux_local_auth::tokens_match(proof, expected)
        || web && marker.get("web") != Some(&Value::Bool(true))
    {
        return Err(invalid());
    }
    let file = file_uploads::open_finished(&path).map_err(io)?;
    file_uploads::touch(&path).map_err(io)?;
    Ok((file, path))
}

/// The sources of a waiting prompt are checked one row at a time, with exactly
/// the same Web provenance and private-file checks as ungrouped upload links.
pub(crate) fn validate(session: &str, web: bool, block: &Value) -> Result<(), RpcError> {
    let (file, _) = open(session, web, block)?;
    let mut previous = None;
    for line in BufReader::new(file).lines() {
        let row: Value = serde_json::from_str(&line.map_err(io)?).map_err(io)?;
        let source = row.get("block").ok_or_else(invalid)?;
        if previous.as_ref() == Some(source) {
            continue;
        }
        if is_manifest(source) || web && !file_uploads::web::verifies_resolved(session, source) {
            return Err(invalid());
        }
        super::still_there(session, web, std::slice::from_ref(source))?;
        previous = Some(source.clone());
    }
    Ok(())
}

/// Spill before queueing or recording, rather than letting a newly accepted
/// prompt produce an oversized queue event or a history stub. Ordinary prompt
/// text and inline images stay in place; every grouped link stays in the file.
pub(crate) fn compact(
    session: &str,
    web: bool,
    blocks: &mut Vec<Value>,
    display: &mut Option<Value>,
) -> Result<Option<PathBuf>, RpcError> {
    // Queue records carry both prompt and display metadata. Leave enough room
    // for that projection and the RPC envelope; this threshold changes only
    // representation, never what attachments are accepted.
    let bytes: usize = blocks.iter().map(|block| block.to_string().len()).sum();
    if bytes < (crate::rpc::MAX_MESSAGE_BYTES - (1 << 20)) / 2 {
        return Ok(None);
    }
    let grouped = |b: &Value| {
        b.get("type").and_then(Value::as_str) == Some("resource_link")
            && b.pointer("/_meta/acpmux/uploadPath").is_some()
            && !is_manifest(b)
    };
    let count = blocks.iter().filter(|block| grouped(block)).count();
    if count == 0 {
        return Ok(None);
    }
    let id = uuid::Uuid::now_v7().to_string();
    let name = format!("{count}-attachments.jsonl");
    let path = file_uploads::finished_path(session, &id, &name).ok_or_else(invalid)?;
    let parent = path.parent().ok_or_else(invalid)?;
    crate::config::refuse_lost_home(&path).map_err(io)?;
    crate::config::private_state_dir(parent).map_err(io)?;
    let partial = parent.join(".partial");
    let mut secret = [0u8; 32];
    getrandom::fill(&mut secret).map_err(io)?;
    let proof: String = secret.iter().map(|byte| format!("{byte:02x}")).collect();
    let displays = display
        .as_ref()
        .and_then(Value::as_array)
        .into_iter()
        .flatten()
        .filter_map(|part| part.get("blockIndex")?.as_u64().map(|index| (index as usize, part)))
        .collect::<HashMap<_, _>>();
    let saved: Result<(), RpcError> = (|| {
        let mut options = std::fs::OpenOptions::new();
        options.write(true).create_new(true);
        #[cfg(unix)]
        std::os::unix::fs::OpenOptionsExt::mode(&mut options, 0o600);
        let mut writer = BufWriter::new(options.open(&partial).map_err(io)?);
        #[derive(serde::Serialize)]
        #[serde(rename_all = "camelCase")]
        struct Row<'a> {
            block_index: usize,
            block: &'a Value,
            #[serde(skip_serializing_if = "Option::is_none")]
            display_part: Option<&'a Value>,
        }
        for (index, block) in blocks.iter().enumerate().filter(|(_, block)| grouped(block)) {
            let row =
                Row { block_index: index, block, display_part: displays.get(&index).copied() };
            serde_json::to_writer(&mut writer, &row).map_err(io)?;
            writer.write_all(b"\n").map_err(io)?;
        }
        writer.flush().map_err(io)?;
        writer.get_ref().sync_all().map_err(io)?;
        std::fs::rename(&partial, &path).map_err(io)?;
        crate::agent_tools::write_private(
            &parent.join(MARKER),
            &serde_json::to_vec(&json!({"proof": proof, "web": web})).map_err(io)?,
        )
        .map_err(io)?;
        file_uploads::touch(&path).map_err(io)?;
        Ok(())
    })();
    if saved.is_err() {
        let _ = std::fs::remove_dir_all(parent);
    }
    saved?;
    let size = std::fs::metadata(&path).map_err(io)?.len();
    let link = json!({"type": "resource_link", "uri": file_uri(&path), "name": name,
        "mimeType": "application/x-ndjson", "size": size,
        "_meta": {"acpmux": {"uploadPath": path.to_string_lossy(),
            "uploadManifest": {"uploadId": id, "fileName": name, "proof": proof}}}});
    let mut next = Vec::new();
    let mut next_display = Vec::new();
    let mut inserted = false;
    for (index, block) in blocks.iter().enumerate() {
        if grouped(block) {
            if !inserted {
                next.push(link.clone());
                inserted = true;
            }
            continue;
        }
        if block.pointer("/_meta/acpmux/context") == Some(&Value::Bool(true))
            && block.pointer("/_meta/acpmux/uploadContext") == Some(&Value::Bool(true))
        {
            continue;
        }
        if let Some(part) = displays.get(&index) {
            let mut part = (*part).clone();
            part.set("blockIndex", json!(next.len()));
            // Companion indexes refer to the original list, retained in the manifest.
            if let Some(object) = part.as_object_mut() {
                object.remove("companionOf");
            }
            next_display.push(part);
        }
        next.push(block.clone());
    }
    next.push(json!({"type": "text", "text": format!(
        "<cmux-attachments-context>\nAll {count} attached files are listed in {}. Read the entire JSONL file with your tools; every row is one attachment, with its original blockIndex and resource_link. Do not stop after the first page.\n</cmux-attachments-context>", path.display()),
        "_meta": {"acpmux": {"context": true}}}));
    *blocks = next;
    *display = (!next_display.is_empty()).then_some(Value::Array(next_display));
    Ok(Some(parent.to_path_buf()))
}

/// `_acpmux/events {uploadManifest, manifestOffset?, maxBytes?}` reads the
/// complete ordered list without ever sending or buffering the whole file.
pub(crate) fn page(session: &str, web: bool, params: &Value) -> Result<Value, RpcError> {
    let block = params.get("uploadManifest").ok_or_else(invalid)?;
    let (mut file, _) = open(session, web, block)?;
    let offset = params.get("manifestOffset").and_then(Value::as_u64).unwrap_or(0);
    if offset > file.metadata().map_err(io)?.len() {
        return Err(invalid());
    }
    file.seek(SeekFrom::Start(offset)).map_err(io)?;
    let mut reader = BufReader::new(file);
    let budget = crate::hub::page_bytes(params);
    let mut rows = Vec::new();
    let mut bytes = 0;
    let mut next = offset;
    let mut has_more = false;
    let mut line = String::new();
    loop {
        line.clear();
        let read = reader.read_line(&mut line).map_err(io)?;
        if read == 0 {
            break;
        }
        if !rows.is_empty() && bytes + read > budget {
            has_more = true;
            break;
        }
        rows.push(serde_json::from_str::<Value>(&line).map_err(io)?);
        bytes += read;
        next += read as u64;
    }
    Ok(json!({"attachments": rows, "hasMore": has_more, "manifestOffset": next}))
}
