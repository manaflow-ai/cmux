import { describe, expect, mock, test } from "bun:test";
import {
  generateKeyPairSync,
  sign as signPayload,
} from "node:crypto";

import {
  BROWSER_PUBLIC_ASSET_ORIGIN,
  BROWSER_NIGHTLY_FEED_URL,
  resolveBrowserNightlyDownload,
} from "../app/lib/browser-nightly-download";
import { handleBrowserNightlyDownloadRequest } from "../app/api/download/browser-nightly/[platform]/[artifact]/route";

const VERSION = "151.0.7922.64";
const { privateKey, publicKey } = generateKeyPairSync("ec", {
  namedCurve: "prime256v1",
});
const TEST_PUBLIC_KEY_PEM = publicKey
  .export({ format: "pem", type: "spki" })
  .toString();

// Real public nightly envelope retained as a key-compatibility fixture. It
// proves the website's checked-in key accepts the same signed bytes as cmux
// Browser without making a network request or pinning live route behavior.
const PRODUCTION_SIGNED_FEED =
  '{"payload":"eyJwbGF0Zm9ybXMiOnsibGludXgteDY0Ijp7ImFyY2hpdmVfcm9vdCI6ImNtdXgtYnJvd3NlciIsImV4ZWN1dGFibGUiOiJjaHJvbWUiLCJzaGEyNTYiOiI2NTdlZmM2MTljMzYwNmUxN2I0MTViNDlkZWQxZDQ2ZjhjMGYwZmI4YjFlNGRiYjNiNDU5NDgzZTgzOWUwMTNhIiwic2l6ZSI6IjY1MTk1MjUyMSIsInVybCI6Imh0dHBzOi8vZ2l0aHViLmNvbS9tYW5hZmxvdy1haS9jbXV4LXYyL3JlbGVhc2VzL2Rvd25sb2FkL25pZ2h0bHkvY211eC1saW51eC14NjQuemlwIn19LCJzY2hlbWEiOjEsInZlcnNpb24iOiIxNTEuMC43OTIyLjY0In0=","signature":"MEQCIDqsCafTkEF9jKuN+O99bUBWiEZBec7TzLXNvN2bw/swAiB+WnzF7teqNr4B1juRDY8mwwMqcBJbffQWvAzVDK7Ieg=="}';

