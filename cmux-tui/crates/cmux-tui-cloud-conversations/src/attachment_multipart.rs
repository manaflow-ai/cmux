//! Sequential multipart originals. The Worker owns the plan, hash and part receipts;
//! the client retains its staged file until the final commit (or any error).

use std::io::{Seek, SeekFrom};

use serde_json::{Value, json};

use crate::attachments::{route_value, transport_url};
use crate::contract::require_conversation;
use crate::{CloudConversations, CloudError, PutBody};

impl CloudConversations {
    /// Send each file range without materializing the original or a whole part.
    /// Parts stay on the lease origin, carry only their slot credential, and
    /// completion uses the authenticated API path rather than a plan-supplied URL.
    pub fn attachment_multipart(
        &self,
        conversation: &str,
        plan: &Value,
        mut body: PutBody,
    ) -> Result<Value, CloudError> {
        require_conversation(conversation)?;
        let bad = || CloudError::Unavailable("invalid multipart upload plan".into());
        let url = plan.get("upload_url").and_then(Value::as_str).ok_or_else(bad)?;
        let slot =
            plan.get("slot").and_then(Value::as_str).filter(|s| !s.is_empty()).ok_or_else(bad)?;
        let size =
            plan.get("part_size").and_then(Value::as_u64).filter(|n| *n > 0).ok_or_else(bad)?;
        let count = plan.get("part_count").and_then(Value::as_u64).ok_or_else(bad)?;
        let direct = match plan.get("transport") {
            None => false,
            Some(Value::String(value)) if value == "worker" => false,
            Some(Value::String(value)) if value == "direct" => true,
            _ => return Err(bad()),
        };
        transport_url(url, &self.api_origin()?, true)?;
        let mut receipts = Vec::new();
        let total = body.len();
        if total == 0 || count != total.div_ceil(size) || count > 10_000 {
            return Err(bad());
        }
        for index in 0..count {
            let offset = index * size;
            let len = size.min(total - offset);
            let part = match &mut body {
                PutBody::File { file, .. } => {
                    file.seek(SeekFrom::Start(offset))
                        .map_err(|e| CloudError::Unavailable(e.to_string()))?;
                    PutBody::File {
                        file: file
                            .try_clone()
                            .map_err(|e| CloudError::Unavailable(e.to_string()))?,
                        len,
                    }
                }
                PutBody::Bytes(bytes) => {
                    PutBody::Bytes(bytes[offset as usize..(offset + len) as usize].to_vec())
                }
            };
            // Ignore arbitrary plan headers: no bearer, cookies or original-file
            // Content-Length can escape into the part request.
            let headers = vec![
                ("x-cmux-part-number".into(), (index + 1).to_string()),
                ("content-length".into(), len.to_string()),
            ];
            if direct {
                let transport = |e: crate::TransportError| CloudError::Unavailable(e.0);
                let signed = route_value(
                    self.backend().attachment_part_url(url, index + 1).map_err(transport)?,
                )?;
                let destination = signed.get("url").and_then(Value::as_str).ok_or_else(bad)?;
                transport_url(destination, &self.api_origin()?, false)?;
                if signed.get("method").and_then(Value::as_str) != Some("PUT")
                    || signed.get("part_number").and_then(Value::as_u64) != Some(index + 1)
                    || signed.pointer("/headers/content-length").and_then(Value::as_str)
                        != Some(len.to_string().as_str())
                {
                    return Err(bad());
                }
                // The contract signs only Content-Length. Never forward slot or auth headers.
                let headers = vec![("content-length".into(), len.to_string())];
                let (reply, etag) =
                    self.backend().put_with_etag(destination, &headers, part).map_err(transport)?;
                if !(200..300).contains(&reply.status) {
                    return Err(CloudError::Unavailable(format!(
                        "part upload answered HTTP {}",
                        reply.status
                    )));
                }
                let etag = etag.filter(|tag| !tag.trim().is_empty()).ok_or_else(|| {
                    CloudError::Unavailable("part upload returned no ETag".into())
                })?;
                receipts.push(json!({"part_number": index + 1, "etag": etag}));
            } else {
                self.attachment_put(url, &headers, part, true)?;
            }
        }
        let mut completion = json!({"conversation": conversation, "slot": slot});
        if direct {
            completion["parts"] = json!(receipts);
        }
        let mut verified = 0;
        loop {
            // Each request hashes more stored bytes. Strict progress makes this finite;
            // a stalled or malformed response fails instead of polling indefinitely.
            let reply =
                route_value(self.post("/v1/home/attachments/multipart/complete", &completion)?)?;
            if reply.get("state").and_then(Value::as_str) != Some("verifying") {
                if direct && !reply.get("attachment").is_some_and(Value::is_object) {
                    return Err(bad());
                }
                return Ok(reply);
            }
            let next = reply.get("verified_bytes").and_then(Value::as_u64).ok_or_else(bad)?;
            if !direct
                || next <= verified
                || next > total
                || reply.get("byte_count").and_then(Value::as_u64) != Some(total)
            {
                return Err(bad());
            }
            verified = next;
        }
    }
}

#[cfg(test)]
#[path = "attachment_multipart_tests.rs"]
mod tests;
