import { ImageResponse } from "next/og";
import { readFile } from "fs/promises";
import { join } from "path";

export const runtime = "nodejs";
export const size = { width: 1200, height: 630 };
export const contentType = "image/png";
export const alt = "cmux — The terminal built for multitasking";

const S = 2; // render at 2x for sharper images on social platforms

export default async function Image() {
  const [logoData, screenshotData, geistRegular, geistSemiBold] =
    await Promise.all([
      readFile(join(process.cwd(), "public", "logo.png")),
      readFile(
        join(process.cwd(), "app", "[locale]", "assets", "og-screenshot.png")
      ),
      fetch(
        "https://fonts.gstatic.com/s/geist/v4/gyBhhwUxId8gMGYQMKR3pzfaWI_RnOM4nQ.ttf"
      ).then((res) => res.arrayBuffer()),
      fetch(
        "https://fonts.gstatic.com/s/geist/v4/gyBhhwUxId8gMGYQMKR3pzfaWI_RQuQ4nQ.ttf"
      ).then((res) => res.arrayBuffer()),
    ]);

  const logoSrc = `data:image/png;base64,${logoData.toString("base64")}`;
  const screenshotSrc = `data:image/png;base64,${screenshotData.toString("base64")}`;

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
            <img src={screenshotSrc} width={size.width * S} />
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
                    fontWeight: 400,
                    color: "#cfcfcf",
                    marginTop: 5 * S,
                    lineHeight: 1,
                  }}
                >
                  The terminal built for multitasking
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
      fonts: [
        { name: "Geist", data: geistRegular, weight: 400, style: "normal" },
        { name: "Geist", data: geistSemiBold, weight: 600, style: "normal" },
      ],
    }
  );
}
