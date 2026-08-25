import { readFile } from "node:fs/promises";
import { join } from "node:path";
import { ImageResponse } from "next/og";

const size = { width: 1200, height: 630 };
const renderScale = 2;

/**
 * Renders a platform-neutral social card for the Windows and Linux browser
 * pages. The regular card includes a screenshot and Mac-specific copy.
 */
export async function browserOpenGraphImageResponse(): Promise<Response> {
  const logoData = await readFile(join(process.cwd(), "public", "logo.png"));
  const logoSrc = `data:image/png;base64,${logoData.toString("base64")}`;
  const scale = renderScale;

  return new ImageResponse(
    <div
      style={{
        width: "100%",
        height: "100%",
        display: "flex",
        alignItems: "center",
        justifyContent: "space-between",
        overflow: "hidden",
        position: "relative",
        padding: `${84 * scale}px ${88 * scale}px`,
        background:
          "radial-gradient(circle at 85% 20%, #252a3a 0%, #11131a 38%, #08090c 75%)",
        color: "#f5f5f5",
        fontFamily: "sans-serif",
      }}
    >
      <div
        style={{
          position: "absolute",
          inset: 0,
          display: "flex",
          opacity: 0.16,
          backgroundImage:
            "linear-gradient(#79809a 1px, transparent 1px), linear-gradient(90deg, #79809a 1px, transparent 1px)",
          backgroundSize: `${48 * scale}px ${48 * scale}px`,
        }}
      />

      <div
        style={{
          display: "flex",
          alignItems: "center",
          gap: 28 * scale,
        }}
      >
        {/* ImageResponse needs a data-URL image rather than next/image. */}
        {/* eslint-disable-next-line @next/next/no-img-element */}
        <img
          src={logoSrc}
          width={128 * scale}
          height={128 * scale}
          alt=""
          style={{
            borderRadius: 28 * scale,
            boxShadow: `0 ${18 * scale}px ${50 * scale}px rgba(0,0,0,0.45)`,
          }}
        />
        <div
          style={{
            display: "flex",
            fontSize: 76 * scale,
            fontWeight: 700,
            letterSpacing: "-0.045em",
          }}
        >
          cmux
        </div>
      </div>

      <div
        style={{
          width: 550 * scale,
          height: 390 * scale,
          display: "flex",
          flexDirection: "column",
          overflow: "hidden",
          border: `${1 * scale}px solid rgba(255,255,255,0.18)`,
          borderRadius: 22 * scale,
          backgroundColor: "rgba(18,20,27,0.96)",
          boxShadow: `0 ${30 * scale}px ${80 * scale}px rgba(0,0,0,0.45)`,
        }}
      >
        <div
          style={{
            height: 62 * scale,
            display: "flex",
            alignItems: "center",
            gap: 10 * scale,
            padding: `0 ${20 * scale}px`,
            borderBottom: `${1 * scale}px solid rgba(255,255,255,0.1)`,
          }}
        >
          <div
            style={{
              width: 86 * scale,
              height: 26 * scale,
              display: "flex",
              borderRadius: 7 * scale,
              backgroundColor: "rgba(255,255,255,0.16)",
            }}
          />
          <div
            style={{
              width: 64 * scale,
              height: 26 * scale,
              display: "flex",
              borderRadius: 7 * scale,
              backgroundColor: "rgba(255,255,255,0.08)",
            }}
          />
          <div
            style={{
              height: 28 * scale,
              flex: 1,
              display: "flex",
              marginLeft: 10 * scale,
              borderRadius: 8 * scale,
              backgroundColor: "rgba(255,255,255,0.08)",
            }}
          />
        </div>

        <div
          style={{
            flex: 1,
            display: "flex",
            gap: 14 * scale,
            padding: 18 * scale,
          }}
        >
          <div
            style={{
              width: 122 * scale,
              display: "flex",
              flexDirection: "column",
              gap: 12 * scale,
            }}
          >
            {[0.75, 1, 0.86, 0.68].map((width, index) => (
              <div
                key={index}
                style={{
                  width: `${width * 100}%`,
                  height: 18 * scale,
                  display: "flex",
                  borderRadius: 5 * scale,
                  backgroundColor:
                    index === 1
                      ? "rgba(117,134,255,0.65)"
                      : "rgba(255,255,255,0.1)",
                }}
              />
            ))}
          </div>

          <div
            style={{
              flex: 1,
              display: "flex",
              flexDirection: "column",
              gap: 14 * scale,
            }}
          >
            <div
              style={{
                height: 126 * scale,
                display: "flex",
                alignItems: "center",
                justifyContent: "center",
                borderRadius: 13 * scale,
                background:
                  "linear-gradient(135deg, rgba(117,134,255,0.28), rgba(84,213,171,0.13))",
              }}
            >
              <div
                style={{
                  width: 136 * scale,
                  height: 22 * scale,
                  display: "flex",
                  borderRadius: 7 * scale,
                  backgroundColor: "rgba(255,255,255,0.68)",
                }}
              />
            </div>
            <div
              style={{
                flex: 1,
                display: "flex",
                gap: 14 * scale,
              }}
            >
              <div
                style={{
                  flex: 1,
                  display: "flex",
                  borderRadius: 13 * scale,
                  backgroundColor: "rgba(255,255,255,0.07)",
                }}
              />
              <div
                style={{
                  flex: 1,
                  display: "flex",
                  borderRadius: 13 * scale,
                  backgroundColor: "rgba(255,255,255,0.07)",
                }}
              />
            </div>
          </div>
        </div>
      </div>
    </div>,
    {
      width: size.width * scale,
      height: size.height * scale,
      headers: {
        "Cache-Control": "public, max-age=0, s-maxage=31536000, immutable",
      },
    },
  );
}
