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
# Workflows pass `path: ~/.bun/install/cache` as actions/cache does, but the
# composite action hands it over as a quoted env value, so the shell never
# expands the tilde: saves warned "does not exist" and uploaded nothing, and
# every restore of those keys missed (and would have unpacked into ./~).
case "$dir" in
  "~") dir="$HOME" ;;
  "~/"*) dir="$HOME/${dir#\~/}" ;;
esac

# CI_CACHE_R2_NAMESPACE names a platform-independent cache (for example
# `any` for built web bundles that a Linux job saves and a Mac restores);
# otherwise the namespace is the runner's OS and architecture.
platform="${CI_CACHE_R2_NAMESPACE:-${RUNNER_OS:-$(uname -s)}-${RUNNER_ARCH:-$(uname -m)}}"
if ! valid_name "$platform"; then
  echo "r2-cache: namespace has characters outside [A-Za-z0-9._-]: $platform" >&2
  exit 2
fi
namespace="v1/$platform"
set_output() { if [[ -n "${GITHUB_OUTPUT:-}" ]]; then echo "$1=$2" >> "$GITHUB_OUTPUT"; fi; }

lan_cache="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lan_cache_fetch.py"
fetch() { # <relative object path> <destination file>
  # An archive comes from the site's LAN cache host first, through the mini's glaeda broker: the minis
  # share one slow uplink, and the host fetches each object over it once. A miss there means the bucket
  # has none; anything else (no broker, host down) falls through to the bucket.
  if [[ "$1" == */objects/* ]] && [[ -S "${CMUX_LAN_CACHE_SOCKET:-$HOME/.local/state/glaeda/lan-fetch/fetch.sock}" ]] \
      && command -v python3 >/dev/null 2>&1; then
    # The broker writes into a directory of its own, removed afterwards: a broker that answers late can
    # never touch the file the bucket download below writes.
    local lan_status=1 lan_dir
    if lan_dir="$(mktemp -d "${TMPDIR:-/tmp}/r2-cache-lan.XXXXXX")"; then
      lan_status=0
      python3 "$lan_cache" "${CI_CACHE_R2_PUBLIC_URL%/}" "$1" "$lan_dir/object" || lan_status=$?
      if [[ "$lan_status" == 0 ]] && mv -f "$lan_dir/object" "$2"; then
        rm -rf "$lan_dir"
        return 0
      fi
      rm -rf "$lan_dir"
      [[ "$lan_status" == 3 ]] && return 22
    fi
  fi
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
  local candidate="$1" work extension target
  # nightly_build_state.py links workspace cache paths to a persistent runner
  # directory. Preserve that link and its populated contents: replacing it
  # would silently move a multi-GiB cache back into the ephemeral workspace.
  if [[ -L "$dir" ]]; then
    target="$(python3 - "$dir" <<'PY2'
import os
import sys
print(os.path.realpath(sys.argv[1]))
PY2
)"
    if [[ -n "$(find "$target" -mindepth 1 -print -quit 2>/dev/null)" ]]; then
      echo "r2-cache: preserving populated symlink target $target"
      return 1
    fi
    dir="$target"
  fi
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

# A save that writes nothing: a warning, or with CACHE_REQUIRED=true an error that fails the step.
# A writer whose entry pull requests compare against (the base's test log) is required: from #57363
# (02:53Z) to #57975 (2026-11-26 15:35Z) its save had no credentials, warned "nothing saved" and went
# green, so every red acpmux pull request found no base log and had each base red charged to it.
not_saved() {
  if [[ "${CACHE_REQUIRED:-}" == true ]]; then
    echo "::error::r2-cache: $1 (a required save)"
    return 1
  fi
  echo "::warning::r2-cache: $1"
  return 0
}

# The archive is written whole before its upload (an S3 PUT needs its length). Its size is at most the
# directory's, so a save whose disk lacks that room plus headroom is skipped with a warning: the cache
# misses once, and the job stays green. Filling the disk instead killed the runner itself: machine
# channel x86_64 musl leg, job 140250090793 (2026-11-27, cmux-runner-pool-e5a-0207), "No space left on
# device" in the runner's own _diag log while "Save the workspace delta to R2" wrote its archive.
room_for_archive() { # <work dir>
  local need_kib free_kib headroom_kib="${CI_CACHE_R2_SAVE_HEADROOM_KIB:-1048576}"
  [[ "$headroom_kib" =~ ^[0-9]+$ ]] || headroom_kib=1048576
  need_kib="$(du -sk "$dir" 2>/dev/null | cut -f1)" || need_kib=""
  free_kib="$(df -Pk "$1" 2>/dev/null | awk 'NR == 2 { print $4 }')" || free_kib=""
  [[ "$need_kib" =~ ^[0-9]+$ && "$free_kib" =~ ^[0-9]+$ ]] || return 0
  if ((free_kib < need_kib + headroom_kib)); then
    room_short="$key not saved: $((free_kib >> 10)) MiB free for its archive, $(((need_kib + headroom_kib) >> 10)) MiB needed (scripts/ci/r2-cache.sh room_for_archive)"
    return 1
  fi
  echo "r2-cache: $((free_kib >> 10)) MiB free, archive at most $((need_kib >> 10)) MiB"
}

save() {
  local name
  for name in CI_CACHE_R2_ENDPOINT CI_CACHE_R2_BUCKET CI_CACHE_R2_PUBLIC_URL AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY; do
    if [[ -z "${!name:-}" ]]; then
      not_saved "$name is not set; nothing saved"
      return
    fi
  done
  if [[ ! -d "$dir" ]]; then
    not_saved "$dir does not exist; nothing saved"
    return
  fi

  local extension="tar.gz" work status generation url
  command -v zstd >/dev/null 2>&1 && extension="tar.zst"
  # GITHUB_RUN_ID increases across every workflow in the repository, in the
  # order runs were created. Run numbers count per workflow, and nightly.yml
  # and seed-derived-data.yml write the same prefixes.
  generation="${GITHUB_RUN_ID:-0}"
  valid_generation "$generation" || { not_saved "invalid run ID; nothing saved"; return; }
  work="$(mktemp -d)"
  url="${CI_CACHE_R2_ENDPOINT%/}/$CI_CACHE_R2_BUCKET/$namespace/objects/$key.$extension"
  status="$(request --head --dump-header "$work/headers" "$url")" || status=000
  local room_short=""
  if [[ "$status" == 404 ]] && ! room_for_archive "$work"; then
    rm -rf "$work"
    not_saved "$room_short"
    return
  fi
  if [[ "$status" == 404 ]]; then
    if [[ "$extension" == "tar.zst" ]]; then
      tar -cf - -C "$dir" . | zstd -T0 -3 -q -o "$work/archive"
    else
      tar -cf - -C "$dir" . | gzip -1 > "$work/archive"
    fi
    echo "r2-cache: archive is $(du -m "$work/archive" | cut -f1) MB"
    # A dropped connection (HTTP 000: no response, which curl's own --retry does not retry) or a 5xx
    # sends the archive again, up to 3 times: the fat cargo legs' first 1483 MB save got 000 and
    # published nothing (job 140187794318, 2026-11-26). An upload the bucket kept before the drop
    # answers the retry with 412, read back below like a concurrent writer's.
    local attempt
    for attempt in 1 2 3; do
      status="$(request -H 'If-None-Match: *' -H "x-amz-meta-generation: $generation" \
        -H 'content-type: application/octet-stream' -T "$work/archive" "$url")" || status=000
      [[ "$status" == 000 || "$status" == 5?? ]] && ((attempt < 3)) || break
      echo "r2-cache: archive upload attempt $attempt got HTTP $status; retrying"
      sleep "$((attempt * 5))"
    done
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
    rm -rf "$work"
    not_saved "archive request failed (HTTP $status); nothing published"
    return
  fi
  generation="$(header x-amz-meta-generation "$work/headers")"
  generation="${generation:-0}"
  if ! valid_generation "$generation"; then
    rm -rf "$work"
    not_saved "invalid stored generation; nothing published"
    return
  fi

  # One pointer per dash-terminated prefix, so any restore prefix finds the
  # newest key. Pointers go last: a reader never sees one without its object.
  local prefix="" part rest="$key" missed=""
  printf '%s\n' "$key" > "$work/pointer"
  while [[ "$rest" == *-* ]]; do
    part="${rest%%-*}"
    rest="${rest#*-}"
    prefix="$prefix$part-"
    publish_pointer "$prefix" "$work" "$generation" \
      || missed="$missed $prefix"
  done
  rm -rf "$work"
  # A reader restores by prefix through these pointers: one left behind hides this save from it.
  [[ -z "$missed" ]] || { not_saved "pointer(s)$missed not updated"; return; }
  echo "r2-cache: saved $key"
}

if [[ "$mode" == "restore" ]]; then
  restore "$@" || { echo "r2-cache: restore failed; treating as a miss"; set_output cache-hit false; }
else
  save
fi
