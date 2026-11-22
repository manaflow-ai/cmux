#!/usr/bin/env bash
# Maps cmux locale identifiers to the .lproj catalog CEF loads on macOS.
# CEF uses regional fallbacks, so this includes the regional cases cmux can
# receive from macOS even when the app's String tables use a base language.

cef_locale_catalog_for_locale() {
  local locale="${1//-/_}"
  case "$locale" in
    en_GB|en_AU|en_CA|en_IE|en_IN|en_NZ|en_ZA) printf '%s\n' en_GB ;;
    en_*) printf '%s\n' en ;;
    en) printf '%s\n' en ;;
    es_ES) printf '%s\n' es ;;
    es_*) printf '%s\n' es_419 ;;
    es) printf '%s\n' es ;;
    pt_PT) printf '%s\n' pt_PT ;;
    pt_*) printf '%s\n' pt_BR ;;
    pt) printf '%s\n' pt_BR ;;
    zh_Hans|zh_CN|zh_SG) printf '%s\n' zh_CN ;;
    zh_Hant|zh_TW|zh_HK|zh_MO) printf '%s\n' zh_TW ;;
    ar*) printf '%s\n' ar ;;
    bs*) printf '%s\n' en ;;
    da*) printf '%s\n' da ;;
    de*) printf '%s\n' de ;;
    fr*) printf '%s\n' fr ;;
    it*) printf '%s\n' it ;;
    ja*) printf '%s\n' ja ;;
    km*) printf '%s\n' en ;;
    ko*) printf '%s\n' ko ;;
    nb*|no*|nn*) printf '%s\n' nb ;;
    iw*) printf '%s\n' he ;;
    tl*) printf '%s\n' fil ;;
    pl*) printf '%s\n' pl ;;
    ru*) printf '%s\n' ru ;;
    th*) printf '%s\n' th ;;
    tr*) printf '%s\n' tr ;;
    uk*) printf '%s\n' uk ;;
    vi*) printf '%s\n' vi ;;
    *) printf '%s\n' en ;;
  esac
}

# Every locale pak Chromium 157 builds for macOS (build/config/locales.gni
# platform_pak_locales: all_chrome_locales minus the extended and pseudo
# locales), as .lproj names. Upstream ships each in four grammatical genders
# (base, _MASCULINE, _FEMININE, _NEUTER): the 220 folders people count. cmux
# keeps only the base one. Keep in step with CHROMIUM_LOCALES in cmux-tui-core
# src/language_packs.rs (tests/test_cmux_next_cef_locale_allowlist.sh checks).
cef_chromium_locales() {
  printf '%s\n' \
    af am ar bg bn ca cs da de el en en_GB es es_419 et fa fi fil fr gu he hi \
    hr hu id it ja kn ko lt lv ml mr ms nb nl pl pt_BR pt_PT ro ru sk sl sr sv \
    sw ta te th tr uk ur vi zh_CN zh_TW
}

# Whether the pinned CEF loads locale paks from outside its framework
# (cef-manifest.json "locale_paks_outside_framework": true). Only then do the
# paks become first-use downloads: before it, a pak moved out of the framework
# is one Chromium cannot read, so the build keeps today's allowlist.
cef_locale_paks_outside_framework() {
  local manifest="$1"
  [[ -f "$manifest" ]] || return 1
  /usr/bin/python3 -I -c 'import json, sys; sys.exit(0 if json.load(open(sys.argv[1])).get("locale_paks_outside_framework") is True else 1)' "$manifest"
}

cef_locale_allowlist() {
  local locale
  # The 21 app String-table languages, plus regional macOS locales whose CEF
  # fallback catalog differs from the base language.
  for locale in \
    ar bs da de en es fr it ja ko nb pl pt-BR ru th tr km uk vi zh-Hans zh-Hant \
    es-ES es-MX pt-BR pt-PT pt-AO en-US en-GB en-AU en-CA en-IN zh-CN zh-TW zh-HK zh-SG; do
    cef_locale_catalog_for_locale "$locale"
  done | sort -u
}
