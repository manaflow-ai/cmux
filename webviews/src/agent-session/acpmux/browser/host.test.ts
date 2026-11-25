import { expect, test } from "bun:test";
import { browserSocketURL, isBrowserPane } from "./host";

test("the browser socket is the listener's /app/ws, the only path its scoped token admits", () => {
  expect(browserSocketURL(new URL("http://localhost:4000/app/?session=s#token=t")).href).toBe(
    "ws://localhost:4000/app/ws",
  );
  expect(browserSocketURL(new URL("https://box.example:8443/app/index.html")).href).toBe(
    "wss://box.example:8443/app/ws",
  );
});

test("only the listener's /app/ entry installs the browser host", () => {
  expect(isBrowserPane(new URL("http://localhost:4000/app/"))).toBe(true);
  expect(isBrowserPane(new URL("http://localhost:4000/app/index.html"))).toBe(true);
  expect(isBrowserPane(new URL("http://localhost:4000/"))).toBe(false);
  expect(isBrowserPane(new URL("file:///app/"))).toBe(false);
});
