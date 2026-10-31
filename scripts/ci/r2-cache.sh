#!/usr/bin/env bash
# Restore or save one cache directory in an R2 bucket.
#
#   r2-cache.sh restore <dir> <key> [<restore-prefix>...]
#   r2-cache.sh save    <dir> <key>
#   r2-cache.sh pack    <dir> <key> <out>
#   r2-cache.sh publish <out> <key> <sha256>
#
# Restores read a public URL and need no credentials, so any runner and any
# pull request can use them. Saves sign with the bucket's S3 credentials and
# run only in main-branch seed jobs. A restore never fails the job: every
# error is a miss.
#
# `pack` then `publish` is `save` in two jobs, so the job that builds a cache
# never holds the credentials (seed-derived-data-pool.yml: an owned Mac builds,
# an ephemeral Linux runner uploads). `pack` needs no credentials: it writes
# <out>/<key>.tar.zst (or .tar.gz) exactly as `save` would upload it, and
# <out>/<key>.packed naming the builder's namespace, and outputs `sha256`,
# the digest of those two files. When the public URL already serves the key it
# packs nothing, as `save` uploads nothing then. `publish` uploads what `pack`
# left in <out> under that namespace and publishes the pointers, exactly as
# `save` does after it packs, but only when the files still have the digest
# `pack` gave: the caller hands it over out of band (a job output), so bytes
# that reached <out> any other way are refused. Only macOS caches travel this
# way, so the namespace must be v1/macOS-ARM64 or v1/macOS-X64.
#
# Layout under CI_CACHE_R2_PUBLIC_URL (and the same keys in the bucket):
#   v1/<os>-<arch>/objects/<key>.tar.zst|.tar.gz   the archived directory
#   v1/<os>-<arch>/latest/<prefix>                 newest key with that prefix
set -euo pipefail

mode="${1:-}"
dir="${2:-}"
key="${3:-}"
case "$mode" in restore|save|pack|publish) ;; *) mode="" ;; esac
if [[ -z "$mode" || -z "$dir" || -z "$key" ]] || [[ ( "$mode" == "pack" || "$mode" == "publish" ) && -z "${4:-}" ]]; then
  echo "usage: r2-cache.sh restore|save <dir> <key> [<restore-prefix>...] | pack <dir> <key> <out> | publish <out> <key> <sha256>" >&2
  exit 2
fi
shift 3

valid_name() { [[ "$1" =~ ^[A-Za-z0-9._-]+$ ]]; }
if ! valid_name "$key"; then
  echo "r2-cache: key has characters outside [A-Za-z0-9._-]: $key" >&2
  exit 2
fi
if [[ "$dir" == *$'\n'* ]]; then
  echo "r2-cache: one directory per call" >&2
  exit 2
fi

namespace="v1/${RUNNER_OS:-$(uname -s)}-${RUNNER_ARCH:-$(uname -m)}"
set_output() { if [[ -n "${GITHUB_OUTPUT:-}" ]]; then echo "$1=$2" >> "$GITHUB_OUTPUT"; fi; }

fetch() { # <relative object path> <destination file>
  curl --fail --silent --show-error --location --retry 3 --retry-delay 2 \
    --connect-timeout 15 --max-time 900 -o "$2" "${CI_CACHE_R2_PUBLIC_URL%/}/$1"
}

unpack() { # <extension> <archive>
  if [[ "$1" == "tar.zst" ]]; then
    # Consume padding through EOF, otherwise bsdtar exits early and zstd
    # receives SIGPIPE, turning a valid restore into a miss under pipefail.
    zstd -dc "$2" | {
      local tar_status=0
      tar -xf - -C "$dir" || tar_status=$?
      cat > /dev/null
      return "$tar_status"
    }
  else
    tar -xzf "$2" -C "$dir"
  fi
}

