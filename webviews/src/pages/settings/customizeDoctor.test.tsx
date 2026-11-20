// Personalization > Customization Problems: with nothing found (or all of it dismissed) no card and
// no notice draw; a remove asks first and only its confirm runs `doctor fix ID remove`; Dismiss runs
// `doctor dismiss ID`; a refusal shows the CLI's words and changes nothing; the notice's Review opens
// the card.
import { afterAll, afterEach, expect, test } from "bun:test";
import { installDom } from "./testDom";
import type { MockOptions } from "./mockProvider";
import type { Rendered } from "./testing";

const restore = installDom();
afterAll(() => restore());
const { renderPage, settle, click } = await import("./testing");
const { mockDoctor, mockAllDoctor, mockDismissedDoctor, mockEmptyDoctor, mockOverrideDoctor, report, DOCTOR_FINDINGS } =
  await import("./mockDoctor");
const { setDoctorTreatment } = await import("./customizeDoctor");

let page: Rendered | null = null;
afterEach(() => {
  page?.unmount();
  page = null;
  setDoctorTreatment("chip");
});

const card = () => page!.container.querySelector<HTMLElement>('[data-card="customizeDoctor"]');
const finding = (id: string) => card()!.querySelector<HTMLElement>(`[data-doctor-finding="${id}"]`)!;
const fix = (id: string, kind: string) => finding(id).querySelector<HTMLButtonElement>(`[data-doctor-fix="${kind}"]`)!;
const notice = () => page!.container.querySelector<HTMLElement>("[data-doctor-notice]");
const LAYER = DOCTOR_FINDINGS.layer!.id;
const BROKEN = DOCTOR_FINDINGS.broken!.id;
const LEFTOVER = DOCTOR_FINDINGS.leftover!.id;

async function open(mock?: MockOptions, path = "/settings/personalization") {
  page = await renderPage({ path, mock });
  await settle();
  return page;
}

test("no findings: the doctor was read and neither the card nor the notice draws", async () => {
  await open({ doctor: mockEmptyDoctor() });
  const read = page!.provider.log.filter(
    (call) => call.op === "cmux.settings.customize.library" && (call.params as { verb?: string }).verb === "doctor",
  );
  expect(read.length).toBeGreaterThan(0);
  expect(card()).toBeNull();
  expect(notice()).toBeNull();
});

test("every finding dismissed: nothing draws (the end state is the start state)", async () => {
  const all = mockDoctor();
  await open({ doctor: report(all.findings.map((one) => ({ ...one, dismissed: true }))) });
  expect(card()).toBeNull();
  expect(notice()).toBeNull();
});

test("a stale layer and a broken theme: each draws its title, place, detail and fixes, and the chip its line", async () => {
  await open({ doctor: mockDoctor() });
  expect(finding(LAYER).textContent).toContain("pr-45206 is still on");
  expect(finding(LAYER).textContent).toContain("Customization Library");
  expect(fix(LAYER, "off").textContent).toBe("Turn off");
  expect(finding(BROKEN).textContent).toContain("themes/night.json:3");
  expect(finding(BROKEN).textContent).toContain("malformed JSON at line 3");
  expect(fix(BROKEN, "open").textContent).toBe("Open");
  expect(notice()!.dataset.doctorNotice).toBe("chip");
  expect(notice()!.querySelector(".doctor-line")!.textContent).toBe(mockDoctor().line!);
});

test("all eleven kinds (override and not-default among them) draw, warnings first", async () => {
  await open({ doctor: mockAllDoctor() });
  const kinds = [...card()!.querySelectorAll<HTMLElement>("[data-doctor-finding]")].map(
    (row) => row.dataset.doctorKind,
  );
  expect(new Set(kinds).size).toBe(11);
  expect(kinds).toContain("not-default");
  expect(kinds).toContain("override");
  const levels = [...card()!.querySelectorAll<HTMLElement>("[data-doctor-finding]")].map((row) => row.dataset.level);
  expect(levels.indexOf("info")).toBeGreaterThan(levels.lastIndexOf("warning"));
});

