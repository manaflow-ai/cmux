import { describe, expect, mock, test } from "bun:test";
import { createElement } from "react";
import { renderToStaticMarkup } from "react-dom/server";

import { useCheckoutRedirect } from "../app/components/checkout-navigation";

describe("checkout navigation", () => {
  test("intercepts an absolute app pricing checkout URL on first activation", () => {
    const fetchMock = mock(
      () => new Promise<Response>(() => {}),
    );
    const preventDefault = mock(() => undefined);
    const previousFetch = globalThis.fetch;
    const previousWindow = Object.getOwnPropertyDescriptor(globalThis, "window");
    Object.defineProperty(globalThis, "fetch", {
      configurable: true,
      value: fetchMock,
    });
    Object.defineProperty(globalThis, "window", {
      configurable: true,
      value: { location: { assign: mock(() => undefined) } },
    });

    let start: ReturnType<typeof useCheckoutRedirect>["start"] | undefined;
    function Harness() {
      start = useCheckoutRedirect().start;
      return null;
    }

    try {
      renderToStaticMarkup(createElement(Harness));
      start?.(
        "http://localhost:9210/api/billing/checkout?plan=pro&cmux_external_browser=1",
        {
          button: 0,
          defaultPrevented: false,
          metaKey: false,
          ctrlKey: false,
          shiftKey: false,
          altKey: false,
          preventDefault,
        } as unknown as Parameters<NonNullable<typeof start>>[1],
      );

      expect(preventDefault).toHaveBeenCalledTimes(1);
      expect(fetchMock).toHaveBeenCalledWith(
        "http://localhost:9210/api/billing/checkout?plan=pro&cmux_external_browser=1&format=json",
        { headers: { accept: "application/json" } },
      );
    } finally {
      Object.defineProperty(globalThis, "fetch", {
        configurable: true,
        value: previousFetch,
      });
      if (previousWindow) {
        Object.defineProperty(globalThis, "window", previousWindow);
      } else {
        Reflect.deleteProperty(globalThis, "window");
      }
    }
  });
});
