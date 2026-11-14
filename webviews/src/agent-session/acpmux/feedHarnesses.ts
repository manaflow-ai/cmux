// The probe harnesses whose models the public model feed names (modelCatalogData.ts feedModels):
// what one lists while this Mac does not have it, so the model picker's search finds its models
// before its own probe can name them.

/** The feed's providers whose models a probe harness runs, by catalog harness id: OpenCode serves
 *  OpenCode Zen (`opencode/…`) and OpenCode Go (`opencode-go/…`) under these very ids. */
export const FEED_PROVIDERS: Readonly<Record<string, readonly string[]>> = { opencode: ["opencode", "opencode-go"] };

/** Whether `harnessId`, while this Mac does not have it, lists the feed's models rather than its
 *  own: the search ranks those after the vendors' own harnesses. */
export const listsFeedModels = (harnessId: string): boolean => harnessId in FEED_PROVIDERS;
