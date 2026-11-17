import { ImageResponse } from "next/og";
import { readFile } from "fs/promises";
import { join } from "path";
import { KIND_ROOT, type ListingKind, type ListingKey, parseListingSlug } from "@/app/extensions/_lib/refs";
import { readLimitedBody } from "@/app/extensions/_lib/limited-body";
import { type Listing, loadListing } from "@/app/extensions/_lib/registry";
import { listingSummary } from "@/app/extensions/_lib/seo";

/**
 * The per-listing social card, `/extensions/og.png?kind=extension|setup&page=/extensions/OWNER/REPO[/PATH]`
 * (seo.ts listingOpenGraphImage): icon, name, summary, publisher, stars and
 * installs, and the first screenshot when the listing has one. Text uses
 * next/og's bundled Geist (full Latin set); remote media loads with a timeout
 * and is skipped when it fails.
 */

const WIDTH = 1200;
const HEIGHT = 630;
const MEDIA_TIMEOUT_MS = 4_000;
const MAX_MEDIA_BYTES = 4 * 1024 * 1024;
const IMAGE_TYPES = new Set(["image/png", "image/jpeg", "image/gif", "image/svg+xml"]);
const SUCCESS_CACHE = "public, max-age=3600, s-maxage=86400, stale-while-revalidate=604800";
const MISS_CACHE = "public, max-age=60";

function notFound(): Response {
  return new Response("Not found", { status: 404, headers: { "Cache-Control": MISS_CACHE } });
}

/** The listing a card is for, from `kind` and `page`, or null when they do not name one. */
function cardTarget(params: URLSearchParams): { kind: ListingKind; key: ListingKey } | null {
  const page = params.get("page") ?? "";
  const kind = (Object.keys(KIND_ROOT) as ListingKind[]).find((candidate) => page.startsWith(`${KIND_ROOT[candidate]}/`));
  if (!kind) return null;
  const requested = params.get("kind");
  if (requested && requested !== kind) return null;
  const segments = page.slice(KIND_ROOT[kind].length + 1).split("/");
  const route = parseListingSlug(segments);
  if (!route || route.page !== "listing") return null;
  return { kind, key: { host: route.host, owner: route.owner, repo: route.repo, path: route.path } };
}

/** A remote image as a data URL, or null when it is slow, large, or not an image satori can draw. */
async function fetchImage(url: string | undefined): Promise<string | null> {
  if (!url) return null;
  try {
    const response = await fetch(url, { signal: AbortSignal.timeout(MEDIA_TIMEOUT_MS), redirect: "error" });
    const type = (response.headers.get("content-type") ?? "").split(";")[0]!.trim().toLowerCase();
    if (!response.ok || !IMAGE_TYPES.has(type)) {
      await response.body?.cancel().catch(() => undefined);
      return null;
    }
    // Refused before buffering: a declared or streamed size over the limit stops the read.
    const body = await readLimitedBody(response, MAX_MEDIA_BYTES);
    if (!body || body.byteLength === 0) return null;
    return `data:${type};base64,${Buffer.from(body).toString("base64")}`;
  } catch {
    return null;
  }
}

async function logoDataUrl(): Promise<string> {
  const data = await readFile(join(process.cwd(), "public", "logo.png"));
  return `data:image/png;base64,${data.toString("base64")}`;
}

function compact(value: number): string {
  return new Intl.NumberFormat("en-US", { notation: "compact", maximumFractionDigits: 1 }).format(value);
}

function truncate(value: string, max: number): string {
  return value.length <= max ? value : `${value.slice(0, max - 1).trimEnd()}…`;
}

function StarIcon() {
  return (
    <svg width="26" height="26" viewBox="0 0 24 24">
      <path d="M12 2.5l2.9 6.1 6.6.8-4.9 4.6 1.3 6.6L12 17.3l-5.9 3.3 1.3-6.6-4.9-4.6 6.6-.8z" fill="#facc15" />
    </svg>
  );
}

function DownloadIcon() {
  return (
    <svg width="26" height="26" viewBox="0 0 24 24" fill="none" stroke="#a3a3a3" strokeWidth="2.2" strokeLinecap="round" strokeLinejoin="round">
      <path d="M12 3v12M7 10l5 5 5-5M4 20h16" />
    </svg>
  );
}

