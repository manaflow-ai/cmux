import { NextResponse } from "next/server";

export const revalidate = 300; // ISR: regenerate every 5 minutes

export async function GET() {
  try {
    const res = await fetch(
      "https://api.github.com/repos/manaflow-ai/cmux",
      {
        headers: { Accept: "application/vnd.github.v3+json" },
        next: { revalidate: 300 },
      }
    );

    if (!res.ok) {
      return NextResponse.json({ stars: null }, { status: 502 });
    }

    const data = await res.json();
    const stars: number = data.stargazers_count;

    return NextResponse.json(
      { stars },
      {
        headers: {
          "Cache-Control": "public, s-maxage=300, stale-while-revalidate=600",
        },
      }
    );
  } catch {
    return NextResponse.json({ stars: null }, { status: 502 });
  }
}
