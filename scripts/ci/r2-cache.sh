#!/usr/bin/env bash
# Restore or save one cache directory in an R2 bucket.
#
#   r2-cache.sh restore <dir> <key> [<restore-prefix>...]
#   r2-cache.sh save    <dir> <key>
#
# Restores read a public URL and need no credentials, so any runner and any
# pull request can use them. Saves sign with the bucket's S3 credentials and
# run only in main-branch seed jobs. A restore never fails the job: every
# error is a miss.
#
# Layout under CI_CACHE_R2_PUBLIC_URL (and the same keys in the bucket):
#   v1/<os>-<arch>/objects/<key>.tar.zst|.tar.gz   the archived directory
#   v1/<os>-<arch>/latest/<prefix>                 newest key with that prefix
set -euo pipefail

mode="${1:-}"
dir="${2:-}"
key="${3:-}"
if [[ "$mode" != "restore" && "$mode" != "save" ]] || [[ -z "$dir" || -z "$key" ]]; then
  echo "usage: r2-cache.sh restore|save <dir> <key> [<restore-prefix>...]" >&2
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
      # Every writer uses nightly.yml's monotonic run number. Keep the
      # archive's original number when retrying a previously uploaded key.
      (( 10#$current >= 10#$generation )) && return 0
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

save() {
  local name
  for name in CI_CACHE_R2_ENDPOINT CI_CACHE_R2_BUCKET CI_CACHE_R2_PUBLIC_URL AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY; do
    if [[ -z "${!name:-}" ]]; then
      echo "::warning::r2-cache: $name is not set; nothing saved"
      return 0
    fi
  done
  if [[ ! -d "$dir" ]]; then
    echo "::warning::r2-cache: $dir does not exist; nothing saved"
    return 0
  fi

  local extension="tar.gz" work status generation url
  command -v zstd >/dev/null 2>&1 && extension="tar.zst"
  generation="${GITHUB_RUN_NUMBER:-0}"
  valid_generation "$generation" || { echo "::warning::r2-cache: invalid run number; nothing saved"; return 0; }
  work="$(mktemp -d)"
  url="${CI_CACHE_R2_ENDPOINT%/}/$CI_CACHE_R2_BUCKET/$namespace/objects/$key.$extension"
  status="$(request --head --dump-header "$work/headers" "$url")" || status=000
  if [[ "$status" == 404 ]]; then
    if [[ "$extension" == "tar.zst" ]]; then
      tar -cf - -C "$dir" . | zstd -T0 -3 -q -o "$work/archive"
    else
      tar -cf - -C "$dir" . | gzip -1 > "$work/archive"
    fi
    echo "r2-cache: archive is $(du -m "$work/archive" | cut -f1) MB"
    status="$(request -H 'If-None-Match: *' -H "x-amz-meta-generation: $generation" \
      -H 'content-type: application/octet-stream' -T "$work/archive" "$url")" || status=000
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

if [[ "$mode" == "restore" ]]; then
  restore "$@" || { echo "r2-cache: restore failed; treating as a miss"; set_output cache-hit false; }
else
  save
fi
