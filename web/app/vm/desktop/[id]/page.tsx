import { desktopIframeUrl } from "../../../../services/vms/desktopWrapper";

// The cmux-owned face of a machine's screen. The pane's address bar shows
// this URL (`cmux_token` on our origin); the gateway's own token parameter
// exists only inside the iframe src. When the token lapses, the overlay says
// so and points at the fix instead of leaving a silent white canvas.
export default async function VmDesktopPage({
  params,
  searchParams,
}: {
  params: Promise<{ id: string }>;
  searchParams: Promise<Record<string, string | string[] | undefined>>;
}) {
  const { id } = await params;
  const query = await searchParams;
  const token = typeof query.cmux_token === "string" ? query.cmux_token : "";
  const host = typeof query.host === "string" ? query.host : "";
  const expiresAtMs = typeof query.exp === "string" ? Number.parseInt(query.exp, 10) : NaN;
  const frameSrc = desktopIframeUrl({ host, token, params: query });
  const machine = decodeURIComponent(id);

  const shell: React.CSSProperties = {
    margin: 0,
    height: "100vh",
    background: "#101418",
    color: "#dbe5ea",
    fontFamily: "-apple-system, 'Segoe UI', sans-serif",
    display: "flex",
    alignItems: "center",
    justifyContent: "center",
    textAlign: "center",
  };

  if (!frameSrc) {
    return (
      <main style={shell}>
        <div style={{ maxWidth: 440, padding: 24 }}>
          <h1 style={{ fontSize: 18, margin: "0 0 8px" }}>This desktop link isn&apos;t valid</h1>
          <p style={{ margin: 0, color: "#8fa2ac", fontSize: 14, lineHeight: 1.5 }}>
            The link is missing its session or points somewhere cmux won&apos;t frame.
            Reopen the desktop from cmux: right-click <code>{machine}</code> in the
            Machines panel and choose Open Desktop.
          </p>
        </div>
      </main>
    );
  }

  const expired = Number.isFinite(expiresAtMs) && Date.now() > expiresAtMs;
  if (expired) {
    return (
      <main style={shell}>
        <div style={{ maxWidth: 440, padding: 24 }}>
          <h1 style={{ fontSize: 18, margin: "0 0 8px" }}>This desktop session expired</h1>
          <p style={{ margin: 0, color: "#8fa2ac", fontSize: 14, lineHeight: 1.5 }}>
            <code>{machine}</code> and everything on it are fine — only this link&apos;s
            session ended. Reopen the desktop from cmux (right-click the machine →
            Open Desktop) to get a fresh one.
          </p>
        </div>
      </main>
    );
  }

  return (
    <main style={{ margin: 0, height: "100vh", background: "#101418" }}>
      <title>{`${machine} — desktop`}</title>
      <iframe
        src={frameSrc}
        title={`${machine} desktop`}
        allow="clipboard-read; clipboard-write; fullscreen"
        style={{ border: 0, width: "100%", height: "100%", display: "block" }}
      />
      {Number.isFinite(expiresAtMs) ? (
        <script
          // Long-lived panes outlive the token: when the deadline passes,
          // reload so the server renders the honest expiry screen above.
          dangerouslySetInnerHTML={{
            __html: `setTimeout(function(){location.reload()}, Math.min(${expiresAtMs} - Date.now() + 2000, 2147483647));`,
          }}
        />
      ) : null}
    </main>
  );
}
