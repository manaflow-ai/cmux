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
