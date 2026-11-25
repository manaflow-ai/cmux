import { expect, test } from "bun:test";
import { renderToStaticMarkup } from "react-dom/server";
import type { Strings } from "../shared/i18n";
import { SourceLink } from "./SourceLink";
import { sourceLink } from "./sourceLinkTarget";
import { fromInstalled, fromListing, type WireInstalledApp, type WireListing } from "./wire";

const strings: Strings = { language: "en", t: (key) => key, format: (key) => key };
const commit = "3f9c2a1b7d4e5f60718293a4b5c6d7e8f9012345";

test("a github app in a subdirectory links its tree at the pinned commit", () => {
  expect(sourceLink({ repository: "https://github.com/acme/apps", path: "tools/standup", commit })).toEqual({
    text: "github.com/acme/apps/tools/standup @ 3f9c2a1",
    href: `https://github.com/acme/apps/tree/${commit}/tools/standup`,
  });
});

test("a root app on codeberg and gitlab uses each host's tree path", () => {
  expect(sourceLink({ repository: "https://codeberg.org/acme/app", commit })?.href).toBe(
    `https://codeberg.org/acme/app/tree/${commit}`,
  );
  expect(sourceLink({ repository: "https://gitlab.com/acme/app", commit })).toEqual({
    text: "gitlab.com/acme/app @ 3f9c2a1",
    href: `https://gitlab.com/acme/app/-/tree/${commit}`,
  });
});

test("another host links the repository itself", () => {
  expect(sourceLink({ repository: "https://git.example.com/acme/app", path: "x", commit })).toEqual({
    text: "git.example.com/acme/app/x @ 3f9c2a1",
    href: "https://git.example.com/acme/app",
  });
});

test("no pinned link without an https repository and a hex commit", () => {
  expect(sourceLink({ repository: "https://github.com/acme/app" })).toBeUndefined();
  expect(sourceLink({ repository: "http://github.com/acme/app", commit })).toBeUndefined();
  expect(sourceLink({ repository: "https://github.com/acme/app", commit: "main" })).toBeUndefined();
});

test("the page shows the pinned source, and the plain Repository link for any other app", () => {
  const pinned = renderToStaticMarkup(
    <SourceLink source={{ repository: "https://github.com/acme/apps", path: "standup", commit }} strings={strings} />,
  );
  expect(pinned).toContain(`href="https://github.com/acme/apps/tree/${commit}/standup"`);
  expect(pinned).toContain("github.com/acme/apps/standup @ 3f9c2a1");
  expect(pinned).toContain('target="_blank"');

  const plain = renderToStaticMarkup(
    <SourceLink source={{ repository: "https://github.com/acme/app" }} strings={strings} />,
  );
  expect(plain).toContain('href="https://github.com/acme/app"');
  expect(plain).not.toContain(" @ ");
  expect(renderToStaticMarkup(<SourceLink source={{}} strings={strings} />)).toBe("");
});

test("the wire's git source reaches catalog and installed rows; non-git rows carry none", () => {
  const listing: WireListing = {
    app: "acme/standup",
    name: "Standup",
    summary: "",
    publisher: "acme",
    tier: "unverified",
    version: "1.0.0",
    icon: null,
    categories: [],
    hide_only: false,
    install: null,
    repository: "https://github.com/acme/apps",
    path: "standup",
    ref: "v1.0.0",
    commit,
    tag: "v1.0.0",
  };
  const app = fromListing(listing);
  expect([app.repository, app.path, app.commit, app.tag]).toEqual([
    "https://github.com/acme/apps",
    "standup",
    commit,
    "v1.0.0",
  ]);
  const plain = fromListing({
    ...listing,
    repository: undefined,
    path: undefined,
    ref: undefined,
    commit: undefined,
    tag: undefined,
  });
  expect("commit" in plain || "repository" in plain).toBe(false);

  const row: WireInstalledApp = {
    app: "acme/standup",
    name: "Standup",
    tier: "unverified",
    hide_only: false,
    state: {
      installed: true,
      enabled: true,
      hidden: false,
      sandboxed: true,
      source: "user",
      version: "1.0.0",
      update: null,
    },
    grants: [],
    repository: "https://github.com/acme/apps",
    commit,
  };
  expect(fromInstalled(row)).toMatchObject({ repository: "https://github.com/acme/apps", commit });
});
