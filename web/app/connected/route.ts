import { NextRequest, NextResponse } from "next/server";
import { localeDirection } from "../../i18n/routing";
import { preferredLocale } from "../lib/preferred-locale";
import {
  connectedReturnHref,
  resolveConnectedApp,
  resolveConnectedStatus,
} from "./apps";
import { renderConnectedPage } from "./page-html";
import { resolveConnectedPageVariant } from "./variants";

/**
 * `GET /connected?app=<id>&status=ok|error[&return=<own scheme>][&variant=<id>]`: the page
 * every sign-in callback ends on when the person is in a browser tab (MCP servers' loopback,
 * Settings > Connections, any app's OAuth). "Back to cmux" opens `<scheme>://` (tried once on
 * load); in cmux's own browser that link hands off in-process and closes the tab.
 */
type ConnectedMessages = {
  title: string;
  titleGeneric: string;
  errorTitle: string;
  errorTitleGeneric: string;
  body: string;
  errorBody: string;
  button: string;
  closeHint: string;
};

export async function GET(request: NextRequest): Promise<NextResponse> {
  const params = request.nextUrl.searchParams;
  const locale = preferredLocale(request);
  const messages = (
    (await import(`../../messages/${locale}.json`)).default as { connected: ConnectedMessages }
  ).connected;
  const app = resolveConnectedApp(params.get("app"));
  const status = resolveConnectedStatus(params.get("status"));
  const title =
    status === "ok"
      ? app
        ? messages.title.replace("{app}", app.name)
        : messages.titleGeneric
      : app
        ? messages.errorTitle.replace("{app}", app.name)
        : messages.errorTitleGeneric;
  const html = renderConnectedPage({
    locale,
    dir: localeDirection(locale),
    title,
    body: status === "ok" ? messages.body : messages.errorBody,
    button: messages.button,
    href: connectedReturnHref(params.get("return")),
    hint: messages.closeHint,
    app,
    status,
    variant: resolveConnectedPageVariant(params.get("variant")),
    autoOpen: status === "ok",
  });
  return new NextResponse(html, {
    headers: {
      "Content-Type": "text/html; charset=utf-8",
      "Cache-Control": "no-store",
      "X-Robots-Tag": "noindex",
      "Referrer-Policy": "no-referrer",
    },
  });
}
