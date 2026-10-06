#!/usr/bin/env bash
set -euo pipefail

# Publish one fleet-built cmux dev archive and its Sparkle feed. The worker
# supplies the private key and R2 credentials through a root-owned secret file;
# this script never prints either value.

if [[ $# -ne 3 ]]; then
  echo "usage: publish-dev-build.sh <app-path> <archive-path> <metadata-path>" >&2
  exit 2
fi

APP_PATH="$1"
ARCHIVE_PATH="$2"
METADATA_PATH="$3"
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

: "${CMUX_DEV_BUILD_TRACK:?CMUX_DEV_BUILD_TRACK is required}"
: "${CMUX_DEV_BUILD_SHA:?CMUX_DEV_BUILD_SHA is required}"
: "${CMUX_DEV_BUILD_BRANCH:?CMUX_DEV_BUILD_BRANCH is required}"
: "${CMUX_DEV_R2_ENDPOINT:?CMUX_DEV_R2_ENDPOINT is required}"
: "${CMUX_DEV_R2_BUCKET:?CMUX_DEV_R2_BUCKET is required}"
: "${CMUX_DEV_R2_PUBLIC_BASE:?CMUX_DEV_R2_PUBLIC_BASE is required}"
: "${CMUX_DEV_SPARKLE_PRIVATE_KEY:?CMUX_DEV_SPARKLE_PRIVATE_KEY is required}"

case "$CMUX_DEV_BUILD_TRACK" in
  classic|next) ;;
  *) echo "error: unsupported dev build track '$CMUX_DEV_BUILD_TRACK'" >&2; exit 2 ;;
esac
[[ "$CMUX_DEV_BUILD_SHA" =~ ^[0-9a-f]{40}$ ]] || { echo "error: invalid dev build SHA" >&2; exit 2; }
[[ -d "$APP_PATH/Contents" && -f "$ARCHIVE_PATH" ]] || { echo "error: dev build inputs are missing" >&2; exit 1; }

plist_value() {
  /usr/libexec/PlistBuddy -c "Print :$1" "$APP_PATH/Contents/Info.plist"
}

version="$(plist_value CFBundleVersion)"
short_version="$(plist_value CFBundleShortVersionString)"
bundle_id="$(plist_value CFBundleIdentifier)"
[[ "$bundle_id" == "com.cmuxterm.app.dev" ]] || {
  echo "error: dev archive has bundle id '$bundle_id', expected com.cmuxterm.app.dev" >&2
  exit 1
}
[[ "$version" =~ ^[0-9]+$ ]] || { echo "error: dev build version is not numeric" >&2; exit 1; }

archive_name="cmux-${CMUX_DEV_BUILD_TRACK}-${CMUX_DEV_BUILD_SHA:0:12}.zip"
public_root="${CMUX_DEV_R2_PUBLIC_BASE%/}/${CMUX_DEV_BUILD_TRACK}"
immutable_prefix="cmux-dev/${CMUX_DEV_BUILD_TRACK}/builds/${CMUX_DEV_BUILD_SHA}"
work_dir="$(mktemp -d "${TMPDIR:-/tmp}/cmux-dev-publish.XXXXXX")"
trap 'rm -rf "$work_dir"' EXIT

named_archive="$work_dir/$archive_name"
cp -p "$ARCHIVE_PATH" "$named_archive"
appcast="$work_dir/appcast.xml"
download_prefix="$public_root/builds/${CMUX_DEV_BUILD_SHA}/"
release_notes="https://github.com/manaflow-ai/cmux/commit/${CMUX_DEV_BUILD_SHA}"
SPARKLE_PRIVATE_KEY="$CMUX_DEV_SPARKLE_PRIVATE_KEY" \
  DOWNLOAD_URL_PREFIX="$download_prefix" \
  RELEASE_NOTES_URL="$release_notes" \
  SPARKLE_MAXIMUM_DELTAS=0 \
  "$ROOT_DIR/scripts/sparkle_generate_appcast.sh" "$named_archive" "$version" "$appcast"

