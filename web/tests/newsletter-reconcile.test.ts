import { describe, expect, test } from "bun:test";

// Reconciliation invariants for the newsletter segment sync: subscription
// state is a one-way door (globally unsubscribed contacts get zero writes),
// updates only backfill missing names, and re-running the same sync plans
// zero writes.

import {
  mergeContactSources,
  normalizeEmail,
  splitDisplayName,
  type NewsletterContact,
} from "../services/newsletter/contacts";
import {
  planSegmentSync,
  type ExistingContact,
} from "../services/newsletter/reconcile";

function contact(
  email: string,
  firstName?: string,
  lastName?: string,
  stackUserId?: string,
): NewsletterContact {
  return {
    email,
    ...(stackUserId ? { stackUserId } : {}),
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

describe("planSegmentSync", () => {
  const existingContacts: ExistingContact[] = [
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
    {
      id: "c_outside",
      email: "outside@example.com",
      firstName: "Otto",
      unsubscribed: false,
    },
  ];
  // present and noname are in the segment; outside is a global contact that
  // has not been added to this segment yet.
  const memberEmails = new Set(["present@example.com", "noname@example.com"]);

  test("plans creates for contacts missing globally", () => {
    const plan = planSegmentSync({
      desired: [contact("new@example.com", "New", "Person")],
      existingContacts,
      segmentMemberEmails: memberEmails,
    });
    expect(plan.toCreate).toEqual([
      { email: "new@example.com", firstName: "New", lastName: "Person" },
    ]);
    expect(plan.toAddToSegment).toHaveLength(0);
    expect(plan.toBackfillName).toHaveLength(0);
  });

  test("plans a segment add for an existing contact outside the segment", () => {
    const plan = planSegmentSync({
      desired: [contact("outside@example.com")],
      existingContacts,
      segmentMemberEmails: memberEmails,
    });
    expect(plan.toCreate).toHaveLength(0);
    expect(plan.toAddToSegment).toEqual([
      { contactId: "c_outside", email: "outside@example.com" },
    ]);
  });

  test("matches a Stack identity across an email change and plans migration", () => {
    const plan = planSegmentSync({
      desired: [contact("new@example.com", "Ada", undefined, "stack-1")],
      existingContacts: [
        {
          id: "c_old",
          email: "old@example.com",
          stackUserId: "stack-1",
          unsubscribed: false,
        },
      ],
      segmentMemberEmails: new Set(["old@example.com"]),
    });
    expect(plan.toCreate).toHaveLength(0);
    expect(plan.blockedIdentityChanges).toBe(1);
    expect(plan.toRemoveForIdentityChange).toEqual([
      { contactId: "c_old", email: "old@example.com" },
    ]);
    expect(plan.toAddToSegment).toHaveLength(0);
    expect(plan.toBackfillName).toHaveLength(0);
  });

  test("keeps an old address claimed by another active source", () => {
    const plan = planSegmentSync({
      desired: [
        contact("new@example.com", undefined, undefined, "stack-1"),
        { email: "old@example.com", sources: ["stripe"] },
      ],
      existingContacts: [
        {
          id: "c_old",
          email: "old@example.com",
          stackUserId: "stack-1",
          unsubscribed: false,
        },
      ],
      segmentMemberEmails: new Set(["old@example.com"]),
    });
    expect(plan.blockedIdentityChanges).toBe(1);
    expect(plan.toRemoveForIdentityChange).toHaveLength(0);
  });

  test("backfills the stable Stack identity on an existing email match", () => {
    const plan = planSegmentSync({
      desired: [contact("present@example.com", "Ada", undefined, "stack-2")],
      existingContacts: [
        {
          id: "c_present",
          email: "present@example.com",
          unsubscribed: false,
        },
      ],
      segmentMemberEmails: new Set(["present@example.com"]),
    });
    expect(plan.toBackfillProperties).toEqual([
      {
        contactId: "c_present",
        email: "present@example.com",
        properties: { cmux_stack_user_id: "stack-2" },
      },
    ]);
  });

  test("a globally unsubscribed contact gets zero writes of any kind", () => {
    const plan = planSegmentSync({
      desired: [contact("unsub@example.com", "Una", "Subscribed")],
      existingContacts,
      segmentMemberEmails: memberEmails,
    });
    expect(plan.toCreate).toHaveLength(0);
    expect(plan.toAddToSegment).toHaveLength(0);
    expect(plan.toBackfillName).toHaveLength(0);
    expect(plan.skippedUnsubscribed).toBe(1);
  });

  test("does not backfill identity properties on a globally unsubscribed contact", () => {
    const plan = planSegmentSync({
      desired: [contact("unsub@example.com", undefined, undefined, "stack-unsub")],
      existingContacts: [
        {
          id: "c_unsub",
          email: "unsub@example.com",
          unsubscribed: true,
        },
      ],
      segmentMemberEmails: new Set(["unsub@example.com"]),
    });
    expect(plan.toBackfillProperties).toHaveLength(0);
    expect(plan.toBackfillName).toHaveLength(0);
    expect(plan.toAddToSegment).toHaveLength(0);
    expect(plan.skippedUnsubscribed).toBe(1);
  });

  test("no plan entry ever carries subscription state", () => {
    const plan = planSegmentSync({
      desired: [
        contact("new@example.com"),
        contact("present@example.com"),
        contact("outside@example.com"),
      ],
      existingContacts,
      segmentMemberEmails: memberEmails,
    });
    for (const entry of [
      ...plan.toCreate,
      ...plan.toAddToSegment,
      ...plan.toBackfillName,
      ...plan.toBackfillProperties,
      ...plan.toRemoveForIdentityChange,
    ]) {
      expect("unsubscribed" in entry).toBe(false);
      expect("topics" in entry).toBe(false);
    }
  });

  test("backfills only missing name fields", () => {
    const plan = planSegmentSync({
      desired: [contact("noname@example.com", "Nova", "Named")],
      existingContacts,
      segmentMemberEmails: memberEmails,
    });
    expect(plan.toBackfillName).toEqual([
      {
        contactId: "c_noname",
        email: "noname@example.com",
        firstName: "Nova",
        lastName: "Named",
      },
    ]);
    expect(plan.toAddToSegment).toHaveLength(0);
  });

  test("does not overwrite an existing name", () => {
    const plan = planSegmentSync({
      desired: [contact("present@example.com", "Different", "Name")],
      existingContacts,
      segmentMemberEmails: memberEmails,
    });
    expect(plan.toBackfillName).toHaveLength(0);
    expect(plan.alreadyPresent).toBe(1);
  });

  test("matches existing contacts and members case-insensitively", () => {
    const plan = planSegmentSync({
      desired: [contact("present@example.com")],
      existingContacts: [
        {
          id: "c_present",
          email: "Present@Example.com",
          firstName: "P",
          unsubscribed: false,
        },
      ],
      segmentMemberEmails: new Set(["Present@Example.com"]),
    });
    expect(plan.toCreate).toHaveLength(0);
    expect(plan.toAddToSegment).toHaveLength(0);
    expect(plan.alreadyPresent).toBe(1);
  });

  test("re-running the applied plan is a no-op", () => {
    const desired = [
      contact("new@example.com", "New", "Person"),
      contact("noname@example.com", "Nova", "Named"),
      contact("outside@example.com"),
    ];
    const first = planSegmentSync({
      desired,
      existingContacts,
      segmentMemberEmails: memberEmails,
    });
    // Simulate the applied state after the first run.
    const afterApply: ExistingContact[] = [
      ...existingContacts.map((c) =>
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
    const membersAfterApply = new Set([
      ...memberEmails,
      "new@example.com",
      "outside@example.com",
    ]);
    const second = planSegmentSync({
      desired,
      existingContacts: afterApply,
      segmentMemberEmails: membersAfterApply,
    });
    expect(first.toCreate).toHaveLength(1);
    expect(first.toAddToSegment).toHaveLength(1);
    expect(first.toBackfillName).toHaveLength(1);
    expect(second.toCreate).toHaveLength(0);
    expect(second.toAddToSegment).toHaveLength(0);
    expect(second.toBackfillName).toHaveLength(0);
    expect(second.alreadyPresent).toBe(3);
  });
});