restore_key() { # <key>; returns 0 when the directory was restored
  local candidate="$1" work extension
  work="$(mktemp -d)"
  for extension in tar.zst tar.gz; do
    if [[ "$extension" == "tar.zst" ]] && ! command -v zstd >/dev/null 2>&1; then
      continue
    fi
    if fetch "$namespace/objects/$candidate.$extension" "$work/archive" 2>/dev/null; then
      rm -rf "$dir"
      mkdir -p "$dir"
      if unpack "$extension" "$work/archive"; then
        rm -rf "$work"
        return 0
      fi
      # A truncated or corrupt archive must not leave half a cache behind.
      rm -rf "$dir"
      echo "r2-cache: could not unpack $candidate.$extension"
    fi
  done
  rm -rf "$work"
  return 1
}

restore() {
  set_output cache-hit false
  if [[ -z "${CI_CACHE_R2_PUBLIC_URL:-}" ]]; then
    echo "r2-cache: CI_CACHE_R2_PUBLIC_URL is not set; treating as a miss"
    return 0
  fi
  if restore_key "$key"; then
    echo "r2-cache: restored $key"
    set_output cache-hit true
    set_output cache-matched-key "$key"
    return 0
  fi
  local prefix pointer matched
  for prefix in "$@"; do
    [[ -n "$prefix" ]] || continue
    valid_name "$prefix" || { echo "r2-cache: skipping invalid prefix $prefix"; continue; }
    pointer="$(mktemp)"
    if fetch "$namespace/latest/$prefix" "$pointer" 2>/dev/null; then
      matched="$(head -c 512 "$pointer" | tr -d '[:space:]')"
      rm -f "$pointer"
      if valid_name "$matched" && [[ "$matched" == "$prefix"* ]] && restore_key "$matched"; then
        echo "r2-cache: restored $matched for prefix $prefix"
        set_output cache-matched-key "$matched"
        return 0
      fi
    else
      rm -f "$pointer"
    fi
  done
  echo "r2-cache: no entry for $key"
}

# Authenticated S3 metadata reads avoid CDN state when publishing pointers.
request() {
  printf 'user = "%s:%s"\n' "$AWS_ACCESS_KEY_ID" "$AWS_SECRET_ACCESS_KEY" \
    | curl --config - --silent --show-error --retry 3 --retry-delay 2 \
        --connect-timeout 15 --max-time 1800 \
        --aws-sigv4 "aws:amz:auto:s3" \
        -H "x-amz-content-sha256: UNSIGNED-PAYLOAD" \
        -o /dev/null -w '%{http_code}' "$@"
}

header() {
  awk -v name="$1:" 'tolower($1) == name {gsub("\r", ""); value=$2} END {print value}' "$2"
}

valid_generation() { [[ "$1" =~ ^[0-9]{1,12}$ ]]; }

