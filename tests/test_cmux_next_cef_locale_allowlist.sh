#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/scripts/cmux-next/cef-locale-allowlist.sh"

allowlist="$(cef_locale_allowlist)"
expect_catalog() {
  local locale="$1" expected="$2" actual
  actual="$(cef_locale_catalog_for_locale "$locale")"
  [[ "$actual" == "$expected" ]] || {
    echo "FAIL: CEF maps $locale to $actual, expected $expected" >&2
    exit 1
  }
  grep -Fxq -- "$actual" <<<"$allowlist" || {
    echo "FAIL: CEF catalog $actual for $locale is not retained" >&2
    exit 1
  }
}

# Every app String-table language has a retained CEF catalog.
for pair in \
  'ar ar' 'bs en' 'da da' 'de de' 'en en' 'es es' 'fr fr' 'it it' \
  'ja ja' 'ko ko' 'nb nb' 'pl pl' 'pt-BR pt_BR' 'ru ru' 'th th' \
  'tr tr' 'km en' 'uk uk' 'vi vi' 'zh-Hans zh_CN' 'zh-Hant zh_TW'; do
  set -- $pair
  expect_catalog "$1" "$2"
done

# Regional macOS locales use CEF's regional catalogs rather than the base
# language catalog. These caught the es-MX and pt-PT regression.
for pair in \
  'es-ES es' 'es-MX es_419' 'es-AR es_419' 'pt-BR pt_BR' \
  'pt-PT pt_PT' 'pt-AO pt_BR' 'en-US en' 'en-GB en_GB' \
  'en-AU en_GB' 'en-CA en_GB' 'en-IN en_GB' 'zh-CN zh_CN' 'zh-TW zh_TW' 'zh-HK zh_TW' 'zh-SG zh_CN'; do
  set -- $pair
  expect_catalog "$1" "$2"
done

for required in en en_GB es es_419 pt_BR pt_PT zh_CN zh_TW; do
  grep -Fxq -- "$required" <<<"$allowlist" || {
    echo "FAIL: required regional catalog $required is absent" >&2
    exit 1
  }
done

echo "PASS: CEF locale fallback mappings retain every app and regional catalog"
