import { ImageResponse } from "next/og";
import { readFile } from "fs/promises";
import { join } from "path";
import { openGraphImageTagline } from "@/i18n/seo";
import { routing, type Locale } from "@/i18n/routing";

const size = { width: 1200, height: 630 };

const S = 2; // render at 2x for sharper images on social platforms
const SCREENSHOT_INSET = 40;
const SCREENSHOT_RADIUS = 18;
const localeFonts: Partial<
  Record<Locale, { name: string; filename: string }>
> = {
  ja: {
    name: "Noto Sans CJK JP",
    filename: "noto-cjk-jp.otf",
  },
  "zh-CN": {
    name: "Noto Sans CJK SC",
    filename: "noto-cjk-sc.otf",
  },
  "zh-TW": {
    name: "Noto Sans CJK TC",
    filename: "noto-cjk-tc.otf",
  },
  ko: {
    name: "Noto Sans CJK KR",
    filename: "noto-cjk-kr.otf",
  },
  ar: {
    name: "Tajawal",
    filename: "tajawal.ttf",
  },
  th: {
    name: "Noto Sans Thai",
    filename: "noto-thai.ttf",
  },
  km: {
    name: "Noto Sans Khmer",
    filename: "noto-khmer.ttf",
  },
  ru: {
    name: "Noto Sans",
    filename: "noto-sans-cyrillic.ttf",
  },
  uk: {
    name: "Noto Sans",
    filename: "noto-sans-cyrillic.ttf",
  },
};

type OpenGraphImageRenderer = (locale: string) => Response | Promise<Response>;

export async function openGraphImageResponse(
  locale: string,
  render: OpenGraphImageRenderer = renderOpenGraphImage,
): Promise<Response> {
  if (!routing.locales.includes(locale as Locale)) {
    return new Response(null, { status: 404 });
  }

  return render(locale);
}

async function readBundledFont(filename: string): Promise<ArrayBuffer> {
  const data = await readFile(
    join(process.cwd(), "app", "lib", "open-graph-fonts", filename)
  );
  return data.buffer.slice(
    data.byteOffset,
    data.byteOffset + data.byteLength
  ) as ArrayBuffer;
}

async function renderOpenGraphImage(locale: string) {
  const tagline = openGraphImageTagline(locale);
  const localeFont = localeFonts[locale as Locale];
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
          "landing-image.png",
        )
      ),
      readBundledFont("geist-regular.ttf"),
      readBundledFont("geist-semibold.ttf"),
      localeFont
        ? readBundledFont(localeFont.filename)
        : Promise.resolve(null),
    ]);

  const logoSrc = `data:image/png;base64,${logoData.toString("base64")}`;
  const screenshotSrc = `data:image/png;base64,${screenshotData.toString("base64")}`;
  const fonts = [];
  fonts.push({
    name: "Geist",
    data: geistRegular,
    weight: 400 as const,
    style: "normal" as const,
  });
  fonts.push({
    name: "Geist",
    data: geistSemiBold,
    weight: 600 as const,
    style: "normal" as const,
  });
  if (localeFont && localeFontData) {
    fonts.push({
      name: localeFont.name,
      data: localeFontData,
      weight: 400 as const,
      style: "normal" as const,
    });
  }
  const taglineFontFamily = localeFont ? `${localeFont.name}, Geist` : "Geist";
  const taglineDirection = locale === "ar" ? "rtl" : "ltr";

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
              margin: `${SCREENSHOT_INSET * S}px ${SCREENSHOT_INSET * S}px 0`,
              borderRadius: SCREENSHOT_RADIUS * S,
            }}
          >
            <img
              src={screenshotSrc}
              width={(size.width - SCREENSHOT_INSET * 2) * S}
              alt=""
            />
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
                  {tagline}
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
