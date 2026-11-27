#!/usr/bin/env bash
# r2-cache.sh save: an archive above CI_CACHE_R2_MULTIPART_BYTES goes up as a multipart upload that
# reassembles byte for byte, and a smaller one still takes the single conditional PUT. A fake curl
# plays the bucket.
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
script="$here/../r2-cache.sh"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

mkdir -p "$tmp/bin" "$tmp/bucket"
cat > "$tmp/bin/curl" <<'FAKE'
#!/usr/bin/env bash
# Enough of curl and an S3 bucket for r2-cache.sh save.
set -euo pipefail
cat > /dev/null # the credentials config on stdin
method=GET out=/dev/null dump="" upload="" data="" url=""
while (($#)); do
  case "$1" in
    --head) method=HEAD ;;
    -X) method="$2"; shift ;;
    -o) out="$2"; shift ;;
    --dump-header) dump="$2"; shift ;;
    -T) upload="$2"; [[ "$method" == GET ]] && method=PUT; shift ;;
    --data-binary) data="$2"; shift ;;
    -H|-w|--config|--retry|--retry-delay|--connect-timeout|--max-time|--aws-sigv4) shift ;;
    -*) ;;
    *) url="$1" ;;
  esac
  shift
done
[[ "$method" == GET && -n "$data" ]] && method=POST
b="$FAKE_BUCKET"
path="${url#*://*/}"; query=""; [[ "$path" == *\?* ]] && query="${path#*\?}" && path="${path%%\?*}"
obj="$b/$(printf '%s' "$path" | tr '/' '_')"
echo "$method $path${query:+?$query}" >> "$b/log"
code=200
case "$method" in
  HEAD) if [[ -f "$obj" ]]; then
          [[ -z "$dump" ]] || printf 'etag: "x"\r\nx-amz-meta-generation: 77\r\n' > "$dump"
        else code=404; fi ;;
  POST) if [[ "$query" == uploads= ]]; then
          echo '<InitiateMultipartUploadResult><UploadId>id+/=</UploadId></InitiateMultipartUploadResult>' > "$out"
        elif [[ "$query" == uploadId=id%2B%2F%3D ]]; then
          cp "${data#@}" "$b/complete.xml"
          : > "$obj"
          for part in $(ls "$b/parts" | sort -n); do cat "$b/parts/$part" >> "$obj"; done
          echo '<CompleteMultipartUploadResult/>' > "$out"
        else code=400; fi ;;
  PUT) if [[ "$query" == partNumber=*'&uploadId=id%2B%2F%3D' ]]; then
         n="${query#partNumber=}"; n="${n%%&*}"
         mkdir -p "$b/parts"; cp "$upload" "$b/parts/$n"
         [[ -z "$dump" ]] || printf 'etag: "e%s"\r\n' "$n" > "$dump"
       elif [[ -z "$query" ]]; then
         [[ "$(wc -c < "$upload")" -le "${FAKE_PUT_LIMIT:-999999999}" ]] || code=400
         [[ "$code" != 200 ]] || cp "$upload" "$obj"
       else code=400; fi ;;
  DELETE) echo aborted >> "$b/log" ;;
esac
printf '%s' "$code"
FAKE
chmod +x "$tmp/bin/curl"

export PATH="$tmp/bin:$PATH" FAKE_BUCKET="$tmp/bucket" GITHUB_RUN_ID=77 RUNNER_OS=Linux RUNNER_ARCH=X64
export CI_CACHE_R2_ENDPOINT=https://r2.example CI_CACHE_R2_BUCKET=bkt CI_CACHE_R2_PUBLIC_URL=https://pub.example
export AWS_ACCESS_KEY_ID=k AWS_SECRET_ACCESS_KEY=s CI_CACHE_R2_SAVE_HEADROOM_KIB=0

mkdir -p "$tmp/dir"
head -c 3000000 /dev/urandom > "$tmp/dir/blob"

# 1. Over the threshold, one part (parts are at least 5 MiB). The fake bucket refuses a single PUT
#    that large, as R2 refuses one over 5 GiB.
FAKE_PUT_LIMIT=1000 CI_CACHE_R2_MULTIPART_BYTES=1000 CI_CACHE_R2_PART_BYTES=5242880 \
  bash "$script" save "$tmp/dir" big-key-1 > "$tmp/out1" 2>&1
grep -q 'r2-cache: saved big-key-1' "$tmp/out1" || { cat "$tmp/out1" "$tmp/bucket/log"; echo "FAIL: big save"; exit 1; }
grep -q 'uploaded 1 parts' "$tmp/out1" || { cat "$tmp/out1"; echo "FAIL: expected 1 part at 5 MiB parts"; exit 1; }
obj="$tmp/bucket/bkt_v1_Linux-X64_objects_big-key-1.tar.zst"
[[ -f "$obj" ]] || obj="${obj%.tar.zst}.tar.gz"
mkdir "$tmp/back1"
if [[ "$obj" == *.zst ]]; then zstd -dc "$obj" | tar -xf - -C "$tmp/back1"; else tar -xzf "$obj" -C "$tmp/back1"; fi
cmp "$tmp/dir/blob" "$tmp/back1/blob" || { echo "FAIL: multipart object does not reassemble"; exit 1; }
grep -q '^PUT bkt/v1/Linux-X64/latest/big-' "$tmp/bucket/log" || { echo "FAIL: pointer not published"; exit 1; }
! grep -q aborted "$tmp/bucket/log" || { echo "FAIL: upload aborted"; exit 1; }

# 2. Three parts (5 MiB, 5 MiB, the rest of 12 MB of incompressible bytes), listed in order.
head -c 12000000 /dev/urandom > "$tmp/dir/blob"
rm -rf "$tmp/bucket"/*
FAKE_PUT_LIMIT=1000 CI_CACHE_R2_MULTIPART_BYTES=1000 CI_CACHE_R2_PART_BYTES=5242880 \
  bash "$script" save "$tmp/dir" big-key-2 > "$tmp/out2" 2>&1
grep -q 'uploaded 3 parts' "$tmp/out2" || { cat "$tmp/out2" "$tmp/bucket/log"; echo "FAIL: expected 3 parts"; exit 1; }
grep -q '<Part><PartNumber>1</PartNumber><ETag>"e1"</ETag></Part><Part><PartNumber>2</PartNumber><ETag>"e2"</ETag></Part><Part><PartNumber>3</PartNumber>' \
  "$tmp/bucket/complete.xml" || { cat "$tmp/bucket/complete.xml"; echo "FAIL: completion body"; exit 1; }
obj="$(ls "$tmp/bucket"/bkt_v1_Linux-X64_objects_big-key-2.*)"
mkdir "$tmp/back2"
if [[ "$obj" == *.zst ]]; then zstd -dc "$obj" | tar -xf - -C "$tmp/back2"; else tar -xzf "$obj" -C "$tmp/back2"; fi
cmp "$tmp/dir/blob" "$tmp/back2/blob" || { echo "FAIL: 3-part object does not reassemble"; exit 1; }

# 3. Under the threshold: one conditional PUT, no multipart calls.
rm -rf "$tmp/bucket"/*
bash "$script" save "$tmp/dir" small-key > "$tmp/out3" 2>&1
grep -q 'r2-cache: saved small-key' "$tmp/out3" || { cat "$tmp/out3"; echo "FAIL: small save"; exit 1; }
! grep -q 'uploads=\|partNumber=' "$tmp/bucket/log" || { echo "FAIL: small save went multipart"; exit 1; }

echo "PASS r2-cache-multipart"
