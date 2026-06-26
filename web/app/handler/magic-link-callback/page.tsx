import { Suspense } from "react";
import { StackHandler } from "@stackframe/stack";
import { headers } from "next/headers";
import { notFound, redirect } from "next/navigation";
import { NextRequest } from "next/server";
import { stackServerApp } from "../../lib/stack";
import { isMobileNativeReturnTo } from "../after-sign-in/native-return";
import { mobileMagicLinkCallbackModel } from "../mobile-magic-link-callback/handler";

export const dynamic = "force-dynamic";

type SearchParams = Record<string, string | string[] | undefined>;

function firstParam(params: SearchParams, key: string): string | undefined {
  const value = params[key];
  return Array.isArray(value) ? value[0] : value;
}

async function mobileRequest(params: SearchParams): Promise<NextRequest> {
  const h = await headers();
  const requestHeaders = new Headers();
  h.forEach((value, key) => requestHeaders.set(key, value));
  const host = h.get("x-forwarded-host") ?? h.get("host") ?? "cmux.com";
  const proto = h.get("x-forwarded-proto") ?? (host.startsWith("localhost") ? "http" : "https");
  const url = new URL("/handler/magic-link-callback", `${proto}://${host}`);
  for (const [key, value] of Object.entries(params)) {
    if (Array.isArray(value)) {
      for (const item of value) url.searchParams.append(key, item);
    } else if (value !== undefined) {
      url.searchParams.set(key, value);
    }
  }
  return new NextRequest(url, { headers: requestHeaders });
}

export default async function MagicLinkCallbackPage(props: {
  searchParams: Promise<SearchParams>;
}) {
  const searchParams = await props.searchParams;
  const nativeReturnTo = firstParam(searchParams, "native_app_return_to");

  if (nativeReturnTo && isMobileNativeReturnTo(nativeReturnTo)) {
    const model = await mobileMagicLinkCallbackModel(await mobileRequest(searchParams));
    if (!model) redirect("/");
    const scriptHref = JSON.stringify(model.href).replaceAll("<", "\\u003c");
    return (
      <main>
        <h1>{model.messages.title}</h1>
        <p>{model.messages.body}</p>
        <a href={model.href}>{model.label}</a>
        <script dangerouslySetInnerHTML={{ __html: `window.location.replace(${scriptHref});` }} />
      </main>
    );
  }

  if (!stackServerApp) notFound();

  return (
    <Suspense>
      <StackHandler
        fullPage
        app={stackServerApp}
        params={Promise.resolve({ stack: ["magic-link-callback"] })}
      />
    </Suspense>
  );
}
