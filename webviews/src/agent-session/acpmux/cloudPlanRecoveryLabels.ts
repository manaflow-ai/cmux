// l10n-allow-file: Exact existing localized button titles from CmuxNextCloudUI/Resources/Cloud.xcstrings.
// The pane cannot import the native bundle and its 7 MB Localizable.xcstrings is kept separate.
// Keep these two titles in sync with cloud.atCap.upgrade / cloud.atCap.runHere.
export type CloudPlanRecoveryLabels = { upgrade: string; runHere: string };

const english: CloudPlanRecoveryLabels = { upgrade: "Upgrade", runHere: "Run on This Mac" };
const labels: Record<string, CloudPlanRecoveryLabels> = {
  ar: {
    upgrade: "ترقية",
    runHere: "تشغيل على جهاز Mac هذا",
  },
  bs: {
    upgrade: "Nadogradi",
    runHere: "Pokreni na ovom Macu",
  },
  da: {
    upgrade: "Opgrader",
    runHere: "Kør på denne Mac",
  },
  de: {
    upgrade: "Upgraden",
    runHere: "Auf diesem Mac ausführen",
  },
  en: {
    upgrade: "Upgrade",
    runHere: "Run on This Mac",
  },
  es: {
    upgrade: "Mejorar",
    runHere: "Ejecutar en este Mac",
  },
  fr: {
    upgrade: "Mettre à niveau",
    runHere: "Exécuter sur ce Mac",
  },
  it: {
    upgrade: "Esegui upgrade",
    runHere: "Esegui su questo Mac",
  },
  ja: {
    upgrade: "アップグレード",
    runHere: "この Mac で実行",
  },
  km: {
    upgrade: "ដំឡើងកម្រិត",
    runHere: "ដំណើរការលើ Mac នេះ",
  },
  ko: {
    upgrade: "업그레이드",
    runHere: "이 Mac에서 실행",
  },
  nb: {
    upgrade: "Oppgrader",
    runHere: "Kjør på denne Macen",
  },
  pl: {
    upgrade: "Ulepsz",
    runHere: "Uruchom na tym Macu",
  },
  "pt-BR": {
    upgrade: "Fazer upgrade",
    runHere: "Executar neste Mac",
  },
  ru: {
    upgrade: "Улучшить",
    runHere: "Запустить на этом Mac",
  },
  th: {
    upgrade: "อัปเกรด",
    runHere: "เรียกใช้บน Mac เครื่องนี้",
  },
  tr: {
    upgrade: "Yükselt",
    runHere: "Bu Mac'te Çalıştır",
  },
  uk: {
    upgrade: "Оновити тариф",
    runHere: "Запустити на цьому Mac",
  },
  vi: {
    upgrade: "Nâng cấp",
    runHere: "Chạy trên máy Mac này",
  },
  "zh-Hans": {
    upgrade: "升级",
    runHere: "在这台 Mac 上运行",
  },
  "zh-Hant": {
    upgrade: "升級",
    runHere: "在這台 Mac 上執行",
  },
};

export function cloudPlanRecoveryLabels(language: string): CloudPlanRecoveryLabels {
  return labels[language] ?? labels[language.split("-")[0] ?? ""] ?? english;
}
