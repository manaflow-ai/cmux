# The signed Linux release file, read by the Linux installers (cmuxterm-hq
# docs/design/linux-signed-packages.md, sections 2 and 4).
#
# The one source of the function set web/public/tui/install-static.sh and
# cmux-tui/scripts/machine-join.sh carry inline: edit it here, then run
#   python3 cmux-tui/scripts/linux-release-verify-gen.py
# which writes it, and the public keys from
# Packages/macOS/CmuxNext/Sources/CmuxNextUpdater/Resources/web-update-keys.json,
# between the "linux-release-verify" markers of both scripts.
# cmux-tui/scripts/linux-release-verify.test.sh fails when a copy differs.
#
# The caller sets clr_dir (a private directory, umask 077) and clr_state (the
# installed.json path), then:
#   clr_tools                        OpenSSL 3 and a sha256 tool, or refuse
#   clr_release pointer CHANNEL      channels/linux-CHANNEL.json, verified
#   clr_release commit SHA [pinned]  <SHA>/release.json, verified; pinned: an
#                                    explicit version, so a lower sequence is allowed
#                                    (either sets clr_fetched once the file downloaded)
#   clr_has TARGET NAME              whether the verified file names that binary
#   clr_download TARGET NAME OUT     that binary, capped at its signed size, checked
#   clr_record                       the installed version and sequence to clr_state
# Each returns 1 after setting clr_why (what failed) and clr_next (what to do);
# clr_report prints both, `next:` last. Nothing here trusts a byte it did not
# verify: the envelope's signature is checked by an embedded key before any
# payload field is read.
clr_files="https://files.cmux.com/cmux-tui"
# Whatever the release file says, no download is larger than this.
clr_cap=536870912
clr_why=""
clr_next=""

clr_refuse() { # WHY NEXT
  clr_why="$1"
  clr_next="$2"
  return 1
}

clr_report() {
  printf '%s: %s\n' "${clr_who:-cmux}" "$clr_why" >&2
  printf 'next: %s\n' "$clr_next" >&2
}

# FILE (JSON with no escapes) to one "path<TAB>value" line per scalar,
# path the keys joined by "." (array items by index). Fails on a key with a
# "." or a tab in it, an escape, or anything it cannot read.
clr_flatten() {
  if grep -q '[\\	]' "$1"; then
    return 1
  fi
  awk 'BEGIN { RS = "\001" }
function path(  p, j) { p = ""; for (j = 1; j <= d; j++) p = p (j > 1 ? "." : "") nm[j]; return p }
{
  s = $0; n = length(s); d = 0; ek = 0; i = 1
  while (i <= n) {
    c = substr(s, i, 1)
    if (c == " " || c == "\n" || c == "\r" || c == ":") { i++; continue }
    if (c == "{") { d++; ty[d] = "o"; ek = 1; i++; continue }
    if (c == "[") { d++; ty[d] = "a"; nm[d] = 0; ek = 0; i++; continue }
    if (c == "}" || c == "]") { if (d < 1) exit 2; d--; ek = 0; i++; continue }
    if (c == ",") { if (d < 1) exit 2; if (ty[d] == "o") ek = 1; else nm[d]++; i++; continue }
    if (d < 1) exit 2
    if (c == "\"") {
      j = index(substr(s, i + 1), "\"")
      if (j == 0) exit 2
      v = substr(s, i + 1, j - 1); i += j + 1
      if (ek) { if (index(v, ".")) exit 2; nm[d] = v; ek = 0; continue }
      print path() "\t" v; continue
    }
    if (ek) exit 2
    if (!match(substr(s, i), /^[-+.0-9A-Za-z]+/)) exit 2
    print path() "\t" substr(s, i, RLENGTH); i += RLENGTH
  }
  if (d != 0) exit 2
}' "$1"
}

clr_get() { # FLAT PATH: the value at PATH, or nothing
  awk -F '	' -v k="$2" '$1 == k { print $2; exit }' "$1"
}

