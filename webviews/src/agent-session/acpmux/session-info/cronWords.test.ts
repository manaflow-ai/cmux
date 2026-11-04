import { describe, expect, test } from "bun:test";
import { translatorFor } from "../i18n";
import { cronWords, nextCronFire } from "./cronWords";

const t = translatorFor("en");
const words = (cron: string) => cronWords(cron, t, "en-US");

describe("cronWords", () => {
  test("Leo's case: '17 * * * *' reads hourly at :17", () => {
    expect(words("17 * * * *")).toBe("hourly at :17");
    expect(words("5 * * * *")).toBe("hourly at :05");
  });

  test("every minute and every N minutes", () => {
    expect(words("* * * * *")).toBe("every minute");
    expect(words("*/5 * * * *")).toBe("every 5 min");
  });

  test("every N hours at a minute", () => {
    expect(words("0 */2 * * *")).toBe("every 2 h at :00");
  });

  test("daily, weekdays and weekly at a time of day", () => {
    expect(words("30 9 * * *")).toBe("daily at 9:30 AM");
    expect(words("0 9 * * 1-5")).toBe("weekdays at 9:00 AM");
    expect(words("0 17 * * 5")).toBe("weekly on Friday at 5:00 PM");
    expect(words("0 8 * * 0")).toBe("weekly on Sunday at 8:00 AM");
    expect(words("0 8 * * 7")).toBe("weekly on Sunday at 8:00 AM");
  });

  test("monthly and one pinned date", () => {
    expect(words("0 9 1 * *")).toBe("monthly on day 1 at 9:00 AM");
    expect(words("30 14 3 11 *")).toBe("on Nov 3 at 2:30 PM");
  });

  test("a shape it does not know stays the raw string", () => {
    expect(words("0,30 9 * * *")).toBe("0,30 9 * * *");
    expect(words("0 9 * * MON")).toBe("0 9 * * MON");
    expect(words("*/1 * * * *")).toBe("*/1 * * * *");
    expect(words("61 * * * *")).toBe("61 * * * *");
    expect(words("@hourly")).toBe("@hourly");
    expect(words("  0 9 * * 1-5 ")).toBe("weekdays at 9:00 AM");
  });
});

describe("nextCronFire", () => {
  const at = (y: number, mo: number, d: number, h: number, mi: number) => new Date(y, mo - 1, d, h, mi).getTime();

  test("the next matching local minute, strictly after", () => {
    expect(nextCronFire("17 * * * *", at(2026, 11, 3, 3, 10))).toBe(at(2026, 11, 3, 3, 17));
    expect(nextCronFire("17 * * * *", at(2026, 11, 3, 3, 17))).toBe(at(2026, 11, 3, 4, 17));
    expect(nextCronFire("*/5 * * * *", at(2026, 11, 3, 3, 11))).toBe(at(2026, 11, 3, 3, 15));
  });

  test("a pinned date, across a month and a year", () => {
    expect(nextCronFire("30 14 3 11 *", at(2026, 11, 1, 0, 0))).toBe(at(2026, 11, 3, 14, 30));
    expect(nextCronFire("0 0 1 1 *", at(2026, 11, 3, 0, 0))).toBe(at(2027, 1, 1, 0, 0));
  });

  test("weekdays, and day of month or weekday when both are set", () => {
    // 2026-11-07 is a Saturday.
    expect(nextCronFire("0 9 * * 1-5", at(2026, 11, 7, 10, 0))).toBe(at(2026, 11, 9, 9, 0));
    expect(nextCronFire("0 9 15 * 1", at(2026, 11, 7, 10, 0))).toBe(at(2026, 11, 9, 9, 0));
    // A `*/N` field does not restrict, so the two AND: an odd day that is a Monday (not Nov 11, a
    // Wednesday, nor Nov 16, an even Monday).
    expect(nextCronFire("0 9 */2 * 1", at(2026, 11, 10, 10, 0))).toBe(at(2026, 11, 23, 9, 0));
  });

  test("unreadable or impossible schedules have none", () => {
    expect(nextCronFire("@daily", 0)).toBeUndefined();
    expect(nextCronFire("0 9 * * MON", 0)).toBeUndefined();
    expect(nextCronFire("0 0 31 2 *", at(2026, 1, 1, 0, 0))).toBeUndefined();
  });
});
