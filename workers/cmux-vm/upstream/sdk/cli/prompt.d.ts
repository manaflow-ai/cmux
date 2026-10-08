/**
 * Whether this invocation may stop and ask a question: a person at a terminal,
 * and a stdout that is not owed to a machine. Anything scripted gets an error
 * naming the flag it should have passed instead.
 */
export declare function canAsk(argv: {
    output?: string;
}): boolean;
/**
 * One line of input. Questions go to stderr, so a prompt never lands in the
 * output a caller is capturing. `undefined` means the question was abandoned —
 * Ctrl-C, or stdin ending — which every caller treats as "no answer" rather
 * than as an answer of "".
 */
export declare function ask(question: string): Promise<string | undefined>;
/** A yes/no question. Anything but an explicit yes is a no. */
export declare function confirm(question: string): Promise<boolean>;
/**
 * Whether the API refused because something already holds the slug.
 *
 * 409 CONFLICT covers more than slugs — a VM create with no capacity is one
 * too — so every caller confirms by looking the slug up before offering to
 * take it.
 */
export declare function isConflict(error: unknown): boolean;
//# sourceMappingURL=prompt.d.ts.map