test("Remove asks first, with Cancel focused; only the confirm runs `doctor fix ID remove`", async () => {
  await open({ doctor: mockDismissedDoctor() });
  await click(fix(LEFTOVER, "remove"));
  await settle();
  expect(page!.provider.doctorRuns).toEqual([]);
  const confirm = card()!.querySelector<HTMLElement>("[data-doctor-confirm]")!;
  expect(confirm.textContent).toContain("Remove layers/branch-sidebar-tint?");
  expect(confirm.textContent).toContain("keeps a copy");
  expect(document.activeElement).toBe(confirm.querySelector('[data-doctor-action="cancel"]'));
  await click(confirm.querySelector('[data-doctor-action="cancel"]')!);
  await settle();
  expect(card()!.querySelector("[data-doctor-confirm]")).toBeNull();
  expect(page!.provider.doctorRuns).toEqual([]);
  await click(fix(LEFTOVER, "remove"));
  await settle();
  await click(card()!.querySelector('[data-doctor-action="confirm"]')!);
  await settle();
  expect(page!.provider.doctorRuns).toEqual([{ verb: "doctor-fix", id: LEFTOVER, fix: "remove" }]);
  expect(card()!.querySelector(`[data-doctor-finding="${LEFTOVER}"]`)).toBeNull();
});

test("Turn off and Open run at once; Open is the host's `doctor-open`", async () => {
  await open({ doctor: mockDoctor() });
  await click(fix(BROKEN, "open"));
  await settle();
  await click(fix(LAYER, "off"));
  await settle();
  expect(page!.provider.doctorRuns).toEqual([
    { verb: "doctor-open", id: BROKEN },
    { verb: "doctor-fix", id: LAYER, fix: "off" },
  ]);
});

test("Dismiss runs `doctor dismiss ID`; the last one dismissed takes the card and the notice away", async () => {
  await open({ doctor: report([DOCTOR_FINDINGS.layer!]) });
  await click(finding(LAYER).querySelector<HTMLButtonElement>(".ui-dismiss")!);
  await settle();
  expect(page!.provider.doctorRuns).toEqual([{ verb: "doctor-dismiss", id: LAYER }]);
  expect(card()).toBeNull();
  expect(notice()).toBeNull();
});

test("a dismissed finding draws muted, marked Dismissed, with no Dismiss of its own", async () => {
  await open({ doctor: mockDismissedDoctor() });
  const row = finding(BROKEN);
  expect(row.dataset.dismissed).toBe("");
  expect(row.querySelector("[data-doctor-dismissed]")!.textContent).toContain("Dismissed");
  expect(row.querySelector(".ui-dismiss")).toBeNull();
});

test("a refusal shows the CLI's words and changes nothing", async () => {
  await open({ doctor: mockDoctor(), doctorRefusal: 'there is no finding "layer-on:pr-45206"' });
  await click(fix(LAYER, "off"));
  await settle();
  expect(page!.provider.doctorRuns).toEqual([{ verb: "doctor-fix", id: LAYER, fix: "off" }]);
  expect(card()!.querySelector("[data-doctor-refusal]")!.textContent).toBe(
    'Not changed: there is no finding "layer-on:pr-45206"',
  );
  expect(finding(LAYER)).not.toBeNull();
});

test("a host that cannot run the doctor draws no card and no notice", async () => {
  await open({ failing: { "cmux.settings.customize.library": "cmux.page.unavailable" } });
  expect(card()).toBeNull();
  expect(notice()).toBeNull();
});

test("the chip's Review, on another page, opens Personalization on the card", async () => {
  const scrolled: HTMLElement[] = [];
  const view = globalThis.window.HTMLElement.prototype;
  const original = view.scrollIntoView;
  view.scrollIntoView = function (this: HTMLElement) {
    scrolled.push(this);
  };
  try {
    await open({ doctor: mockDoctor() }, "/settings/general");
    expect(card()).toBeNull();
    await click(notice()!.querySelector<HTMLElement>('[data-doctor-action="review"]')!);
    await settle();
    expect(page!.history.location.pathname).toBe("/settings/personalization");
    expect(card()).not.toBeNull();
    expect(scrolled).toContain(card()!);
  } finally {
    view.scrollIntoView = original;
  }
});

test("the banner treatment draws a warning Notice with Review; inline draws the count in the card header", async () => {
  setDoctorTreatment("banner");
  await open({ doctor: mockDoctor() });
  const banner = page!.container.querySelector<HTMLElement>('[data-doctor-notice="banner"]')!;
  expect(banner.querySelector('[data-kind="warning"]')).not.toBeNull();
  expect(banner.querySelector('[data-notice-action="review"]')!.textContent).toBe("Review");
  expect(page!.container.querySelector('[data-doctor-notice="chip"]')).toBeNull();
  page!.unmount();
  setDoctorTreatment("inline");
  await open({ doctor: mockDoctor() });
  const inline = card()!.querySelector<HTMLElement>('[data-doctor-notice="inline"]')!;
  expect(inline.querySelector("[data-count]")!.textContent).toBe("3");
  expect(page!.container.querySelectorAll("[data-doctor-notice]")).toHaveLength(1);
});