clr_sha() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" | awk '{print $1}'
  else
    openssl dgst -sha256 "$1" | sed 's/.*= *//'
  fi
}

clr_size() { wc -c <"$1" | tr -d ' '; }

clr_tools() {
  clr_v="$(openssl version 2>/dev/null || true)"
  case "$clr_v" in
    "OpenSSL "[3-9].* | "OpenSSL "[1-9][0-9].*) ;;
    *)
      clr_refuse "the signed release file needs OpenSSL 3 to check its Ed25519 signature, and this host has ${clr_v:-no openssl}; nothing was installed" \
        "install OpenSSL 3 (the openssl package: Ubuntu 22.04, Debian 12, RHEL 9 and newer ship it), then run this again"
      return 1
      ;;
  esac
  command -v awk >/dev/null 2>&1 || {
    clr_refuse "awk is required to read the signed release file" "install awk, then run this again"
    return 1
  }
}

# URL OUT CAP: at most CAP bytes at URL into OUT. 0 on success; 3 when the
# response runs past CAP (cut off at CAP + 1 bytes); else curl's exit. A
# dropped connection is retried, 4 tries with waits of 2, 8 and 20 s; an
# HTTP status (curl's 22) is an answer.
clr_curl() {
  for clr_wait in 2 8 20 ''; do
    rm -f "$2.rc"
    { curl --proto '=https' --proto-redir '=https' --tlsv1.2 -fsSL --max-filesize "$3" "$1" ||
      echo "$?" >"$2.rc"; } | head -c "$(($3 + 1))" >"$2"
    if [ "$(clr_size "$2")" -gt "$3" ]; then
      return 3
    fi
    clr_rc=0
    [ ! -f "$2.rc" ] || clr_rc="$(cat "$2.rc")"
    case "$clr_rc" in
      0) return 0 ;;
      63) return 3 ;;
      5 | 6 | 7 | 18 | 28 | 35 | 52 | 55 | 56) [ -n "$clr_wait" ] || return "$clr_rc" ;;
      *) return "$clr_rc" ;;
    esac
    printf '%s: the network dropped %s (curl exit %s); retrying in %s s\n' "${clr_who:-cmux}" "$1" "$clr_rc" "$clr_wait" >&2
    sleep "$clr_wait"
  done
}

# FILE: the payload of the envelope in FILE, to $clr_dir/payload, when a
# signature by an embedded key covers it.
clr_verify_envelope() {
  clr_flatten "$1" >"$clr_dir/envelope.flat" || {
    clr_refuse "$2 is not a signed release envelope" "$3"
    return 1
  }
  [ "$(clr_get "$clr_dir/envelope.flat" schema)" = 1 ] || {
    clr_refuse "$2 has an unknown envelope schema" "$3"
    return 1
  }
  clr_b64="$(clr_get "$clr_dir/envelope.flat" payload)"
  case "$clr_b64" in
    '' | *[!A-Za-z0-9+/=]*)
      clr_refuse "$2 has no payload" "$3"
      return 1
      ;;
  esac
  printf '%s' "$clr_b64" | openssl base64 -d -A >"$clr_dir/payload" 2>/dev/null || {
    clr_refuse "$2 has a payload that is not base64" "$3"
    return 1
  }
  clr_good=""
  awk -F '	' '$1 ~ /^signatures\.[0-9]+\.key_id$/ { sub(/\.key_id$/, "", $1); print $1 "\t" $2 }' \
    "$clr_dir/envelope.flat" >"$clr_dir/sigs"
  while IFS='	' read -r clr_at clr_key_id; do
    clr_pub="$(clr_keys | awk -v k="$clr_key_id" '$1 == k { print $2; exit }')"
    [ -n "$clr_pub" ] || continue
    clr_sig="$(clr_get "$clr_dir/envelope.flat" "$clr_at.sig")"
    case "$clr_sig" in
      '' | *[!A-Za-z0-9+/=]*) continue ;;
    esac
    printf '%s\n%s\n%s\n' '-----BEGIN PUBLIC KEY-----' "$clr_pub" '-----END PUBLIC KEY-----' >"$clr_dir/key.pem"
    printf '%s' "$clr_sig" | openssl base64 -d -A >"$clr_dir/sig" 2>/dev/null || continue
    if openssl pkeyutl -verify -pubin -inkey "$clr_dir/key.pem" -rawin -in "$clr_dir/payload" \
      -sigfile "$clr_dir/sig" >/dev/null 2>&1; then
      clr_good="$clr_key_id"
      break
    fi
  done <"$clr_dir/sigs"
  [ -n "$clr_good" ] || {
    clr_refuse "$2 is not signed by a cmux release key this installer trusts; nothing was installed" \
      "do not install from this file; report it at https://github.com/manaflow-ai/cmux/issues (or get a newer installer if cmux rotated its keys)"
    return 1
  }
}

