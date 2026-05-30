import { NextResponse } from "next/server";
import { recordSpanError, setSpanAttributes, withApiRouteSpan } from "../../../services/telemetry";

export const revalidate = 300; // ISR: regenerate every 5 minutes

export async function GET(request: Request) {
  return withApiRouteSpan(
    request,
    "/api/github-stars",
    { "cmux.subsystem": "website", "cmux.upstream.service": "github" },
    async (span) => {
      try {
        const res = await fetch(
          "https://api.github.com/repos/manaflow-ai/cmux",
          {
            headers: { Accept: "application/vnd.github.v3+json" },
            next: { revalidate: 300 },
          }
        );
        setSpanAttributes(span, { "cmux.upstream.status_code": res.status });

        if (!res.ok) {
          return NextResponse.json({ stars: null }, { status: 502 });
        }

        const data = await res.json();
        const stars: number = data.stargazers_count;
        setSpanAttributes(span, { "cmux.github.stars": stars });

        return NextResponse.json(
          { stars },
          {
            headers: {
              "Cache-Control": "public, s-maxage=300, stale-while-revalidate=600",
            },
          }
        );
      } catch (err) {
        recordSpanError(span, err);
        return NextResponse.json({ stars: null }, { status: 502 });
      }
    },
  );
}
