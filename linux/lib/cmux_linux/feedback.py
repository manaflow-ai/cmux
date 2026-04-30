from __future__ import annotations

import mimetypes
import os
import time
import urllib.request
import uuid
from pathlib import Path
from typing import Any, Mapping


FEEDBACK_ENDPOINT_ENV_KEYS = (
    "CMUX_LINUX_FEEDBACK_ENDPOINT",
    "CMUX_FEEDBACK_API_URL",
    "CMUX_FEEDBACK_ENDPOINT",
)
FEEDBACK_USER_AGENT = "cmux-linux"


def feedback_endpoint_url(env: Mapping[str, str] | None = None) -> str | None:
    values = env if env is not None else os.environ
    for key in FEEDBACK_ENDPOINT_ENV_KEYS:
        value = values.get(key)
        if value is None:
            continue
        stripped = value.strip()
        if stripped.startswith(("http://", "https://")):
            return stripped
        return None
    return None


def build_feedback_upload_request(
    endpoint: str,
    submission: Mapping[str, Any],
    image_paths: list[str],
    *,
    boundary: str | None = None,
) -> urllib.request.Request:
    resolved_boundary = boundary or f"cmux-linux-{uuid.uuid4().hex}"
    fields = _feedback_upload_fields(submission)
    files = [_feedback_file_payload(path) for path in image_paths]
    body = _multipart_body(fields, files, resolved_boundary)
    return urllib.request.Request(
        endpoint,
        data=body,
        headers={
            "Accept": "application/json",
            "Content-Type": f"multipart/form-data; boundary={resolved_boundary}",
            "User-Agent": FEEDBACK_USER_AGENT,
        },
        method="POST",
    )


def _feedback_upload_fields(submission: Mapping[str, Any]) -> dict[str, str]:
    body = str(submission.get("body") or submission.get("message") or "")
    submitted_at = submission.get("submitted_at")
    submitted_at_text = str(submitted_at if submitted_at is not None else time.time())
    return {
        "email": str(submission.get("email") or ""),
        "message": body,
        "platform": str(submission.get("platform") or "linux"),
        "submissionId": str(submission.get("id") or ""),
        "submittedAt": submitted_at_text,
    }


def _feedback_file_payload(path: str) -> dict[str, Any]:
    file_path = Path(path)
    data = file_path.read_bytes()
    mime_type = mimetypes.guess_type(file_path.name)[0] or "application/octet-stream"
    return {
        "field_name": "attachments",
        "file_name": file_path.name,
        "mime_type": mime_type,
        "data": data,
    }


def _multipart_body(fields: Mapping[str, str], files: list[Mapping[str, Any]], boundary: str) -> bytes:
    chunks: list[bytes] = []
    for name, value in fields.items():
        chunks.extend(
            [
                f"--{boundary}\r\n".encode("utf-8"),
                f'Content-Disposition: form-data; name="{name}"\r\n\r\n'.encode("utf-8"),
                value.encode("utf-8"),
                b"\r\n",
            ]
        )
    for file_payload in files:
        field_name = str(file_payload["field_name"])
        file_name = str(file_payload["file_name"])
        mime_type = str(file_payload["mime_type"])
        data = file_payload["data"]
        chunks.extend(
            [
                f"--{boundary}\r\n".encode("utf-8"),
                (
                    f'Content-Disposition: form-data; name="{field_name}"; '
                    f'filename="{file_name}"\r\n'
                ).encode("utf-8"),
                f"Content-Type: {mime_type}\r\n\r\n".encode("utf-8"),
                data if isinstance(data, bytes) else bytes(data),
                b"\r\n",
            ]
        )
    chunks.append(f"--{boundary}--\r\n".encode("utf-8"))
    return b"".join(chunks)
