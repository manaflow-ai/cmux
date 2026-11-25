# shellcheck shell=bash
# Sourced by rust-dev-loop.sh. blaze_home_path REAL prints the path BLAZE_HOME is set to for the blaze home
# REAL: REAL itself when its daemon socket (REAL/v2.sock) fits a Unix socket address, else a link in /tmp to
# it (blaze_home_link). macOS takes at most 104 bytes there (Linux 108): a fleet Mac's step home
# (/Volumes/ephemeral0/cmux-ci/fleet-worker/steps/<id>/home/.cache/...) made a 156-byte socket path, and blaze's
# daemon never started ("path must be shorter than SUN_LEN", step 2b240a0d42ed3a7abd387550). blaze keeps the
# path it is given, so the socket is made under the link while its build state stays on REAL's disk.
# blaze_home_unlink REAL removes that link, only when it points at REAL.
blaze_home_max_socket=100

# Named by REAL's name and a checksum of its path, so two runs with the same pid in different step homes
# never share a link.
blaze_home_link() { echo "/tmp/${1##*/}-$(printf '%s' "$1" | cksum | cut -d' ' -f1)"; }

blaze_home_path() {
  local real="$1" link
  local socket="$real/v2.sock"
  if (( ${#socket} < blaze_home_max_socket )); then
    echo "$real"
    return
  fi
  link="$(blaze_home_link "$real")"
  if [[ -L "$link" && "$(readlink "$link")" != "$real" ]]; then
    rm -f "$link"
  fi
  [[ -L "$link" ]] || ln -s "$real" "$link"
  echo "$link"
}

blaze_home_unlink() {
  local link
  link="$(blaze_home_link "$1")"
  if [[ -L "$link" && "$(readlink "$link")" == "$1" ]]; then
    rm -f "$link"
  fi
}
