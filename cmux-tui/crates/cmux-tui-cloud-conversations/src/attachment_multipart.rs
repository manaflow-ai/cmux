//! Sequential multipart originals. The Worker owns the plan, hash and part receipts;
//! the client retains its staged file until the final commit (or any error).

use std::io::{Seek, SeekFrom};

use serde_json::{Value, json};

use crate::attachments::route_value;
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
            self.attachment_put(url, &headers, part, true)?;
        }
        route_value(self.post(
            "/v1/home/attachments/multipart/complete",
            &json!({"conversation": conversation, "slot": slot}),
        )?)
    }
}

#[cfg(test)]
#[path = "attachment_multipart_tests.rs"]
mod tests;
