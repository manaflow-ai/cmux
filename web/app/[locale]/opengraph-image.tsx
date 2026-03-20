import { ImageResponse } from "next/og";
import { readFile } from "fs/promises";
import { join } from "path";

export const runtime = "nodejs";
export const size = { width: 1200, height: 630 };
export const contentType = "image/png";
export const alt = "cmux — The terminal built for multitasking";

export default async function Image() {
  const logoData = await readFile(join(process.cwd(), "public", "logo.png"));
  const logoSrc = `data:image/png;base64,${logoData.toString("base64")}`;

  return new ImageResponse(
    (
      <div
        style={{
          width: "100%",
          height: "100%",
          display: "flex",
          flexDirection: "column",
          alignItems: "center",
          justifyContent: "center",
          backgroundColor: "#0a0a0a",
        }}
      >
        {/* Top accent line */}
        <div
          style={{
            position: "absolute",
            top: 0,
            left: 0,
            right: 0,
            height: 4,
            background: "linear-gradient(90deg, #22d3ee, #3b82f6, #8b5cf6)",
          }}
        />

        {/* Logo */}
        <img
          src={logoSrc}
          width={88}
          height={88}
          style={{ borderRadius: 20 }}
        />

        {/* Title */}
        <div
          style={{
            fontSize: 56,
            fontWeight: 700,
            color: "#ededed",
            marginTop: 24,
            letterSpacing: "-0.02em",
          }}
        >
          cmux
        </div>

        {/* Tagline */}
        <div
          style={{
            fontSize: 28,
            color: "#a3a3a3",
            marginTop: 8,
          }}
        >
          The terminal built for multitasking
        </div>

        {/* Description */}
        <div
          style={{
            fontSize: 18,
            color: "#636363",
            marginTop: 28,
            textAlign: "center",
            maxWidth: 700,
            lineHeight: 1.5,
          }}
        >
          Native macOS terminal for AI coding agents. Works with Claude Code,
          Codex, OpenCode, Gemini CLI, Kiro, Aider, and more.
        </div>

        {/* URL */}
        <div
          style={{
            position: "absolute",
            bottom: 36,
            fontSize: 16,
            color: "#525252",
          }}
        >
          cmux.com
        </div>
      </div>
    ),
    { ...size }
  );
}
