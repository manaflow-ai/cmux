#!/bin/bash
# Resolve the shared private backend before packaging a tagged development app.
cmux_resolve_tagged_backend() {
  local tag="$1" checkout="$2" url="${CMUX_DEV_BACKEND_URL:-}"
  if [[ -z "$url" ]]; then
    [[ -x "$checkout/scripts/dev-backend.sh" ]] || {
      echo 'Tagged development requires the shared GCP backend helper. Create this checkout through cmuxterm-hq.' >&2
      return 1
    }
    "$checkout/scripts/dev-backend.sh" start --tag "$tag" --checkout "$checkout" --transport direct >&2 || return 1
    url="$("$checkout/scripts/dev-backend.sh" url --tag "$tag")" || return 1
  fi
  case "$url" in
    https://cmux-dev-backend-1.tail137216.ts.net:*) ;;
    *) echo 'Development API URLs must use the shared Tailscale backend.' >&2; return 1 ;;
  esac
  local port="${url#https://cmux-dev-backend-1.tail137216.ts.net:}"
  port="${port%/}"
  [[ "$port" =~ ^[0-9]{4}$ && "$port" -ge 3800 && "$port" -le 4799 ]] || {
    echo 'Development backend URL has an invalid port or path.' >&2; return 1;
  }
  printf 'https://cmux-dev-backend-1.tail137216.ts.net:%s/\n' "$port"
}