publish_pointer() { # <prefix> <work dir> <archive generation>
  local prefix="$1" work="$2" generation="$3" attempt status etag current condition
  local url="${CI_CACHE_R2_ENDPOINT%/}/$CI_CACHE_R2_BUCKET/$namespace/latest/$prefix"
  for attempt in 1 2 3 4; do
    status="$(request --head --dump-header "$work/headers" "$url")" || return 1
    if [[ "$status" == 200 ]]; then
      current="$(header x-amz-meta-generation "$work/headers")"
      current="${current:-0}"
      valid_generation "$current" || return 1
      # Keep the archive's original generation when retrying a previously
      # uploaded key, so a late retry cannot promote an old archive.
      if (( 10#$current > 10#$generation )); then
        echo "r2-cache: pointer $prefix names a newer save (generation $current > $generation); left as is"
        return 0
      fi
      (( 10#$current == 10#$generation )) && return 0
      etag="$(header etag "$work/headers")"
      [[ -n "$etag" ]] || return 1
      condition="If-Match: $etag"
    elif [[ "$status" == 404 ]]; then
      condition='If-None-Match: *'
    else
      return 1
    fi
    status="$(request -H "$condition" -H "x-amz-meta-generation: $generation" \
      -H "content-type: text/plain" -H "cache-control: no-store" \
      -T "$work/pointer" "$url")" || return 1
    [[ "$status" == 200 ]] && return 0
    # A concurrent writer won. Re-read its generation before trying again.
    [[ "$status" == 412 || "$status" == 409 ]] || return 1
  done
  return 1
}

credentials() { # 0 when every name a signed write needs is set
  local name
  for name in CI_CACHE_R2_ENDPOINT CI_CACHE_R2_BUCKET CI_CACHE_R2_PUBLIC_URL AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY; do
    if [[ -z "${!name:-}" ]]; then
      echo "::warning::r2-cache: $name is not set; nothing saved"
      return 1
    fi
  done
}

archive_extension() { if command -v zstd >/dev/null 2>&1; then echo tar.zst; else echo tar.gz; fi; }

pack_archive() { # <extension> <archive>; archives $dir
  if [[ "$1" == "tar.zst" ]]; then
    # --long=27: a 128 MiB match window. Seeds and compilation caches repeat
    # content far apart; on real archives this cut seeds 27%, the compilation
    # cache 33% and SwiftPM 12% for about 5 s more on 11 GB. 2^27 is zstd's
    # default decompression limit, so restores need no flag.
    tar -cf - -C "$dir" . | zstd -T0 -3 --long=27 -q -o "$2"
  else
    tar -cf - -C "$dir" . | gzip -1 > "$2"
  fi
  echo "r2-cache: archive is $(du -m "$2" | cut -f1) MB"
}

# Uploads $key's archive unless the bucket has it, then publishes its pointers.
# ARCHIVE is the packed file; empty means pack $dir now (save), or, for a key
# `pack` found already published, that there is nothing to upload.
store() { # <extension> [<archive>]
  local extension="$1" archive="${2:-}" work status generation url
  # GITHUB_RUN_ID increases across every workflow in the repository, in the
  # order runs were created. Run numbers count per workflow, and nightly.yml
  # and seed-derived-data.yml write the same prefixes.
  generation="${GITHUB_RUN_ID:-0}"
  valid_generation "$generation" || { echo "::warning::r2-cache: invalid run ID; nothing saved"; return 0; }
  work="$(mktemp -d)"
  url="${CI_CACHE_R2_ENDPOINT%/}/$CI_CACHE_R2_BUCKET/$namespace/objects/$key.$extension"
  status="$(request --head --dump-header "$work/headers" "$url")" || status=000
  if [[ "$status" == 404 ]]; then
    if [[ -z "$archive" && "$mode" == "save" ]]; then
      archive="$work/archive"
      pack_archive "$extension" "$archive"
    elif [[ -z "$archive" ]]; then
      echo "::warning::r2-cache: $key was packed as published, but the bucket does not have it; nothing saved"
      rm -rf "$work"
      return 0
    fi
    status="$(request -H 'If-None-Match: *' -H "x-amz-meta-generation: $generation" \
      -H 'content-type: application/octet-stream' -T "$archive" "$url")" || status=000
    if [[ "$status" == 412 ]]; then
      status="$(request --head --dump-header "$work/headers" "$url")" || status=000
    elif [[ "$status" == 200 ]]; then
      # The archive was created by this run; no metadata read is needed.
      printf 'x-amz-meta-generation: %s\n' "$generation" > "$work/headers"
    fi
  elif [[ "$status" == 200 ]]; then
    echo "r2-cache: $key already exists; not saving archive, checking pointers"
  fi
  if [[ "$status" != 200 ]]; then
    echo "::warning::r2-cache: archive request failed (HTTP $status); nothing published"
    rm -rf "$work"
    return 0
  fi
  generation="$(header x-amz-meta-generation "$work/headers")"
  generation="${generation:-0}"
  if ! valid_generation "$generation"; then
    echo "::warning::r2-cache: invalid stored generation; nothing published"
    rm -rf "$work"
    return 0
  fi

  # One pointer per dash-terminated prefix, so any restore prefix finds the
  # newest key. Pointers go last: a reader never sees one without its object.
  local prefix="" part rest="$key"
  printf '%s\n' "$key" > "$work/pointer"
  while [[ "$rest" == *-* ]]; do
    part="${rest%%-*}"
    rest="${rest#*-}"
    prefix="$prefix$part-"
    publish_pointer "$prefix" "$work" "$generation" \
      || echo "::warning::r2-cache: pointer $prefix was not updated"
  done
  rm -rf "$work"
  echo "r2-cache: saved $key"
}

save() {
  credentials || return 0
  if [[ ! -d "$dir" ]]; then
    echo "::warning::r2-cache: $dir does not exist; nothing saved"
    return 0
  fi
  store "$(archive_extension)"
}

sha256_of() { if command -v shasum >/dev/null 2>&1; then shasum -a 256 "$@"; else sha256sum "$@"; fi; }

# The digest of what `pack` left for $key in OUT: its record and its archive,
# if any, by name, so neither can be swapped or added afterwards unnoticed.
packed_digest() { # <out>
  (
    cd "$1" || exit 1
    local name
    for name in "$key.packed" "$key.tar.zst" "$key.tar.gz"; do
      [[ ! -e "$name" ]] || sha256_of "$name"
    done
  ) | sha256_of | cut -d' ' -f1
}

published() { # <extension>; whether the public URL serves $key's archive now
  # A query the CDN has never seen, so a cached answer for this key (adoption
  # probes it before the build) cannot stand in for the bucket's.
  curl --fail --silent --location --head --connect-timeout 15 --max-time 30 -o /dev/null \
    "${CI_CACHE_R2_PUBLIC_URL%/}/$namespace/objects/$key.$1?r2-cache-pack=${GITHUB_RUN_ID:-0}-$$" 2>/dev/null
}

pack() { # <out>
  local out="$1" extension found=""
  if [[ ! -d "$dir" ]]; then
    echo "::warning::r2-cache: $dir does not exist; nothing packed"
    return 0
  fi
  mkdir -p "$out"
  rm -f "$out/$key.packed" "$out/$key.tar.zst" "$out/$key.tar.gz"
  extension="$(archive_extension)"
  if [[ -n "${CI_CACHE_R2_PUBLIC_URL:-}" ]]; then
    for found in "$extension" tar.zst tar.gz; do
      published "$found" && break
      found=""
    done
  fi
  if [[ -n "$found" ]]; then
    # `publish` still checks the pointers, as `save` does for an existing key.
    echo "r2-cache: $key already exists; not packing it"
    extension="$found"
  else
    pack_archive "$extension" "$out/$key.$extension"
  fi
  printf 'namespace=%s\nextension=%s\n' "$namespace" "$extension" > "$out/$key.packed"
  set_output sha256 "$(packed_digest "$out")"
}

publish() { # <sha256>
  local out="$dir" expected="$1" packed value extension archive="" actual
  credentials || return 0
  packed="$out/$key.packed"
  # A refusal fails the step: the caller downloaded what it was told was packed,
  # so anything else here is not a miss but a broken handoff.
  if [[ ! -f "$packed" ]]; then
    echo "::error::r2-cache: nothing was packed for $key in $out; nothing saved"
    return 1
  fi
  if ! [[ "$expected" =~ ^[0-9a-f]{64}$ ]]; then
    echo "::error::r2-cache: publish needs the sha256 pack gave for $key; nothing saved"
    return 1
  fi
  actual="$(packed_digest "$out")"
  if [[ "$actual" != "$expected" ]]; then
    echo "::error::r2-cache: what is in $out for $key (sha256 $actual) does not match what was packed ($expected); nothing saved"
    return 1
  fi
  value="$(sed -n 's/^namespace=//p' "$packed" | head -n 1)"
  extension="$(sed -n 's/^extension=//p' "$packed" | head -n 1)"
  # The builder's namespace, not this runner's: a Linux job publishes a macOS
  # cache. Only the macOS namespaces: nothing else is packed for publish.
  if ! [[ "$value" =~ ^v1/macOS-(ARM64|X64)$ ]] || ! [[ "$extension" == "tar.zst" || "$extension" == "tar.gz" ]]; then
    echo "::error::r2-cache: $packed is not a pack record of a macOS cache; nothing saved"
    return 1
  fi
  namespace="$value"
  [[ ! -f "$out/$key.$extension" ]] || archive="$out/$key.$extension"
  store "$extension" "$archive"
}

case "$mode" in
  restore) restore "$@" || { echo "r2-cache: restore failed; treating as a miss"; set_output cache-hit false; } ;;
  save) save ;;
  pack) pack "$1" ;;
  publish) publish "$1" ;;
esac
