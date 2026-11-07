#!/usr/bin/env bash
# Merges a JSON object (stdin) into one Cloud VM image roll's record, rolls/<ROLL_ID>.json on the
# branch cloud-image-rolls of this repository (cloud-vm-image-roll.yml writes the plan, gate and promotion;
# cmux-vm.yml writes the production smoke and any rollback). A reader needs no API call:
#   git fetch origin cloud-image-rolls && git show FETCH_HEAD:rolls/<id>.json
#
#   echo '{"gate":{"result":"passed"}}' | TOKEN=... images/cmux-vm/image-roll-record.sh ROLL_ID
#
# TOKEN is a contents: write token (the job's GITHUB_TOKEN: its push starts no workflow). It reaches git
# only as an extra header in the environment, never argv or a log. A push that loses a race reads the
# branch again and merges again, at most 5 times; then it fails, and the caller's step says so.
set -euo pipefail
roll="${1:?usage: image-roll-record.sh ROLL_ID < patch.json}"
[[ "$roll" =~ ^[0-9]{1,20}$ ]] || { echo "image-roll-record: bad roll id" >&2; exit 2; }
: "${TOKEN:?TOKEN is required}"
repo="${GITHUB_REPOSITORY:?}"
branch="${CMUX_IMAGE_ROLL_BRANCH:-cloud-image-rolls}"
server="${GITHUB_SERVER_URL:-https://github.com}"
patch="$(mktemp)"
work="$(mktemp -d)"
trap 'rm -rf "$work" "$patch"' EXIT
jq -e 'if type == "object" then . else error("the patch is not a JSON object") end' > "$patch"

export GIT_CONFIG_COUNT=1
export GIT_CONFIG_KEY_0="http.${server}/.extraheader"
GIT_CONFIG_VALUE_0="AUTHORIZATION: basic $(printf 'x-access-token:%s' "$TOKEN" | base64 -w0)"
export GIT_CONFIG_VALUE_0

git -C "$work" init -q
git -C "$work" config user.name "github-actions[bot]"
git -C "$work" config user.email "41898282+github-actions[bot]@users.noreply.github.com"
git -C "$work" remote add origin "${server}/${repo}.git"
file="rolls/${roll}.json"
for attempt in 1 2 3 4 5; do
  if git -C "$work" fetch -q --depth 1 origin "refs/heads/${branch}" 2> /dev/null; then
    git -C "$work" checkout -q -B "$branch" FETCH_HEAD
  else
    # The first record ever: the branch starts as an orphan with only records on it.
    git -C "$work" checkout -q --orphan "$branch"
    git -C "$work" rm -rqf . 2> /dev/null || true
  fi
  mkdir -p "$work/rolls"
  if [ -f "$work/$file" ]; then current="$work/$file"; else current=/dev/null; fi
  # The first record is the patch itself ($cur is [] when there is no file). Objects merge key by key at every
  # depth, so rollback.deploys keeps each attempt; a null in the patch never erases what is recorded (a re-run of
  # a settle that writes "rollback": null keeps the rollback it already recorded).
  jq -n --slurpfile cur "$current" --slurpfile patch "$patch" '
    def merge($a; $b):
      if ($a | type) == "object" and ($b | type) == "object" then
        reduce ($b | keys_unsorted[]) as $k ($a; .[$k] = merge($a[$k]; $b[$k]))
      elif $b == null then $a
      else $b end;
    merge($cur[0] // {}; $patch[0])' > "$work/$file.next"
  mv "$work/$file.next" "$work/$file"
  git -C "$work" add "$file"
  if git -C "$work" diff --cached --quiet; then exit 0; fi
  git -C "$work" commit -q -m "image roll ${roll}: record"
  if git -C "$work" push -q origin "HEAD:refs/heads/${branch}"; then
    echo "image roll ${roll}: record written (${branch}:${file})"
    exit 0
  fi
  echo "image roll ${roll}: the record branch moved; merging again (attempt ${attempt})"
done
echo "image-roll-record: the record branch kept moving; ${file} was not written" >&2
exit 1
