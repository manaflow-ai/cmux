#!/usr/bin/env bash
# github-release-download.sh URL OUT [CURL ARGS...]: download URL to OUT with curl, and for a github.com
# release download (https://github.com/OWNER/REPO/releases/download/TAG/NAME) with a token present
# (GH_DOWNLOAD_TOKEN, GH_TOKEN or GITHUB_TOKEN), through the API with that token first.
# The NIGHTLY Macs get 403 from GitHub on anonymous requests, release downloads included; github.com's
# download path ignores a token, the API's asset path does not (scripts/ci/github_release_asset.py).
# The token reaches curl through a config on a pipe, never argv, and curl drops a header it was given on a
# redirect to another host (the API answers with a signed link on the asset host). Anything the API route
# cannot do (no token, no asset, an error) falls back to URL itself, anonymously, as before.
# CURL ARGS are the caller's own (retries, timeouts); -f, -s, -S, -L are added.
set -uo pipefail
url="${1:?usage: github-release-download.sh URL OUT [CURL ARGS...]}"
out="${2:?usage: github-release-download.sh URL OUT [CURL ARGS...]}"
shift 2
here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
secret="${GH_DOWNLOAD_TOKEN:-${GH_TOKEN:-${GITHUB_TOKEN:-}}}"
if [[ -n "$secret" && "$url" == https://github.com/*/releases/download/* && "$secret" != *[!A-Za-z0-9_.-]* ]] \
    && asset="$(python3 -I "$here/github_release_asset.py" "$url")" && [[ -n "$asset" ]]; then
  if curl -fsSL "$@" -K <(printf 'header = "Authorization: Bearer %s"\n' "$secret") \
      -H 'Accept: application/octet-stream' -o "$out" "$asset"; then
    exit 0
  fi
  echo "github-release-download: the API copy of $url failed; trying the download URL" >&2
fi
exec curl -fsSL "$@" -o "$out" "$url"