upload() {
  local file="$1" key="$2" type="$3" write_once="${4:-0}"
  local args=(
    --file "$file"
    --endpoint-url "$CMUX_DEV_R2_ENDPOINT"
    --bucket "$CMUX_DEV_R2_BUCKET"
    --key "$key"
    --content-type "$type"
    --cache-control "no-cache, no-store, must-revalidate"
  )
  [[ "$write_once" == 1 ]] && args+=(--write-once)
  AWS_DEFAULT_REGION=auto python3 "$ROOT_DIR/scripts/ci/upload-r2-object.py" "${args[@]}"
}

upload "$named_archive" "$immutable_prefix/$archive_name" application/zip 1
# Keep one non-track-specific recovery alias valid for updater failures where
# the app does not retain its track metadata. The per-track immutable URL
# remains the canonical link shown on the stable page.
upload "$named_archive" "cmux-dev/latest.zip" application/zip 0
upload "$appcast" "cmux-dev/${CMUX_DEV_BUILD_TRACK}/appcast.xml" application/xml 0

metadata="$work_dir/build.json"
title="${CMUX_DEV_BUILD_TITLE:-}"
if [[ -z "$title" ]]; then
  title="$(git -C "$ROOT_DIR" show -s --format=%s "$CMUX_DEV_BUILD_SHA" 2>/dev/null || true)"
fi
CMUX_DEV_BUILD_METADATA_OUT="$metadata" \
  CMUX_DEV_BUILD_ARCHIVE_URL="$download_prefix$archive_name" \
  CMUX_DEV_BUILD_APPCAST_URL="$public_root/appcast.xml" \
  CMUX_DEV_BUILD_VERSION="$version" \
  CMUX_DEV_BUILD_SHORT_VERSION="$short_version" \
  CMUX_DEV_BUILD_ARCHIVE_NAME="$archive_name" \
  CMUX_DEV_BUILD_TITLE="$title" \
  python3 - "$metadata" <<'PY'
import json
import os
import sys
from datetime import datetime, timezone

payload = {
    "track": os.environ["CMUX_DEV_BUILD_TRACK"],
    "sha": os.environ["CMUX_DEV_BUILD_SHA"],
    "branch": os.environ["CMUX_DEV_BUILD_BRANCH"],
    "title": os.environ.get("CMUX_DEV_BUILD_TITLE", ""),
    "pr_url": os.environ.get("CMUX_DEV_BUILD_PR_URL", ""),
    "version": os.environ["CMUX_DEV_BUILD_VERSION"],
    "short_version": os.environ["CMUX_DEV_BUILD_SHORT_VERSION"],
    "archive": os.environ["CMUX_DEV_BUILD_ARCHIVE_URL"],
    "archive_name": os.environ["CMUX_DEV_BUILD_ARCHIVE_NAME"],
    "appcast": os.environ["CMUX_DEV_BUILD_APPCAST_URL"],
    "published_at": datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
}
with open(sys.argv[1], "w", encoding="utf-8") as stream:
    json.dump(payload, stream, indent=2, sort_keys=True)
    stream.write("\n")
PY

# Each track owns its small index. The stable top-level page is static and
# reads both indexes, so classic and next jobs never overwrite one another.
existing="$work_dir/existing.json"
if ! curl --fail --silent --show-error --max-time 15 "$public_root/index.json" -o "$existing"; then
  printf '{"track":%s,"builds":[]}' "$(python3 -c 'import json,sys; print(json.dumps(sys.argv[1]))' "$CMUX_DEV_BUILD_TRACK")" > "$existing"
fi
index="$work_dir/index.json"
python3 - "$existing" "$metadata" "$index" <<'PY'
import json, sys
old = json.load(open(sys.argv[1], encoding="utf-8"))
new = json.load(open(sys.argv[2], encoding="utf-8"))
rows = [new] + [row for row in old.get("builds", []) if row.get("sha") != new["sha"]]
json.dump({"track": new["track"], "builds": rows[:20]}, open(sys.argv[3], "w", encoding="utf-8"), indent=2, sort_keys=True)
open(sys.argv[3], "a", encoding="utf-8").write("\n")
PY
upload "$index" "cmux-dev/${CMUX_DEV_BUILD_TRACK}/index.json" application/json 0

