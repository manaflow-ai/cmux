import { describe, expect, test } from "bun:test";

// Reconciliation invariants for the newsletter audience sync: unsubscribe is
// a one-way door, updates only backfill missing names, and re-running the
// same sync plans zero writes.

import {
  mergeContactSources,
  normalizeEmail,
  splitDisplayName,
  type NewsletterContact,
} from "../services/newsletter/contacts";
import {
  planAudienceSync,
  type ExistingContact,
} from "../services/newsletter/reconcile";

function contact(
  email: string,
  firstName?: string,
  lastName?: string,
): NewsletterContact {
  return {
    email,
    ...(firstName ? { firstName } : {}),
    ...(lastName ? { lastName } : {}),
    sources: ["stack"],
  };
}

describe("normalizeEmail", () => {
  test("lowercases and trims", () => {
    expect(normalizeEmail("  Ada@Example.COM ")).toBe("ada@example.com");
  });

  test("rejects empty and non-address values", () => {
    expect(normalizeEmail("")).toBeNull();
    expect(normalizeEmail("   ")).toBeNull();
    expect(normalizeEmail("not-an-email")).toBeNull();
    expect(normalizeEmail(null)).toBeNull();
    expect(normalizeEmail(undefined)).toBeNull();
  });
});

describe("splitDisplayName", () => {
  test("splits first and last", () => {
    expect(splitDisplayName("Ada Lovelace")).toEqual({
      firstName: "Ada",
      lastName: "Lovelace",
    });
  });

  test("multi-part last names stay together", () => {
    expect(splitDisplayName("Ada King of Lovelace")).toEqual({
      firstName: "Ada",
      lastName: "King of Lovelace",
    });
  });

  test("single token has no last name", () => {
    expect(splitDisplayName("Ada")).toEqual({ firstName: "Ada" });
  });

  test("empty input yields no name fields (never empty strings)", () => {
    expect(splitDisplayName("")).toEqual({});
    expect(splitDisplayName("   ")).toEqual({});
    expect(splitDisplayName(null)).toEqual({});
    expect(splitDisplayName(undefined)).toEqual({});
  });
});

describe("mergeContactSources", () => {
  test("dedupes across sources by email and unions the source tags", () => {
    const merged = mergeContactSources([
      [contact("ada@example.com", "Ada", "Lovelace")],
      [
        {
          email: "ada@example.com",
          firstName: "Ada",
          sources: ["stripe"],
        },
        { email: "grace@example.com", sources: ["stripe"] },
      ],
    ]);
    expect(merged).toHaveLength(2);
    const ada = merged.find((c) => c.email === "ada@example.com");
    expect(ada?.sources.sort()).toEqual(["stack", "stripe"]);
  });

  test("the more complete name wins regardless of source order", () => {
    const merged = mergeContactSources([
      [{ email: "ada@example.com", firstName: "A", sources: ["stack"] }],
      [
        {
          email: "ada@example.com",
          firstName: "Ada",
          lastName: "Lovelace",
          sources: ["stripe"],
        },
      ],
    ]);
    expect(merged[0].firstName).toBe("Ada");
    expect(merged[0].lastName).toBe("Lovelace");
  });

  test("on an equally complete name the earlier source wins", () => {
    const merged = mergeContactSources([
      [
        {
          email: "ada@example.com",
          firstName: "Ada",
          lastName: "Lovelace",
          sources: ["stack"],
        },
      ],
      [
        {
          email: "ada@example.com",
          firstName: "Augusta",
          lastName: "King",
          sources: ["stripe"],
        },
      ],
    ]);
    expect(merged[0].firstName).toBe("Ada");
    expect(merged[0].lastName).toBe("Lovelace");
  });
});

describe("planAudienceSync", () => {
  const existing: ExistingContact[] = [
    {
      id: "c_present",
      email: "present@example.com",
      firstName: "Prescilla",
      lastName: "Present",
      unsubscribed: false,
    },
    {
      id: "c_unsub",
      email: "unsub@example.com",
      unsubscribed: true,
    },
    {
      id: "c_noname",
      email: "noname@example.com",
      unsubscribed: false,
    },
  ];

  test("plans creates for new contacts only", () => {
    const plan = planAudienceSync(
      [contact("new@example.com", "New", "Person")],
      existing,
    );
    expect(plan.toCreate).toEqual([
      { email: "new@example.com", firstName: "New", lastName: "Person" },
    ]);
    expect(plan.toBackfillName).toHaveLength(0);
  });

  test("never writes an unsubscribed contact, even with new name data", () => {
    const plan = planAudienceSync(
      [contact("unsub@example.com", "Una", "Subscribed")],
      existing,
    );
    expect(plan.toCreate).toHaveLength(0);
    expect(plan.toBackfillName).toHaveLength(0);
    expect(plan.skippedUnsubscribed).toBe(1);
  });

  test("no plan entry ever carries an unsubscribed field", () => {
    const plan = planAudienceSync(
      [contact("new@example.com"), contact("present@example.com")],
      existing,
    );
    for (const create of plan.toCreate) {
      expect("unsubscribed" in create).toBe(false);
    }
    for (const update of plan.toBackfillName) {
      expect("unsubscribed" in update).toBe(false);
    }
  });

  test("backfills only missing name fields", () => {
    const plan = planAudienceSync(
      [contact("noname@example.com", "Nova", "Named")],
      existing,
    );
    expect(plan.toBackfillName).toEqual([
      {
        contactId: "c_noname",
        email: "noname@example.com",
        firstName: "Nova",
        lastName: "Named",
      },
    ]);
  });

  test("does not overwrite an existing name", () => {
    const plan = planAudienceSync(
      [contact("present@example.com", "Different", "Name")],
      existing,
    );
    expect(plan.toBackfillName).toHaveLength(0);
    expect(plan.alreadyPresent).toBe(1);
  });

  test("matches existing contacts case-insensitively", () => {
    const plan = planAudienceSync(
      [contact("present@example.com")],
      [
        {
          id: "c_present",
          email: "Present@Example.com",
          firstName: "P",
          unsubscribed: false,
        },
      ],
    );
    expect(plan.toCreate).toHaveLength(0);
    expect(plan.alreadyPresent).toBe(1);
  });

  test("re-running the applied plan is a no-op", () => {
    const desired = [
      contact("new@example.com", "New", "Person"),
      contact("noname@example.com", "Nova", "Named"),
    ];
    const first = planAudienceSync(desired, existing);
    // Simulate the applied state after the first run.
    const afterApply: ExistingContact[] = [
      ...existing.map((c) =>
        c.id === "c_noname"
          ? { ...c, firstName: "Nova", lastName: "Named" }
          : c,
      ),
      {
        id: "c_new",
        email: "new@example.com",
        firstName: "New",
        lastName: "Person",
        unsubscribed: false,
      },
    ];
    const second = planAudienceSync(desired, afterApply);
    expect(first.toCreate).toHaveLength(1);
    expect(first.toBackfillName).toHaveLength(1);
    expect(second.toCreate).toHaveLength(0);
    expect(second.toBackfillName).toHaveLength(0);
    expect(second.alreadyPresent).toBe(2);
  });
});
