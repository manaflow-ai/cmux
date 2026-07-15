import { ImageResponse } from "next/og";
import { readFile } from "fs/promises";
import { join } from "path";
import { openGraphImageTagline } from "@/i18n/seo";

export const runtime = "nodejs";
export const size = { width: 1200, height: 630 };
export const contentType = "image/png";

const S = 2; // render at 2x for sharper images on social platforms
const NOTO_BASE =
  "https://raw.githubusercontent.com/notofonts/notofonts.github.io/main/fonts";
const NOTO_CJK_BASE =
  "https://raw.githubusercontent.com/notofonts/noto-cjk/main/Sans/OTF";
const localeFonts: Record<string, { name: string; url: string }> = {
  ja: {
    name: "Noto Sans CJK JP",
    url: `${NOTO_CJK_BASE}/Japanese/NotoSansCJKjp-Regular.otf`,
  },
  "zh-CN": {
    name: "Noto Sans CJK SC",
    url: `${NOTO_CJK_BASE}/SimplifiedChinese/NotoSansCJKsc-Regular.otf`,
  },
  "zh-TW": {
    name: "Noto Sans CJK TC",
    url: `${NOTO_CJK_BASE}/TraditionalChinese/NotoSansCJKtc-Regular.otf`,
  },
  ko: {
    name: "Noto Sans CJK KR",
    url: `${NOTO_CJK_BASE}/Korean/NotoSansCJKkr-Regular.otf`,
  },
  ar: {
    name: "Noto Naskh Arabic",
    url: `${NOTO_BASE}/NotoNaskhArabic/hinted/ttf/NotoNaskhArabic-Regular.ttf`,
  },
  th: {
    name: "Noto Sans Thai",
    url: `${NOTO_BASE}/NotoSansThai/hinted/ttf/NotoSansThai-Regular.ttf`,
  },
  km: {
    name: "Noto Sans Khmer",
    url: `${NOTO_BASE}/NotoSansKhmer/hinted/ttf/NotoSansKhmer-Regular.ttf`,
  },
  ru: {
    name: "Noto Sans",
    url: `${NOTO_BASE}/NotoSans/hinted/ttf/NotoSans-Regular.ttf`,
  },
  uk: {
    name: "Noto Sans",
    url: `${NOTO_BASE}/NotoSans/hinted/ttf/NotoSans-Regular.ttf`,
  },
};
const FONT_FETCH_TIMEOUT_MS = 1500;
const remoteFontData = new Map<string, ArrayBuffer>();

async function fetchRemoteFont(url: string) {
  const existing = remoteFontData.get(url);
  if (existing) {
    return existing;
  }

  try {
    const res = await fetch(url, {
      signal: AbortSignal.timeout(FONT_FETCH_TIMEOUT_MS),
    });
    if (!res.ok) {
      return null;
    }
    const data = await res.arrayBuffer();
    remoteFontData.set(url, data);
    return data;
  } catch {
    return null;
  }
}

export default async function Image({
  params,
}: {
  params: Promise<{ locale: string }>;
}) {
  const { locale } = await params;
  const tagline = openGraphImageTagline(locale);
  const localeFont = localeFonts[locale];
  const [logoData, screenshotData, geistRegular, geistSemiBold, localeFontData] =
    await Promise.all([
      readFile(join(process.cwd(), "public", "logo.png")),
      readFile(
        join(
          process.cwd(),
          "app",
          "[locale]",
          "(landing)",
          "assets",
          "og-screenshot.png",
        )
      ),
      fetchRemoteFont(
        "https://fonts.gstatic.com/s/geist/v4/gyBhhwUxId8gMGYQMKR3pzfaWI_RnOM4nQ.ttf"
      ),
      fetchRemoteFont(
        "https://fonts.gstatic.com/s/geist/v4/gyBhhwUxId8gMGYQMKR3pzfaWI_RQuQ4nQ.ttf"
      ),
      localeFont ? fetchRemoteFont(localeFont.url) : Promise.resolve(null),
    ]);

  const logoSrc = `data:image/png;base64,${logoData.toString("base64")}`;
  const screenshotSrc = `data:image/png;base64,${screenshotData.toString("base64")}`;
  const fonts = [];
  if (geistRegular) {
    fonts.push({
      name: "Geist",
      data: geistRegular,
      weight: 400 as const,
      style: "normal" as const,
    });
  }
  if (geistSemiBold) {
    fonts.push({
      name: "Geist",
      data: geistSemiBold,
      weight: 600 as const,
      style: "normal" as const,
    });
  }
  if (localeFont && localeFontData) {
    fonts.push({
      name: localeFont.name,
      data: localeFontData,
      weight: 400 as const,
      style: "normal" as const,
    });
  }
  const taglineFontFamily =
    localeFont && localeFontData ? `${localeFont.name}, Geist` : "Geist";
  const renderedTagline = localeFont && !localeFontData ? openGraphImageTagline("en") : tagline;
  const taglineDirection = locale === "ar" && localeFontData ? "rtl" : "ltr";

  return new ImageResponse(
    (
      <div
        style={{
          width: "100%",
          height: "100%",
          display: "flex",
          flexDirection: "column",
          backgroundColor: "#0a0a0a",
          fontFamily: "Geist",
          paddingBottom: 28 * S,
        }}
      >
        <div
          style={{
            display: "flex",
            flexDirection: "column",
            flex: 1,
          }}
        >
          {/* Screenshot */}
          <div
            style={{
              display: "flex",
              flex: 1,
              overflow: "hidden",
              position: "relative",
            }}
          >
            <img src={screenshotSrc} width={size.width * S} alt="" />
            <div
              style={{
                position: "absolute",
                bottom: 0,
                left: 0,
                right: 0,
                height: 320 * S,
                background:
                  "linear-gradient(to bottom, rgba(10,10,10,0), rgba(10,10,10,1))",
              }}
            />
          </div>

          {/* Branding bar */}
          <div
            style={{
              display: "flex",
              alignItems: "center",
              marginTop: -60 * S,
              paddingLeft: 25 * S,
            }}
          >
            <div
              style={{
                display: "flex",
                alignItems: "center",
                gap: 20 * S,
              }}
            >
              <img
                src={logoSrc}
                width={112 * S}
                height={112 * S}
                alt=""
                style={{ borderRadius: 20 * S }}
              />
              <div style={{ display: "flex", flexDirection: "column" }}>
                <div
                  style={{
                    fontSize: 48 * S,
                    fontWeight: 600,
                    color: "#ededed",
                    letterSpacing: "-0.02em",
                    lineHeight: 1,
                    marginTop: -8 * S,
                  }}
                >
                  cmux
                </div>
                <div
                  style={{
                    fontSize: 34 * S,
                    fontFamily: taglineFontFamily,
                    direction: taglineDirection,
                    fontWeight: 400,
                    color: "#cfcfcf",
                    marginTop: 5 * S,
                    lineHeight: 1,
                  }}
                >
                  {renderedTagline}
                </div>
              </div>
            </div>
          </div>
        </div>
      </div>
    ),
    {
      width: size.width * S,
      height: size.height * S,
      ...(fonts.length > 0 ? { fonts } : {}),
    }
  );
}