page="$work_dir/index.html"
cat > "$page" <<'HTML'
<!doctype html>
<meta charset="utf-8">
<title id="page-title"></title>
<meta name="viewport" content="width=device-width,initial-scale=1">
<style>body{font:15px system-ui,sans-serif;max-width:900px;margin:40px auto;padding:0 20px;color:#17202a}table{border-collapse:collapse;width:100%}th,td{text-align:left;padding:9px;border-bottom:1px solid #ddd}code{font-family:ui-monospace,monospace}</style>
<h1 id="heading"></h1>
<p id="subtitle"></p>
<div id="builds"></div>
<script>
const translations = {
  en: {heading:'cmux dev builds',subtitle:'Fleet builds from green merges. Each track updates itself through Sparkle.',loading:'Loading…',commit:'Commit',title:'Title',published:'Published',download:'Download',zip:'zip'},
  ja: {heading:'cmux 開発ビルド',subtitle:'グリーンマージから作成されたフリートビルドです。各トラックは Sparkle で自動更新されます。',loading:'読み込み中…',commit:'コミット',title:'タイトル',published:'公開日時',download:'ダウンロード',zip:'zip'},
  'zh-CN': {heading:'cmux 开发版本',subtitle:'来自绿色合并的舰队构建。每个轨道都会通过 Sparkle 自动更新。',loading:'正在加载…',commit:'提交',title:'标题',published:'发布时间',download:'下载',zip:'zip'},
  'zh-TW': {heading:'cmux 開發版本',subtitle:'來自綠色合併的艦隊建置。每個軌道都會透過 Sparkle 自動更新。',loading:'載入中…',commit:'提交',title:'標題',published:'發布時間',download:'下載',zip:'zip'},
  ko: {heading:'cmux 개발 빌드',subtitle:'통과한 병합에서 생성된 fleet 빌드입니다. 각 트랙은 Sparkle로 자동 업데이트됩니다.',loading:'로드 중…',commit:'커밋',title:'제목',published:'게시됨',download:'다운로드',zip:'zip'},
  de: {heading:'cmux Entwicklungs-Builds',subtitle:'Fleet-Builds aus grünen Merges. Jeder Track aktualisiert sich über Sparkle.',loading:'Wird geladen…',commit:'Commit',title:'Titel',published:'Veröffentlicht',download:'Download',zip:'zip'},
  es: {heading:'Compilaciones de desarrollo de cmux',subtitle:'Compilaciones del fleet a partir de merges correctos. Cada pista se actualiza con Sparkle.',loading:'Cargando…',commit:'Commit',title:'Título',published:'Publicado',download:'Descarga',zip:'zip'},
  fr: {heading:'Builds de développement cmux',subtitle:'Builds du fleet issus de merges réussis. Chaque piste se met à jour avec Sparkle.',loading:'Chargement…',commit:'Commit',title:'Titre',published:'Publié',download:'Téléchargement',zip:'zip'},
  it: {heading:'Build di sviluppo cmux',subtitle:'Build del fleet dai merge riusciti. Ogni traccia si aggiorna tramite Sparkle.',loading:'Caricamento…',commit:'Commit',title:'Titolo',published:'Pubblicato',download:'Download',zip:'zip'},
  da: {heading:'cmux-udviklingsbuilds',subtitle:'Fleet-builds fra vellykkede merges. Hvert spor opdateres via Sparkle.',loading:'Indlæser…',commit:'Commit',title:'Titel',published:'Udgivet',download:'Download',zip:'zip'},
  pl: {heading:'Wersje deweloperskie cmux',subtitle:'Buildy floty z udanych merge. Każdy kanał aktualizuje się przez Sparkle.',loading:'Ładowanie…',commit:'Commit',title:'Tytuł',published:'Opublikowano',download:'Pobierz',zip:'zip'},
  ru: {heading:'Сборки cmux для разработки',subtitle:'Сборки флота из успешных слияний. Каждый канал обновляется через Sparkle.',loading:'Загрузка…',commit:'Коммит',title:'Название',published:'Опубликовано',download:'Скачать',zip:'zip'},
  bs: {heading:'cmux razvojne verzije',subtitle:'Fleet verzije iz uspješnih spajanja. Svaki kanal se ažurira putem Sparklea.',loading:'Učitavanje…',commit:'Commit',title:'Naslov',published:'Objavljeno',download:'Preuzimanje',zip:'zip'},
  ar: {heading:'إصدارات cmux التطويرية',subtitle:'إصدارات الأسطول من عمليات الدمج الناجحة. يتم تحديث كل مسار عبر Sparkle.',loading:'جار التحميل…',commit:'الإيداع',title:'العنوان',published:'تاريخ النشر',download:'التنزيل',zip:'zip'},
  no: {heading:'cmux-utviklingsbygg',subtitle:'Fleet-bygg fra vellykkede merges. Hvert spor oppdateres gjennom Sparkle.',loading:'Laster inn…',commit:'Commit',title:'Tittel',published:'Publisert',download:'Last ned',zip:'zip'},
  'pt-BR': {heading:'Builds de desenvolvimento do cmux',subtitle:'Builds do fleet de merges aprovados. Cada trilha é atualizada pelo Sparkle.',loading:'Carregando…',commit:'Commit',title:'Título',published:'Publicado',download:'Download',zip:'zip'},
  th: {heading:'บิลด์พัฒนา cmux',subtitle:'บิลด์จาก fleet ที่มาจากการผสานสำเร็จ แต่ละแทร็กอัปเดตผ่าน Sparkle',loading:'กำลังโหลด…',commit:'คอมมิต',title:'ชื่อเรื่อง',published:'เผยแพร่แล้ว',download:'ดาวน์โหลด',zip:'zip'},
  tr: {heading:'cmux geliştirme derlemeleri',subtitle:'Başarılı birleştirmelerden fleet derlemeleri. Her kanal Sparkle ile güncellenir.',loading:'Yükleniyor…',commit:'Commit',title:'Başlık',published:'Yayınlandı',download:'İndir',zip:'zip'},
  km: {heading:'ប៊ីលដ៍អភិវឌ្ឍន៍ cmux',subtitle:'ប៊ីលដ៍ fleet ពីការរួមបញ្ចូលដែលជោគជ័យ។ បទនីមួយៗធ្វើបច្ចុប្បន្នភាពតាម Sparkle។',loading:'កំពុងផ្ទុក…',commit:'Commit',title:'ចំណងជើង',published:'បានផ្សព្វផ្សាយ',download:'ទាញយក',zip:'zip'},
  uk: {heading:'Розробницькі збірки cmux',subtitle:'Збірки флоту з успішних злиттів. Кожен канал оновлюється через Sparkle.',loading:'Завантаження…',commit:'Коміт',title:'Назва',published:'Опубліковано',download:'Завантажити',zip:'zip'}
};
const requested = (navigator.languages || [navigator.language || 'en']).map(x => x.replace('_','-'));
const locale = requested.find(x => translations[x]) || requested.map(x => x.split('-')[0]).find(x => translations[x]) || 'en';
const text = translations[locale];
document.documentElement.lang = locale;
document.querySelector('#page-title').textContent = text.heading;
document.querySelector('#heading').textContent = text.heading;
document.querySelector('#subtitle').textContent = text.subtitle;
document.querySelector('#builds').textContent = text.loading;
const esc = s => String(s ?? '').replace(/[&<>"']/g, c => ({'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;',"'":'&#39;'}[c]));
Promise.all(['classic','next'].map(track => fetch(`${track}/index.json`, {cache:'no-store'}).then(r => r.json()).then(x => [track,x]).catch(() => [track,{builds:[]}]))).then(all => {
  document.querySelector('#builds').innerHTML = all.map(([track,data]) => `<h2>${esc(track)}</h2><table><tr><th>${text.commit}</th><th>${text.title}</th><th>${text.published}</th><th>${text.download}</th></tr>${(data.builds||[]).map(b => `<tr><td><code>${esc(b.sha.slice(0,12))}</code></td><td>${esc(b.title)}</td><td>${esc(b.published_at)}</td><td><a href="${esc(b.archive)}">${text.zip}</a></td></tr>`).join('')}</table>`).join('');
});
</script>
HTML
upload "$page" cmux-dev/index.html text/html 0

cp -p "$metadata" "$METADATA_PATH"
echo "Published cmux dev ${CMUX_DEV_BUILD_TRACK} ${CMUX_DEV_BUILD_SHA:0:12}: ${CMUX_DEV_BUILD_ARCHIVE_URL}"