function Stats({ listing }: { listing: Listing }) {
  const items = [];
  if (listing.stars !== undefined) {
    items.push(
      <div key="stars" style={{ display: "flex", alignItems: "center", gap: 10 }}>
        <StarIcon />
        {`${compact(listing.stars)} stars`}
      </div>,
    );
  }
  if (listing.installs !== undefined) {
    items.push(
      <div key="installs" style={{ display: "flex", alignItems: "center", gap: 10 }}>
        <DownloadIcon />
        {`${compact(listing.installs)} installs`}
      </div>,
    );
  }
  if (items.length === 0) return null;
  return <div style={{ display: "flex", gap: 36, fontSize: 26, color: "#d4d4d4", marginTop: 28 }}>{items}</div>;
}

function Details({ listing, icon, wide }: { listing: Listing; icon: string; wide: boolean }) {
  const nameSize = listing.name.length > 22 ? 52 : 68;
  return (
    <div style={{ display: "flex", flexDirection: "column", width: wide ? 1072 : 560 }}>
      <img src={icon} width={112} height={112} alt="" style={{ borderRadius: 26, marginBottom: 36 }} />
      <div style={{ display: "flex", fontSize: nameSize, color: "#fafafa", letterSpacing: "-0.03em", lineHeight: 1.05 }}>
        {truncate(listing.name, 48)}
      </div>
      <div style={{ display: "flex", fontSize: 30, color: "#a3a3a3", lineHeight: 1.35, marginTop: 18 }}>
        {truncate(listingSummary(listing), wide ? 150 : 110)}
      </div>
      <div style={{ display: "flex", fontSize: 26, color: "#737373", marginTop: 22 }}>
        {`by ${truncate(listing.publisher ?? listing.owner, 60)}`}
      </div>
      <Stats listing={listing} />
    </div>
  );
}

function Screenshot({ src }: { src: string }) {
  return (
    <div
      style={{
        display: "flex",
        width: 488,
        height: 380,
        borderRadius: 18,
        overflow: "hidden",
        border: "1px solid #262626",
        backgroundColor: "#171717",
      }}
    >
      <img src={src} width={488} height={380} alt="" style={{ objectFit: "cover", objectPosition: "top left" }} />
    </div>
  );
}

function Footer({ logo, kind }: { logo: string; kind: ListingKind }) {
  return (
    <div style={{ display: "flex", alignItems: "center", gap: 14, fontSize: 26, color: "#a3a3a3" }}>
      <img src={logo} width={40} height={40} alt="" style={{ borderRadius: 9 }} />
      {`cmux.com${KIND_ROOT[kind]}`}
    </div>
  );
}

async function renderCard(listing: Listing, kind: ListingKind): Promise<ImageResponse> {
  const [logo, icon, screenshot] = await Promise.all([
    logoDataUrl(),
    fetchImage(listing.iconUrl),
    fetchImage(listing.screenshots[0]),
  ]);
  return new ImageResponse(
    (
      <div
        style={{
          width: "100%",
          height: "100%",
          display: "flex",
          flexDirection: "column",
          justifyContent: "space-between",
          padding: "64px 64px 48px",
          backgroundColor: "#0a0a0a",
          backgroundImage: "radial-gradient(circle at 0% 0%, rgba(45,140,255,0.16), rgba(10,10,10,0) 55%)",
          fontFamily: "Geist",
        }}
      >
        <div style={{ display: "flex", justifyContent: "space-between", alignItems: "flex-start" }}>
          <Details listing={listing} icon={icon ?? logo} wide={!screenshot} />
          {screenshot ? <Screenshot src={screenshot} /> : null}
        </div>
        <Footer logo={logo} kind={kind} />
      </div>
    ),
    { width: WIDTH, height: HEIGHT, headers: { "Cache-Control": SUCCESS_CACHE } },
  );
}

export async function GET(request: Request): Promise<Response> {
  const target = cardTarget(new URL(request.url).searchParams);
  if (!target) return notFound();
  const listing = await loadListing(target.kind, target.key);
  if (!listing) return notFound();
  return renderCard(listing, target.kind);
}