# pointer CHANNEL | commit SHA [pinned]
clr_release() {
  clr_pinned=""
  clr_fetched=""
  if [ "$1" = pointer ]; then
    case "$2" in
      stable | nightly | feat-cmux-next) ;;
      *)
        clr_refuse "no signed release channel $2" "pick stable, nightly or feat-cmux-next"
        return 1
        ;;
    esac
    clr_url="$clr_files/channels/linux-$2.json"
    clr_what="the $2 channel's signed release file ($clr_url)"
    clr_again="run this again in a few minutes; if it keeps failing, report it at https://github.com/manaflow-ai/cmux/issues"
  else
    case "$2" in
      *[!0-9a-f]* | '') clr_refuse "$2 is not a 40-character lowercase hex commit" "pass the full commit"; return 1 ;;
    esac
    [ "${#2}" -eq 40 ] || { clr_refuse "$2 is not a 40-character lowercase hex commit" "pass the full commit"; return 1; }
    [ "${3:-}" != pinned ] || clr_pinned=1
    clr_url="$clr_files/$2/release.json"
    clr_what="the signed release file of $2 ($clr_url)"
    clr_again="pick a commit published with a signed release file, or install the default channel without one"
  fi
  clr_rc=0
  clr_curl "$clr_url" "$clr_dir/release.json" 65536 || clr_rc=$?
  case "$clr_rc" in
    0) ;;
    3) clr_refuse "$clr_what is larger than 64 KiB; nothing was installed" "$clr_again"; return 1 ;;
    22) clr_refuse "$clr_what is not published" "$clr_again"; return 1 ;;
    *) clr_refuse "cannot download $clr_what (curl exit $clr_rc)" "check this machine's outbound HTTPS to files.cmux.com, then run this again"; return 1 ;;
  esac
  clr_fetched=1
  clr_verify_envelope "$clr_dir/release.json" "$clr_what" "$clr_again" || return 1
  clr_p="$clr_dir/release.flat"
  clr_flatten "$clr_dir/payload" >"$clr_p" || {
    clr_refuse "$clr_what has a payload this installer cannot read" "get a newer installer, then run it again"
    return 1
  }
  if [ -n "$(cut -f 1 "$clr_p" | sort | uniq -d)" ]; then
    clr_refuse "$clr_what names a field twice" "$clr_again"
    return 1
  fi
  [ "$(clr_get "$clr_p" schema)" = 1 ] || { clr_refuse "$clr_what has an unknown payload schema" "get a newer installer, then run it again"; return 1; }
  [ "$(clr_get "$clr_p" purpose)" = cmux-linux-release ] || {
    clr_refuse "$clr_what is not a Linux release file (purpose $(clr_get "$clr_p" purpose))" "$clr_again"
    return 1
  }
  clr_channel="$(clr_get "$clr_p" channel)"
  clr_commit="$(clr_get "$clr_p" commit)"
  clr_version="$(clr_get "$clr_p" version)"
  clr_tree_key="$(clr_get "$clr_p" tree_key)"
  if [ "$1" = pointer ]; then
    [ "$clr_channel" = "$2" ] || { clr_refuse "$clr_what is for the channel $clr_channel" "$clr_again"; return 1; }
    clr_exp="$(clr_get "$clr_p" expires_at)"
    case "$clr_exp" in '' | *[!0-9]*) clr_refuse "$clr_what has no expiry" "$clr_again"; return 1 ;; esac
    if [ "$clr_exp" -le "$(date +%s)" ]; then
      clr_refuse "$clr_what expired at $clr_exp (a stale copy, or the channel stopped publishing); nothing was installed" \
        "check this machine's clock; if it is right, report it at https://github.com/manaflow-ai/cmux/issues"
      return 1
    fi
  else
    [ "$clr_commit" = "$2" ] || { clr_refuse "$clr_what is for the commit $clr_commit" "$clr_again"; return 1; }
    case "$clr_channel" in
      stable | nightly | feat-cmux-next) ;;
      *) clr_refuse "$clr_what names the unknown channel $clr_channel" "$clr_again"; return 1 ;;
    esac
  fi
  case "$clr_commit" in *[!0-9a-f]* | '') clr_refuse "$clr_what has a bad commit" "$clr_again"; return 1 ;; esac
  [ "${#clr_commit}" -eq 40 ] || { clr_refuse "$clr_what has a bad commit" "$clr_again"; return 1; }
  if [ -n "$clr_tree_key" ]; then
    case "$clr_tree_key" in *[!0-9a-f]*) clr_refuse "$clr_what has a bad tree_key" "$clr_again"; return 1 ;; esac
    [ "${#clr_tree_key}" -eq 40 ] || { clr_refuse "$clr_what has a bad tree_key" "$clr_again"; return 1; }
  fi
  # The order of publication: `sequence`, or for a file from before it (phase 1)
  # the 14-digit stamp in `version`, which every later sequence is at least.
  clr_sequence="$(clr_get "$clr_p" sequence)"
  if [ -z "$clr_sequence" ]; then
    clr_sequence="$(printf '%s\n' "$clr_version" |
      sed -n 's/^[0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*+\([0-9]\{14\}\)\.[0-9a-f]\{12\}$/\1/p')"
  fi
  case "$clr_sequence" in
    [0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9]) ;;
    *) clr_refuse "$clr_what has no sequence" "$clr_again"; return 1 ;;
  esac
  # Every URL under the file's own prefix, one plain file name below it.
  while IFS='	' read -r clr_at clr_u; do
    clr_rest=""
    case "$clr_u" in
      "$clr_files/$clr_commit/"*) clr_rest="${clr_u#"$clr_files/$clr_commit/"}" ;;
      "$clr_files/tree/"*)
        [ -z "$clr_tree_key" ] || case "$clr_u" in "$clr_files/tree/$clr_tree_key/"*) clr_rest="${clr_u#"$clr_files/tree/$clr_tree_key/"}" ;; esac
        ;;
    esac
    case "$clr_rest" in
      '' | [!A-Za-z0-9]* | *[!A-Za-z0-9._+-]*)
        clr_refuse "$clr_what: $clr_at points off its own prefix ($clr_u); nothing was installed" \
          "do not install from this file; report it at https://github.com/manaflow-ai/cmux/issues"
        return 1
        ;;
    esac
  done <<EOF