describe("cmux Browser nightly download route", () => {
  test("resolves the live Linux contract through the production update key", async () => {
    const fetchMock = feedFetch(PRODUCTION_SIGNED_FEED, 302);

    const resolution = await resolveBrowserNightlyDownload(
      "linux-x64",
      "zip",
      { fetch: fetchMock },
    );

    expect(resolution).toEqual({
      version: VERSION,
      url: "https://github.com/manaflow-ai/cmux-v2/releases/download/nightly/cmux-linux-x64.zip",
    });
    expect(fetchMock).toHaveBeenCalledTimes(2);
  });

  test("redirects the stable Linux endpoint after feed and asset checks", async () => {
    const fetchMock = feedFetch(signedFeed({
      "linux-x64": platformEntry(
        "https://github.com/manaflow-ai/cmux-v2/releases/download/nightly/cmux-linux-x64.zip",
      ),
    }), 302);

    const response = await handleBrowserNightlyDownloadRequest(
      { platform: "linux-x64", artifact: "deb" },
      { fetch: fetchMock, publicKeyPem: TEST_PUBLIC_KEY_PEM },
    );

    expect(response.status).toBe(307);
    expect(response.headers.get("location")).toBe(
      "https://github.com/manaflow-ai/cmux-v2/releases/download/nightly/cmux-linux-x64.deb",
    );
    expect(response.headers.get("x-cmux-browser-version")).toBe(VERSION);
    expect(response.headers.get("cache-control")).toContain("s-maxage=300");

    const calls = fetchCalls(fetchMock);
    expect(String(calls[0]?.[0])).toBe(BROWSER_NIGHTLY_FEED_URL);
    expect(calls[0]?.[1]).toMatchObject({ cache: "no-store" });
    expect(String(calls[1]?.[0])).toBe(response.headers.get("location"));
    expect(calls[1]?.[1]).toMatchObject({
      method: "HEAD",
      redirect: "manual",
      cache: "no-store",
    });
  });

  test("resolves Universal 2 assets for both Mac architectures on an immutable tag", async () => {
    const immutableTag = `nightly-${VERSION}`;
    const envelope = signedFeed({
      "mac-arm64": platformEntry(
        `https://github.com/manaflow-ai/cmux-v2/releases/download/${immutableTag}/cmux-macos-universal.zip`,
        "cmux-browser.app",
        "Contents/MacOS/cmux",
      ),
      "mac-x64": platformEntry(
        `https://github.com/manaflow-ai/cmux-v2/releases/download/${immutableTag}/cmux-macos-universal.zip`,
        "cmux-browser.app",
        "Contents/MacOS/cmux",
      ),
    });

    for (const platform of ["mac-arm64", "mac-x64"]) {
      for (const [artifact, filename] of [
        ["dmg", "cmux-macos-universal.dmg"],
        ["zip", "cmux-macos-universal.zip"],
      ] as const) {
        const fetchMock = feedFetch(envelope, 302);
        const response = await handleBrowserNightlyDownloadRequest(
          { platform, artifact },
          { fetch: fetchMock, publicKeyPem: TEST_PUBLIC_KEY_PEM },
        );

        expect(response.status).toBe(307);
        expect(response.headers.get("location")).toBe(
          `https://github.com/manaflow-ai/cmux-v2/releases/download/${immutableTag}/${filename}`,
        );
        expect(fetchMock).toHaveBeenCalledTimes(2);
      }
    }
  });

  test("resolves Universal 2 assets from an immutable R2 feed URL", async () => {
    const envelope = signedFeed({
      "mac-arm64": platformEntry(
        `${BROWSER_PUBLIC_ASSET_ORIGIN}/nightly/${VERSION}/cmux-macos-universal.zip`,
        "cmux-browser.app",
        "Contents/MacOS/cmux",
      ),
    });
    const fetchMock = feedFetch(envelope, 200, {
      "X-Cmux-Sha256": "a".repeat(64),
      "X-Cmux-Size": "651952521",
    });

    const response = await handleBrowserNightlyDownloadRequest(
      { platform: "mac-arm64", artifact: "dmg" },
      { fetch: fetchMock, publicKeyPem: TEST_PUBLIC_KEY_PEM },
    );

    expect(response.status).toBe(307);
    expect(response.headers.get("location")).toBe(
      `${BROWSER_PUBLIC_ASSET_ORIGIN}/nightly/${VERSION}/cmux-macos-universal.dmg`,
    );
    expect(fetchMock).toHaveBeenCalledTimes(2);
  });

  test("rejects an R2 object whose signed hash or size headers differ", async () => {
    const envelope = signedFeed({
      "mac-arm64": platformEntry(
        `${BROWSER_PUBLIC_ASSET_ORIGIN}/nightly/${VERSION}/cmux-macos-universal.zip`,
        "cmux-browser.app",
        "Contents/MacOS/cmux",
      ),
    });
    const fetchMock = feedFetch(envelope, 200, {
      "X-Cmux-Sha256": "b".repeat(64),
      "X-Cmux-Size": "651952521",
    });

    const response = await handleBrowserNightlyDownloadRequest(
      { platform: "mac-arm64", artifact: "dmg" },
      { fetch: fetchMock, publicKeyPem: TEST_PUBLIC_KEY_PEM },
    );

    expect(response.status).toBe(404);
    expect(await response.json()).toEqual({
      error: "browser_download_unavailable",
    });
    expect(fetchMock).toHaveBeenCalledTimes(2);
  });

  test("keeps both Mac architectures unavailable in the current production feed", async () => {
    for (const platform of ["mac-arm64", "mac-x64"]) {
      const fetchMock = feedFetch(PRODUCTION_SIGNED_FEED, 302);
      const response = await handleBrowserNightlyDownloadRequest(
        { platform, artifact: "dmg" },
        { fetch: fetchMock },
      );

      expect(response.status).toBe(404);
      expect(await response.json()).toEqual({
        error: "browser_download_unavailable",
      });
      expect(fetchMock).toHaveBeenCalledTimes(1);
    }
  });

  test("keeps a platform unavailable until its signed feed entry exists", async () => {
    const fetchMock = feedFetch(signedFeed({
      "linux-x64": platformEntry(
        "https://github.com/manaflow-ai/cmux-v2/releases/download/nightly/cmux-linux-x64.zip",
      ),
    }), 302);

    const response = await handleBrowserNightlyDownloadRequest(
      { platform: "windows-x64", artifact: "installer" },
      { fetch: fetchMock, publicKeyPem: TEST_PUBLIC_KEY_PEM },
    );

    expect(response.status).toBe(404);
    expect(await response.json()).toEqual({
      error: "browser_download_unavailable",
    });
    expect(fetchMock).toHaveBeenCalledTimes(1);
  });

  test("keeps a companion installer unavailable until the asset is published", async () => {
    const fetchMock = feedFetch(signedFeed({
      "windows-x64": platformEntry(
        "https://github.com/manaflow-ai/cmux-v2/releases/download/nightly/cmux-windows-x64.zip",
        "cmux-browser",
        "chrome.exe",
      ),
    }), 404);

    const response = await handleBrowserNightlyDownloadRequest(
      { platform: "windows-x64", artifact: "installer" },
      { fetch: fetchMock, publicKeyPem: TEST_PUBLIC_KEY_PEM },
    );

    expect(response.status).toBe(404);
    expect(await response.json()).toEqual({
      error: "browser_download_unavailable",
    });
    expect(fetchMock).toHaveBeenCalledTimes(2);
  });

  test("rejects tampered signed payloads before checking an asset", async () => {
    const validEnvelope = signedFeed({
      "linux-x64": platformEntry(
        "https://github.com/manaflow-ai/cmux-v2/releases/download/nightly/cmux-linux-x64.zip",
      ),
    });
    const tampered = JSON.parse(validEnvelope) as {
      payload: string;
      signature: string;
    };
    const payload = Buffer.from(tampered.payload, "base64");
    payload[payload.length - 2] ^= 1;
    tampered.payload = payload.toString("base64");
    const fetchMock = feedFetch(JSON.stringify(tampered), 302);

    const response = await handleBrowserNightlyDownloadRequest(
      { platform: "linux-x64", artifact: "deb" },
      { fetch: fetchMock, publicKeyPem: TEST_PUBLIC_KEY_PEM },
    );

    expect(response.status).toBe(502);
    expect(await response.json()).toEqual({
      error: "browser_download_feed_unavailable",
    });
    expect(fetchMock).toHaveBeenCalledTimes(1);
  });

  test("rejects signed URLs outside the public repository allowlist", async () => {
    for (const url of [
      "https://github.com/manaflow-ai/cmux-browser/releases/download/nightly/cmux-linux-x64.zip",
      "https://attacker.example/manaflow-ai/cmux-v2/releases/download/nightly/cmux-linux-x64.zip",
      "https://github.com/manaflow-ai/cmux-v2/releases/download/nightly/cmux-linux-x64.zip?redirect=attacker",
      "https://github.com/manaflow-ai//cmux-v2/releases/download/nightly/cmux-linux-x64.zip",
      `https://github.com/manaflow-ai/cmux-v2/releases/download/nightly-${VERSION}.1/cmux-linux-x64.zip`,
      `${BROWSER_PUBLIC_ASSET_ORIGIN}/nightly/${VERSION}.1/cmux-linux-x64.zip`,
      `${BROWSER_PUBLIC_ASSET_ORIGIN}/nightly/${VERSION}/other.zip`,
      `${BROWSER_PUBLIC_ASSET_ORIGIN}.evil/nightly/${VERSION}/cmux-linux-x64.zip`,
      `${BROWSER_PUBLIC_ASSET_ORIGIN}/nightly/${VERSION}/cmux-linux-x64.zip?x=1`,
    ]) {
      const fetchMock = feedFetch(signedFeed({
        "linux-x64": platformEntry(url),
      }), 302);

      const response = await handleBrowserNightlyDownloadRequest(
        { platform: "linux-x64", artifact: "zip" },
        { fetch: fetchMock, publicKeyPem: TEST_PUBLIC_KEY_PEM },
      );

      expect(response.status).toBe(502);
      expect(fetchMock).toHaveBeenCalledTimes(1);
    }
  });

  test("rejects unknown platform and artifact paths without upstream I/O", async () => {
    const fetchMock = mock(async () => {
      throw new Error("unsupported routes must not fetch");
    }) as unknown as typeof fetch;

    for (const parameters of [
      { platform: "freebsd-x64", artifact: "zip" },
      { platform: "linux-x64", artifact: "pkg" },
    ]) {
      const response = await handleBrowserNightlyDownloadRequest(
        parameters,
        { fetch: fetchMock, publicKeyPem: TEST_PUBLIC_KEY_PEM },
      );
      expect(response.status).toBe(404);
      expect(await response.json()).toEqual({
        error: "browser_download_not_found",
      });
    }
    expect(fetchMock).not.toHaveBeenCalled();
  });
});

