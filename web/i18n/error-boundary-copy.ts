import { locales, routing, type Locale } from "./routing";

export type ErrorBoundaryCopy = {
  /** Heading for a route whose content failed to render. */
  title: string;
  /** Explains that only this part failed. */
  body: string;
  /** One-line notice for a small widget that failed in place. */
  section: string;
  retry: string;
  home: string;
};

/**
 * Error boundaries render when the rest of the tree may be gone, including
 * the next-intl provider (`global-error` replaces the root layout, `/handler`
 * has no provider). This table is therefore read directly, never through a
 * provider that could itself be the thing that failed.
 */
export const errorBoundaryCopy: Record<Locale, ErrorBoundaryCopy> = {
  en: {
    title: "Something went wrong",
    body: "This part of the page could not load. The rest of cmux.com still works.",
    section: "This section could not load.",
    retry: "Try again",
    home: "Go to homepage",
  },
  ja: {
    title: "問題が発生しました",
    body: "ページのこの部分を読み込めませんでした。cmux.com の他の部分は引き続き利用できます。",
    section: "このセクションを読み込めませんでした。",
    retry: "再試行",
    home: "ホームへ移動",
  },
  "zh-CN": {
    title: "出了点问题",
    body: "页面的这一部分无法加载。cmux.com 的其他部分仍可正常使用。",
    section: "此部分无法加载。",
    retry: "重试",
    home: "前往首页",
  },
  "zh-TW": {
    title: "發生問題",
    body: "頁面的這個部分無法載入。cmux.com 的其他部分仍可正常使用。",
    section: "此區塊無法載入。",
    retry: "重試",
    home: "前往首頁",
  },
  ko: {
    title: "문제가 발생했습니다",
    body: "페이지의 이 부분을 불러올 수 없습니다. cmux.com의 나머지 부분은 계속 사용할 수 있습니다.",
    section: "이 섹션을 불러올 수 없습니다.",
    retry: "다시 시도",
    home: "홈으로 이동",
  },
  de: {
    title: "Etwas ist schiefgelaufen",
    body: "Dieser Teil der Seite konnte nicht geladen werden. Der Rest von cmux.com funktioniert weiterhin.",
    section: "Dieser Bereich konnte nicht geladen werden.",
    retry: "Erneut versuchen",
    home: "Zur Startseite",
  },
  es: {
    title: "Algo salió mal",
    body: "Esta parte de la página no se pudo cargar. El resto de cmux.com sigue funcionando.",
    section: "Esta sección no se pudo cargar.",
    retry: "Reintentar",
    home: "Ir a la página de inicio",
  },
  fr: {
    title: "Une erreur s'est produite",
    body: "Cette partie de la page n'a pas pu se charger. Le reste de cmux.com fonctionne toujours.",
    section: "Cette section n'a pas pu se charger.",
    retry: "Réessayer",
    home: "Aller à l'accueil",
  },
  it: {
    title: "Qualcosa è andato storto",
    body: "Questa parte della pagina non è stata caricata. Il resto di cmux.com funziona ancora.",
    section: "Questa sezione non è stata caricata.",
    retry: "Riprova",
    home: "Vai alla home page",
  },
  da: {
    title: "Noget gik galt",
    body: "Denne del af siden kunne ikke indlæses. Resten af cmux.com virker stadig.",
    section: "Denne sektion kunne ikke indlæses.",
    retry: "Prøv igen",
    home: "Gå til forsiden",
  },
  pl: {
    title: "Coś poszło nie tak",
    body: "Nie udało się załadować tej części strony. Reszta cmux.com nadal działa.",
    section: "Nie udało się załadować tej sekcji.",
    retry: "Spróbuj ponownie",
    home: "Przejdź do strony głównej",
  },
  ru: {
    title: "Что-то пошло не так",
    body: "Не удалось загрузить эту часть страницы. Остальная часть cmux.com по-прежнему работает.",
    section: "Не удалось загрузить этот раздел.",
    retry: "Повторить",
    home: "На главную",
  },
  bs: {
    title: "Nešto nije u redu",
    body: "Ovaj dio stranice nije se mogao učitati. Ostatak cmux.com i dalje radi.",
    section: "Ovaj odjeljak se nije mogao učitati.",
    retry: "Pokušaj ponovo",
    home: "Idi na početnu stranicu",
  },
  ar: {
    title: "حدث خطأ ما",
    body: "تعذّر تحميل هذا الجزء من الصفحة. بقية cmux.com لا تزال تعمل.",
    section: "تعذّر تحميل هذا القسم.",
    retry: "إعادة المحاولة",
    home: "الانتقال إلى الصفحة الرئيسية",
  },
  no: {
    title: "Noe gikk galt",
    body: "Denne delen av siden kunne ikke lastes inn. Resten av cmux.com fungerer fortsatt.",
    section: "Denne delen kunne ikke lastes inn.",
    retry: "Prøv igjen",
    home: "Gå til forsiden",
  },
  "pt-BR": {
    title: "Algo deu errado",
    body: "Esta parte da página não pôde ser carregada. O restante do cmux.com continua funcionando.",
    section: "Esta seção não pôde ser carregada.",
    retry: "Tentar novamente",
    home: "Ir para a página inicial",
  },
  th: {
    title: "เกิดข้อผิดพลาด",
    body: "ไม่สามารถโหลดส่วนนี้ของหน้าได้ ส่วนอื่นของ cmux.com ยังใช้งานได้ตามปกติ",
    section: "ไม่สามารถโหลดส่วนนี้ได้",
    retry: "ลองอีกครั้ง",
    home: "ไปที่หน้าแรก",
  },
  tr: {
    title: "Bir sorun oluştu",
    body: "Sayfanın bu bölümü yüklenemedi. cmux.com'un geri kalanı çalışmaya devam ediyor.",
    section: "Bu bölüm yüklenemedi.",
    retry: "Tekrar dene",
    home: "Ana sayfaya git",
  },
  km: {
    title: "មានបញ្ហាកើតឡើង",
    body: "មិនអាចផ្ទុកផ្នែកនេះនៃទំព័របានទេ។ ផ្នែកផ្សេងទៀតនៃ cmux.com នៅតែដំណើរការ។",
    section: "មិនអាចផ្ទុកផ្នែកនេះបានទេ។",
    retry: "ព្យាយាមម្តងទៀត",
    home: "ទៅទំព័រដើម",
  },
  uk: {
    title: "Щось пішло не так",
    body: "Не вдалося завантажити цю частину сторінки. Решта cmux.com і далі працює.",
    section: "Не вдалося завантажити цей розділ.",
    retry: "Спробувати ще раз",
    home: "На головну",
  },
};

function matchLocale(candidate: string | null | undefined): Locale | null {
  if (!candidate) return null;
  if ((locales as readonly string[]).includes(candidate)) return candidate as Locale;
  const lower = candidate.toLowerCase();
  const exact = locales.find((locale) => locale.toLowerCase() === lower);
  if (exact) return exact;
  const language = lower.split("-")[0];
  if (language === "nb" || language === "nn") return "no";
  if (language === "pt") return "pt-BR";
  if (language === "zh") return lower.includes("tw") || lower.includes("hant") ? "zh-TW" : "zh-CN";
  return locales.find((locale) => locale.toLowerCase() === language) ?? null;
}

/** Picks the first candidate that names a supported locale. */
export function resolveErrorBoundaryLocale(
  ...candidates: Array<string | null | undefined>
): Locale {
  for (const candidate of candidates) {
    const locale = matchLocale(candidate);
    if (locale) return locale;
  }
  return routing.defaultLocale;
}
