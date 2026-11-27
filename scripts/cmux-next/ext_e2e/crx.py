"""Download a Chrome Web Store CRX and unpack it with its public key.

The CRX is the same file the Web Store installs. Unpacking keeps the
extension id: the manifest gets `key` from the CRX3 header proof whose
SHA-256 matches the signed crx_id. `_metadata` (Web Store signatures) is
removed, because Chromium refuses reserved names in unpacked extensions.
"""
import base64
import hashlib
import io
import json
import os
import shutil
import urllib.request
import zipfile

CACHE = os.path.expanduser("~/Library/Caches/cmux-ext-e2e/crx")
UPDATE_URL = ("https://clients2.google.com/service/update2/crx?response=redirect&prodversion=154.0.7000.0"
              "&acceptformat=crx2,crx3&x=id%3D{id}%26installsource%3Dondemand%26uc")


def fetch(extension_id, refresh=False, source=None):
    """The Web Store CRX, or `source` (a CRX URL) for delisted extensions."""
    os.makedirs(CACHE, exist_ok=True)
    path = os.path.join(CACHE, extension_id + ".crx")
    if refresh or not os.path.exists(path) or os.path.getsize(path) == 0:
        url = source or UPDATE_URL.format(id=extension_id)
        request = urllib.request.Request(url, headers={"user-agent": "Mozilla/5.0 Chrome/154.0"})
        with urllib.request.urlopen(request, timeout=60) as response:
            data = response.read()
        if not data.startswith(b"Cr24"):
            raise ValueError(f"not a CRX ({len(data)} bytes, HTTP {response.status})")
        with open(path, "wb") as out:
            out.write(data)
    return path


def _varint(data, index):
    value = shift = 0
    while True:
        byte = data[index]
        index += 1
        value |= (byte & 0x7F) << shift
        shift += 7
        if not byte & 0x80:
            return value, index


def _fields(data):
    index = 0
    while index < len(data):
        key, index = _varint(data, index)
        number, wire = key >> 3, key & 7
        if wire == 2:
            length, index = _varint(data, index)
            yield number, data[index:index + length]
            index += length
        elif wire == 0:
            value, index = _varint(data, index)
            yield number, value
        else:
            raise ValueError(f"unsupported wire type {wire}")


def _id(public_key):
    return "".join(chr(ord("a") + int(c, 16)) for c in hashlib.sha256(public_key).hexdigest()[:32])


def unpack(crx_path, target):
    data = open(crx_path, "rb").read()
    version = int.from_bytes(data[4:8], "little")
    if version == 3:
        header_size = int.from_bytes(data[8:12], "little")
        header = data[12:12 + header_size]
        payload = data[12 + header_size:]
        keys, crx_id = [], None
        for number, value in _fields(header):
            if number in (2, 3):  # sha256_with_rsa, sha256_with_ecdsa
                keys += [v for n, v in _fields(value) if n == 1]
            elif number == 10000:
                crx_id = next((v for n, v in _fields(value) if n == 1), None)
        wanted = crx_id.hex() if crx_id else None
        key = next((k for k in keys if wanted and hashlib.sha256(k).hexdigest()[:32] == wanted), keys[0] if keys else None)
    elif version == 2:
        key_len = int.from_bytes(data[8:12], "little")
        sig_len = int.from_bytes(data[12:16], "little")
        key = data[16:16 + key_len]
        payload = data[16 + key_len + sig_len:]
    else:
        raise ValueError(f"CRX version {version}")
    if os.path.isdir(target):
        shutil.rmtree(target)
    with zipfile.ZipFile(io.BytesIO(payload)) as archive:
        archive.extractall(target)
    shutil.rmtree(os.path.join(target, "_metadata"), ignore_errors=True)
    manifest_path = os.path.join(target, "manifest.json")
    with open(manifest_path, encoding="utf-8-sig") as handle:
        manifest = json.load(handle)
    if key:
        manifest["key"] = base64.b64encode(key).decode()
    with open(manifest_path, "w") as handle:
        json.dump(manifest, handle, indent=1)
    return manifest, (_id(key) if key else None)