$(awk -F '	' '$1 ~ /(^|\.)url$/ { print $1 "\t" $2 }' "$clr_p")
EOF
  # A build older than the one installed, unless asked for by version.
  if [ -z "$clr_pinned" ] && [ -f "$clr_state" ]; then
    clr_have=""
    if clr_flatten "$clr_state" >"$clr_dir/state.flat" 2>/dev/null; then
      clr_have="$(clr_get "$clr_dir/state.flat" sequence)"
    fi
    case "$clr_have" in
      [0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9][0-9])
        if [ "$clr_sequence" -lt "$clr_have" ]; then
          clr_refuse "$clr_what is older (sequence $clr_sequence) than the build installed here ($clr_have, $clr_state); nothing was installed" \
            "keep the installed build; to go back on purpose, pass --commit with the commit you want"
          return 1
        fi
        ;;
    esac
  fi
}

clr_has() { # TARGET NAME
  [ -n "$(clr_get "$clr_dir/release.flat" "targets.$1.$2.url")" ]
}

clr_download() { # TARGET NAME OUT
  clr_p="$clr_dir/release.flat"
  clr_u="$(clr_get "$clr_p" "targets.$1.$2.url")"
  clr_want="$(clr_get "$clr_p" "targets.$1.$2.sha256")"
  clr_size="$(clr_get "$clr_p" "targets.$1.$2.size")"
  [ -n "$clr_u" ] || { clr_refuse "the signed release file of $clr_commit has no $2 for $1" "pick another build, or report it at https://github.com/manaflow-ai/cmux/issues"; return 1; }
  # A binary is the file NAME-TARGET; a package (deb, rpm) one cmux-*.deb or cmux-*.rpm.
  case "$2:$clr_u" in
    deb:*/cmux-*.deb | rpm:*/cmux-*.rpm | *:*/"$2-$1") ;;
    deb:* | rpm:*) clr_refuse "the signed release file names $clr_u for the $2 of $1, not a cmux .$2" "report it at https://github.com/manaflow-ai/cmux/issues"; return 1 ;;
    *) clr_refuse "the signed release file names $clr_u for $2 $1, not a file called $2-$1" "report it at https://github.com/manaflow-ai/cmux/issues"; return 1 ;;
  esac
  case "$clr_want" in *[!0-9a-f]* | '') clr_want="" ;; esac
  [ "${#clr_want}" -eq 64 ] || { clr_refuse "the signed release file has no sha256 for $2 $1" "report it at https://github.com/manaflow-ai/cmux/issues"; return 1; }
  case "$clr_size" in *[!0-9]* | '' | 0) clr_size="" ;; esac
  if [ -z "$clr_size" ] || [ "${#clr_size}" -gt 10 ] || [ "$clr_size" -gt "$clr_cap" ]; then
    clr_refuse "the signed release file gives $2 $1 a size of ${clr_size:-nothing}, over the 512 MiB cap" "report it at https://github.com/manaflow-ai/cmux/issues"
    return 1
  fi
  clr_rc=0
  clr_curl "$clr_u" "$3" "$clr_size" || clr_rc=$?
  case "$clr_rc" in
    0) ;;
    3)
      rm -f "$3"
      clr_refuse "$clr_u is larger than its signed size of $clr_size bytes; it was cut off and nothing was installed" \
        "run this again later; if it repeats, report it at https://github.com/manaflow-ai/cmux/issues"
      return 1
      ;;
    *) clr_refuse "cannot download $clr_u (curl exit $clr_rc)" "check this machine's outbound HTTPS to files.cmux.com, then run this again"; return 1 ;;
  esac
  clr_got="$(clr_size "$3")"
  [ "$clr_got" = "$clr_size" ] || {
    rm -f "$3"
    clr_refuse "$clr_u is $clr_got bytes, not its signed $clr_size; nothing was installed" "run this again; if it repeats, report it at https://github.com/manaflow-ai/cmux/issues"
    return 1
  }
  clr_got="$(clr_sha "$3")"
  [ "$clr_got" = "$clr_want" ] || {
    rm -f "$3"
    clr_refuse "$clr_u has sha256 $clr_got, not the signed $clr_want; nothing was installed" \
      "do not install it; run this again later, and report it at https://github.com/manaflow-ai/cmux/issues if it repeats"
    return 1
  }
}

clr_record() {
  mkdir -p "$(dirname "$clr_state")" &&
    printf '{"commit":"%s","sequence":%s,"version":"%s"}\n' "$clr_commit" "$clr_sequence" "$clr_version" \
      >"$clr_state.new" &&
    mv -f "$clr_state.new" "$clr_state"
}
