# Test fixtures for the signed Linux release file (cmux-tui/scripts/linux-release-verify.sh),
# sourced by linux-release-verify.test.sh and machine-join.test.sh. Needs OpenSSL 3.

# DIR: an Ed25519 test key, DIR/key.pem, and DIR/keys.json in the shape of web-update-keys.json.
# Sets lrf_key_id.
lrf_key() {
  mkdir -p "$1"
  openssl genpkey -algorithm ed25519 -out "$1/key.pem" 2>/dev/null
  openssl pkey -in "$1/key.pem" -pubout -outform DER 2>/dev/null | tail -c 32 >"$1/raw"
  lrf_key_id="$(openssl dgst -sha256 -r "$1/raw" | cut -c 1-16)"
  printf '{"keys": [{"id": "%s", "ed25519": "%s"}]}\n' "$lrf_key_id" "$(openssl base64 -A -in "$1/raw")" >"$1/keys.json"
  printf '%s\n' "$lrf_key_id" >"$1/id"
}

# NAME URL FILE [SIZE [SHA]]: one entry of a target, `"NAME":{...}`, with FILE's size and sha256
# unless SIZE or SHA say otherwise.
lrf_entry() {
  size="${4:-$(wc -c <"$3" | tr -d ' ')}"
  sum="${5:-$(openssl dgst -sha256 -r "$3" | cut -c 1-64)}"
  printf '"%s":{"sha256":"%s","size":%s,"url":"%s"}' "$1" "$sum" "$size" "$2"
}

# PAYLOAD KEYDIR OUT: the envelope of PAYLOAD's exact bytes, signed by KEYDIR's key.
lrf_sign() {
  openssl pkeyutl -sign -rawin -inkey "$2/key.pem" -in "$1" -out "$1.sig"
  printf '{"payload":"%s","schema":1,"signatures":[{"key_id":"%s","sig":"%s"}]}\n' \
    "$(openssl base64 -A -in "$1")" "$(cat "$2/id")" "$(openssl base64 -A -in "$1.sig")" >"$3"
}