test("Restore last good asks first and says the broken text is kept; only the confirm runs `doctor fix ID restore`", async () => {
  await open({ doctor: mockDoctor() });
  await click(fix(BROKEN, "restore"));
  await settle();
  expect(page!.provider.doctorRuns).toEqual([]);
  const confirm = finding(BROKEN).querySelector<HTMLElement>("[data-doctor-confirm]")!;
  expect(confirm.textContent).toContain("Restore the last themes/night.json that loaded?");
  expect(confirm.textContent).toContain("moves the broken text aside and keeps it");
  expect(document.activeElement).toBe(confirm.querySelector('[data-doctor-action="cancel"]'));
  await click(confirm.querySelector('[data-doctor-action="confirm"]')!);
  await settle();
  expect(page!.provider.doctorRuns).toEqual([{ verb: "doctor-fix", id: BROKEN, fix: "restore" }]);
  expect(card()!.querySelector(`[data-doctor-finding="${BROKEN}"]`)).toBeNull();
  expect(card()!.querySelector("[data-doctor-said]")!.textContent).toContain("the broken text is kept");
});

test("Recover… asks first with the CLI's plan; only the confirm runs `doctor-recover`, and the end state is the start state", async () => {
  // The stale layer and the broken theme: everything Recover takes back.
  const both = report([DOCTOR_FINDINGS.layer!, DOCTOR_FINDINGS.broken!]);
  await open({ doctor: both });
  await click(card()!.querySelector<HTMLElement>('[data-doctor-action="recover"]')!);
  await settle();
  expect(page!.provider.doctorRuns).toEqual([]);
  const confirm = card()!.querySelector<HTMLElement>("[data-doctor-confirm]")!;
  expect(confirm.textContent).toContain("Recover your customizations?");
  expect(confirm.textContent).toContain(both.recover!.said);
  expect(document.activeElement).toBe(confirm.querySelector('[data-doctor-action="cancel"]'));
  await click(confirm.querySelector('[data-doctor-action="confirm"]')!);
  await settle();
  expect(page!.provider.doctorRuns).toEqual([{ verb: "doctor-recover" }]);
  expect(card()).toBeNull();
  expect(notice()).toBeNull();
});

test("no recover plan: no Recover… on the card or the notice", async () => {
  await open({ doctor: mockOverrideDoctor() });
  expect(finding(DOCTOR_FINDINGS.override!.id).dataset.doctorKind).toBe("override");
  expect(card()!.querySelector('[data-doctor-action="recover"]')).toBeNull();
  expect(notice()!.querySelector('[data-doctor-action="recover"]')).toBeNull();
});

test("the notice's Recover… opens the card with Recover's question open, still asked first", async () => {
  await open({ doctor: mockDoctor() }, "/settings/general");
  await click(notice()!.querySelector<HTMLElement>('[data-doctor-action="recover"]')!);
  await settle();
  expect(page!.history.location.pathname).toBe("/settings/personalization");
  const confirm = card()!.querySelector<HTMLElement>("[data-doctor-confirm]")!;
  expect(confirm.textContent).toContain("Recover your customizations?");
  expect(page!.provider.doctorRuns).toEqual([]);
});

test("Leo's hidden pane dividers: the not-default finding says yours and the default, and Follow default runs at once", async () => {
  const id = DOCTOR_FINDINGS.notDefault!.id;
  await open({ doctor: mockDoctor() });
  expect(finding(id).dataset.doctorKind).toBe("not-default");
  expect(finding(id).textContent).toContain("Yours: 0, default: follows Window opacity.");
  expect(fix(id, "follow-default").textContent).toBe("Follow default");
  await click(fix(id, "follow-default"));
  await settle();
  expect(card()!.querySelector("[data-doctor-confirm]")).toBeNull();
  expect(page!.provider.doctorRuns).toEqual([{ verb: "doctor-fix", id, fix: "follow-default" }]);
  expect(card()!.querySelector(`[data-doctor-finding="${id}"]`)).toBeNull();
  expect(card()!.querySelector("[data-doctor-said]")!.textContent).toContain("a copy of your settings file is kept");
});
