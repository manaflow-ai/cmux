import { badgeSvg, parseBadgeSize, parseBadgeTheme } from "@/app/lib/extensions/badge";

/**
 * The "Get it on cmux" README badge. `?size=small|large` (default 122x44,
 * small 100x36, large 166x60) and `?theme=light`; unknown values fall back.
 */
export function GET(request: Request): Response {
  const params = new URL(request.url).searchParams;
  const svg = badgeSvg({ size: parseBadgeSize(params.get("size")), theme: parseBadgeTheme(params.get("theme")) });
  return new Response(svg, {
    headers: {
      "content-type": "image/svg+xml; charset=utf-8",
      "cache-control": "public, max-age=86400, s-maxage=31536000, stale-while-revalidate=604800",
      "x-content-type-options": "nosniff",
    },
  });
}
