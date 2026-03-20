import { ImageResponse } from "next/og";
import { readFile } from "fs/promises";
import { join } from "path";

export const runtime = "nodejs";
export const size = { width: 1200, height: 630 };
export const contentType = "image/png";
export const alt = "cmux — The terminal built for multitasking";

export default async function Image() {
  const [logoData, screenshotData, geistRegular, geistSemiBold] =
    await Promise.all([
      readFile(join(process.cwd(), "public", "logo.png")),
      readFile(
        join(process.cwd(), "app", "[locale]", "assets", "landing-image.png")
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
          backgroundColor: "#0a0a0a",
          fontFamily: "Geist",
        }}
      >
        {/* Left: text content */}
        <div
          style={{
            display: "flex",
            flexDirection: "column",
            justifyContent: "center",
            padding: "60px 48px",
            width: "460px",
            flexShrink: 0,
          }}
        >
          <img
            src={logoSrc}
            width={56}
            height={56}
            style={{ borderRadius: 14 }}
          />
          <div
            style={{
              fontSize: 42,
              fontWeight: 600,
              color: "#ededed",
              marginTop: 20,
              letterSpacing: "-0.02em",
            }}
          >
            cmux
          </div>
          <div
            style={{
              fontSize: 20,
              fontWeight: 400,
              color: "#a3a3a3",
              marginTop: 8,
              lineHeight: 1.4,
            }}
          >
            The terminal built for multitasking
          </div>
          <div
            style={{
              fontSize: 14,
              fontWeight: 400,
              color: "#525252",
              marginTop: 20,
              lineHeight: 1.5,
            }}
          >
            cmux.com
          </div>
        </div>

        {/* Right: app screenshot */}
        <div
          style={{
            display: "flex",
            alignItems: "center",
            justifyContent: "center",
            flex: 1,
            padding: "32px 32px 32px 0",
          }}
        >
          <img
            src={screenshotSrc}
            style={{
              borderRadius: 12,
              objectFit: "cover",
              width: "100%",
              height: "100%",
            }}
          />
        </div>
      </div>
    ),
    {
      ...size,
      fonts: [
        { name: "Geist", data: geistRegular, weight: 400, style: "normal" },
        { name: "Geist", data: geistSemiBold, weight: 600, style: "normal" },
      ],
    }
  );
}
