import { ImageResponse } from "next/og";

export const alt = "cmux — The terminal built for multitasking";
export const size = { width: 1200, height: 630 };
export const contentType = "image/png";

export default async function Image() {
  return new ImageResponse(
    (
      <div
        style={{
          height: "100%",
          width: "100%",
          display: "flex",
          flexDirection: "column",
          justifyContent: "center",
          backgroundColor: "#0a0a0a",
          backgroundImage:
            "radial-gradient(ellipse 80% 50% at 50% 0%, #1a1a3e 0%, transparent 60%)",
          padding: "60px 80px",
        }}
      >
        {/* Prompt chevron + name */}
        <div style={{ display: "flex", alignItems: "baseline" }}>
          <div
            style={{
              fontSize: 96,
              fontWeight: 700,
              color: "#22d3ee",
            }}
          >
            {">"}
          </div>
          <div
            style={{
              fontSize: 96,
              fontWeight: 700,
              color: "#ededed",
              marginLeft: 20,
              letterSpacing: "-0.03em",
            }}
          >
            cmux
          </div>
        </div>

        {/* Gradient accent line */}
        <div
          style={{
            width: 120,
            height: 3,
            backgroundImage: "linear-gradient(90deg, #22d3ee, #3b82f6)",
            marginTop: 24,
            marginBottom: 24,
            borderRadius: 2,
          }}
        />

        {/* Tagline */}
        <div
          style={{
            fontSize: 32,
            color: "#a3a3a3",
            lineHeight: 1.4,
          }}
        >
          The terminal built for multitasking
        </div>

        {/* URL */}
        <div
          style={{
            position: "absolute",
            bottom: 48,
            right: 80,
            fontSize: 22,
            color: "#404040",
            letterSpacing: "0.05em",
          }}
        >
          cmux.dev
        </div>
      </div>
    ),
    { ...size },
  );
}
