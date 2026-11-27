#!/usr/bin/env bash
# Turn the repo archive store on (hq RFD 0065 pieces 1-2, decision d-d301c6c7ba). Run once on the fleet controller,
# as the user the publisher timer runs as, with `gh` signed in to manaflow-ai and cmux-projection on PATH.
#
# 1. Makes an RSA-4096 sealing key in ~/.config/cmux-repo-archive/ (kept: re-running reuses it).
# 2. Dispatches repo-archive-store.yml on feat-cmux-next with its public half and waits for the run. The run creates
#    the R2 bucket cmux-repo-archive if missing, keeps it private, sets its 7-day expiry rule and mints two tokens.
# 3. Downloads the sealed credentials and unseals them here:
#      ~/.config/cmux-repo-archive-publish.env  CMUX_REPO_ARCHIVE_STORE plus the publisher's write keys (0600)
#      ~/.config/cmux-repo-archive-read.env     the store plus a read-only key, for VM images (0600)
#      ~/.config/cmux-repo-archive-vm.json      the same as a VM's /etc/cmux/repo-archive.json ({"store", "access_key_id",
#                                               "secret_access_key"}; cmux-projection reads the key from it) (0600)
# 4. Installs and enables cmux-repo-archive-publish.timer (systemd --user), publishes once, and reads one archive back
#    with the read-only key (repo-archive-fetch of manaflow-ai/cmux into a temp folder).
# Nothing secret is printed. Usage: install-store.sh [--no-timer]
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
conf=${XDG_CONFIG_HOME:-$HOME/.config}
keydir=$conf/cmux-repo-archive
repo=manaflow-ai/cmux
timer=1
[ "${1:-}" = --no-timer ] && timer=0

umask 077
mkdir -p "$keydir"
if ! [ -s "$keydir/seal.pem" ]; then
  openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:4096 -out "$keydir/seal.pem" 2>/dev/null
fi
pub=$(openssl pkey -in "$keydir/seal.pem" -pubout -outform DER | base64 -w0)

before=$(gh run list -R "$repo" -w repo-archive-store.yml -e workflow_dispatch -L 1 --json databaseId --jq '.[0].databaseId // 0')
gh workflow run repo-archive-store.yml -R "$repo" --ref feat-cmux-next -f seal_pubkey="$pub"
run=
for _ in $(seq 1 30); do
  run=$(gh run list -R "$repo" -w repo-archive-store.yml -e workflow_dispatch -L 1 --json databaseId --jq '.[0].databaseId // 0')
  [ "$run" != "$before" ] && [ "$run" != 0 ] && break
  sleep 4
done
[ -n "$run" ] && [ "$run" != "$before" ] || { echo "install-store: the dispatched run never appeared" >&2; exit 1; }
echo "install-store: run $run"
gh run watch "$run" -R "$repo" --exit-status >/dev/null

work=$(mktemp -d)
trap 'rm -rf -- "$work"' EXIT
gh run download "$run" -R "$repo" -n repo-archive-credentials.sealed -D "$work"

unseal() {
  openssl pkeyutl -decrypt -inkey "$keydir/seal.pem" -pkeyopt rsa_padding_mode:oaep \
    -pkeyopt rsa_oaep_md:sha256 -pkeyopt rsa_mgf1_md:sha256 -in "$1"
}
envfile() {  # sealed file -> env lines on stdout
  unseal "$1" | python3 -c 'import json,sys; c=json.load(sys.stdin)
print("CMUX_REPO_ARCHIVE_STORE=" + c["store"])
print("CMUX_PROJECTION_S3_ACCESS_KEY_ID=" + c["access_key_id"])
print("CMUX_PROJECTION_S3_SECRET_ACCESS_KEY=" + c["secret_access_key"])'
}
envfile "$work/repo-archive-write.sealed" > "$conf/cmux-repo-archive-publish.env.new"
mv -f "$conf/cmux-repo-archive-publish.env.new" "$conf/cmux-repo-archive-publish.env"
envfile "$work/repo-archive-read.sealed" > "$conf/cmux-repo-archive-read.env.new"
mv -f "$conf/cmux-repo-archive-read.env.new" "$conf/cmux-repo-archive-read.env"
unseal "$work/repo-archive-read.sealed" | python3 -c 'import json,sys; c=json.load(sys.stdin)
print(json.dumps({"store": c["store"], "access_key_id": c["access_key_id"], "secret_access_key": c["secret_access_key"]}))' \
  > "$conf/cmux-repo-archive-vm.json.new"
mv -f "$conf/cmux-repo-archive-vm.json.new" "$conf/cmux-repo-archive-vm.json"
echo "install-store: wrote $conf/cmux-repo-archive-publish.env, $conf/cmux-repo-archive-read.env and $conf/cmux-repo-archive-vm.json (0600)"

if [ "$timer" = 1 ]; then
  mkdir -p "$conf/systemd/user"
  install -m 0644 "$here/cmux-repo-archive-publish.service" "$here/cmux-repo-archive-publish.timer" "$conf/systemd/user/"
  systemctl --user daemon-reload
  systemctl --user enable --now cmux-repo-archive-publish.timer
  systemctl --user start cmux-repo-archive-publish.service
  echo "install-store: timer enabled; first publish: $(systemctl --user show -p Result --value cmux-repo-archive-publish.service)"
else
  (set -a; . "$conf/cmux-repo-archive-publish.env"; set +a; bash "$here/publish.sh")
fi

# The read-back reads with the VM file's key alone, as a VM does: no key in the environment. /etc/cmux here is the
# controller's, so the file is named by CMUX_PROJECTION_S3_CONFIG, which takes the same keys.
(unset CMUX_PROJECTION_S3_ACCESS_KEY_ID CMUX_PROJECTION_S3_SECRET_ACCESS_KEY
 CMUX_REPO_ARCHIVE_STORE=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["store"])' "$conf/cmux-repo-archive-vm.json") \
 CMUX_PROJECTION_S3_CONFIG=$conf/cmux-repo-archive-vm.json \
 cmux-projection repo-archive-fetch --url "https://github.com/$repo.git" --at "$work/readback")
echo "install-store: read back $repo at $(git -C "$work/readback" rev-parse HEAD) on $(git -C "$work/readback" rev-parse --abbrev-ref HEAD)"