function platformEntry(
  url: string,
  archiveRoot = "cmux-browser",
  executable = "chrome",
): Record<string, string> {
  return {
    archive_root: archiveRoot,
    executable,
    sha256: "a".repeat(64),
    size: "651952521",
    url,
  };
}

function signedFeed(
  platforms: Record<string, Record<string, string>>,
  version = VERSION,
): string {
  const payload = Buffer.from(JSON.stringify({ platforms, schema: 1, version }));
  return JSON.stringify({
    payload: payload.toString("base64"),
    signature: signPayload("sha256", payload, privateKey).toString("base64"),
  });
}

function feedFetch(
  envelope: string,
  assetStatus: number,
  assetHeaders?: Record<string, string>,
) {
  return mock(async (...args: unknown[]) => {
    const input = args[0] as RequestInfo | URL;
    const init = args[1] as RequestInit | undefined;
    if (String(input) === BROWSER_NIGHTLY_FEED_URL) {
      return new Response(envelope, {
        status: 200,
        headers: {
          "Content-Length": String(Buffer.byteLength(envelope)),
          "Content-Type": "application/json",
        },
      });
    }
    expect(init?.method).toBe("HEAD");
    const headers = new Headers(assetHeaders);
    if (assetStatus >= 300 && assetStatus < 400) {
      headers.set("Location", "https://release-assets.githubusercontent.com/file");
    }
    return new Response(null, { status: assetStatus, headers });
  }) as unknown as typeof fetch;
}

function fetchCalls(fetchMock: typeof fetch) {
  return (fetchMock as unknown as {
    mock: {
      calls: Array<[RequestInfo | URL, RequestInit | undefined]>;
    };
  }).mock.calls;
}
