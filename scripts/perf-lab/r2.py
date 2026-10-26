#!/usr/bin/env python3
"""Write-once, content-addressed PUTs to a Cloudflare R2 bucket (S3 API, SigV4), stdlib only.

The lab keeps blobs in R2 by digest (p12-perf-process.md 3.5, 3.6): the key holds the blob's sha256, so an upload
that finds the key taken (412 on `If-None-Match: *`) already has its bytes there. The body streams from the file,
signed with the sha256 computed while hashing it, so a large store backup never sits in memory.

Credentials come from the environment, then from CMUX_PERF_LAB_R2_ENV_FILE (default ~/.secrets/cmux-perf-lab.env),
never from the command line:
  CMUX_PERF_LAB_R2_ACCOUNT_ID, CMUX_PERF_LAB_R2_ACCESS_KEY_ID, CMUX_PERF_LAB_R2_SECRET_ACCESS_KEY,
  CMUX_PERF_LAB_R2_BUCKET (default cmux-perf-lab), CMUX_PERF_LAB_R2_ENDPOINT (optional).
"""
from __future__ import annotations

import hashlib
import hmac
import http.client
import os
from collections.abc import Callable, Mapping
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from urllib.parse import quote, urlsplit

ENV_PREFIX = "CMUX_PERF_LAB_R2_"
ENV_FILE = Path.home() / ".secrets" / "cmux-perf-lab.env"
DEFAULT_BUCKET = "cmux-perf-lab"
NAMES = ("ACCOUNT_ID", "ACCESS_KEY_ID", "SECRET_ACCESS_KEY", "BUCKET", "ENDPOINT")


class R2Error(RuntimeError):
    pass


def sha256_file(path: Path | str) -> str:
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(1 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def read_env_file(path: Path) -> dict[str, str]:
    """NAME=value lines (an `export ` prefix and one level of quotes allowed); a missing file is empty."""
    values: dict[str, str] = {}
    try:
        lines = path.read_text(encoding="utf-8").splitlines()
    except OSError:
        return values
    for line in lines:
        line = line.strip().removeprefix("export ")
        name, sep, value = line.partition("=")
        if sep and name.startswith(ENV_PREFIX):
            values[name] = value.strip().strip("\"'")
    return values


@dataclass(frozen=True)
class R2Bucket:
    endpoint: str
    bucket: str
    access_key_id: str
    secret_access_key: str

    @classmethod
    def from_env(cls, environ: Mapping[str, str] = os.environ) -> "R2Bucket | None":
        """The configured bucket, or None when no credentials are set."""
        file_values = read_env_file(Path(environ.get(f"{ENV_PREFIX}ENV_FILE", ENV_FILE)))
        get = {name: environ.get(ENV_PREFIX + name) or file_values.get(ENV_PREFIX + name, "") for name in NAMES}
        if not (get["ACCESS_KEY_ID"] and get["SECRET_ACCESS_KEY"]):
            return None
        endpoint = get["ENDPOINT"] or (f"https://{get['ACCOUNT_ID']}.r2.cloudflarestorage.com"
                                       if get["ACCOUNT_ID"] else "")
        if not endpoint:
            raise R2Error(f"{ENV_PREFIX}ACCOUNT_ID or {ENV_PREFIX}ENDPOINT names the R2 endpoint")
        return cls(endpoint.rstrip("/"), get["BUCKET"] or DEFAULT_BUCKET, get["ACCESS_KEY_ID"],
                   get["SECRET_ACCESS_KEY"])

    def signed_headers(self, method: str, key: str, payload_sha256: str, *, now: datetime,
                       extra: Mapping[str, str] = {}) -> tuple[str, dict[str, str]]:
        """The request path and SigV4 headers (region `auto`, service `s3`) for one request."""
        host = urlsplit(self.endpoint).netloc
        path = f"/{quote(self.bucket)}/{quote(key, safe='/')}"
        stamp, day = now.strftime("%Y%m%dT%H%M%SZ"), now.strftime("%Y%m%d")
        headers = {"host": host, "x-amz-content-sha256": payload_sha256, "x-amz-date": stamp,
                   **{name.lower(): value for name, value in extra.items()}}
        names = ";".join(sorted(headers))
        canonical = "\n".join([method, path, "", "".join(f"{n}:{headers[n].strip()}\n" for n in sorted(headers)),
                               names, payload_sha256])
        scope = f"{day}/auto/s3/aws4_request"
        to_sign = f"AWS4-HMAC-SHA256\n{stamp}\n{scope}\n{hashlib.sha256(canonical.encode()).hexdigest()}"
        signing = ("AWS4" + self.secret_access_key).encode()
        for part in (day, "auto", "s3", "aws4_request"):
            signing = hmac.new(signing, part.encode(), hashlib.sha256).digest()
        signature = hmac.new(signing, to_sign.encode(), hashlib.sha256).hexdigest()
        headers["authorization"] = (f"AWS4-HMAC-SHA256 Credential={self.access_key_id}/{scope}, "
                                    f"SignedHeaders={names}, Signature={signature}")
        return path, headers

    def put_once(self, key: str, path: Path | str, *, sha256: str | None = None,
                 clock: Callable[[], datetime] = lambda: datetime.now(timezone.utc),
                 connect: Callable[[str], http.client.HTTPConnection] | None = None) -> bool:
        """Uploads the file at `path` to `key` unless the key exists; True when this call wrote it."""
        digest = sha256 or sha256_file(path)
        size = os.path.getsize(path)
        request_path, headers = self.signed_headers("PUT", key, digest, now=clock(),
                                                    extra={"if-none-match": "*", "content-length": str(size)})
        connection = (connect or (lambda host: http.client.HTTPSConnection(host, timeout=120)))(
            urlsplit(self.endpoint).netloc)
        try:
            with open(path, "rb") as body:
                connection.request("PUT", request_path, body=body, headers=headers)
                response = connection.getresponse()
                detail = response.read(512)
        except OSError as error:
            raise R2Error(f"PUT {key}: {error}") from None
        finally:
            connection.close()
        if response.status == 412:
            return False
        if response.status not in (200, 201):
            raise R2Error(f"PUT {key}: HTTP {response.status} {detail[:200].decode(errors='replace')}")
        return True
