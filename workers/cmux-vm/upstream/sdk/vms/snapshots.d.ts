import type { FreestyleClient } from "../client.js";
/** A snapshot as its owner sees it. */
export interface SnapshotData {
    id: string;
    sourceVmId?: string | null;
    /** Your handle for this snapshot; boot from it anywhere an id is taken. */
    slug?: string | null;
    /** The snapshot's label, if it has one. Shown in place of the slug. */
    displayName?: string | null;
    /** Owning account; public snapshots from other accounts are read-only. */
    accountId?: string | null;
    /** Public snapshots are bootable by any account. */
    public: boolean;
    /**
     * Delete the snapshot once this long has passed without a VM being created
     * from it. Absent means never; some plans cap it and the cap shows up here.
     */
    autoDeleteSeconds?: number | null;
    /**
     * Whether {@link SnapshotData.autoDeleteSeconds} is your plan's doing rather
     * than yours; one your plan set goes away by itself if you move to a plan
     * that does not reclaim unused snapshots.
     */
    autoDeleteFromPlan?: boolean;
    /**
     * Delete the snapshot this long after it was taken, however recently
     * anything booted it.
     */
    ttlSeconds?: number | null;
    /**
     * When a VM was last created from this snapshot. Absent if none ever has
     * been — which is not the same as untouched, since renaming a snapshot is
     * not using it.
     */
    lastUsedAt?: string | null;
    createdAt: string;
    updatedAt: string;
}
export interface CreateSnapshotOptions {
    /**
     * A URL-safe handle you can boot from directly, in place of the id.
     */
    slug?: string;
    /**
     * A label for a slug that does not read as a name — a build id, a commit
     * sha. Shown in place of the slug.
     */
    displayName?: string;
    /**
     * Delete the snapshot once this many seconds pass without a VM being created
     * from it. Every create from it resets the clock. -1 (or omitting this)
     * means never; some plans cap this, and on those omitting it (or sending
     * -1) gets you the cap.
     */
    autoDeleteSeconds?: number;
    /**
     * Delete the snapshot this many seconds after it is taken, whatever has
     * booted it since.
     */
    ttlSeconds?: number;
}
export interface UpdateSnapshotOptions {
    /** An empty string clears it. */
    slug?: string;
    /** An empty string clears it. See {@link CreateSnapshotOptions.displayName}. */
    displayName?: string;
    /**
     * Seconds of nothing being created from it before the snapshot is deleted;
     * -1 removes the window. On a plan that caps it, -1 puts you back on the
     * cap.
     */
    autoDeleteSeconds?: number;
    /**
     * Seconds from when the snapshot was taken — not from now — before it is
     * deleted; -1 removes the deadline.
     */
    ttlSeconds?: number;
}
export interface SnapshotCreated {
    snapshotId: string;
    sourceVmId: string | null;
    snapshot: SnapshotData;
}
export interface ListSnapshotsOptions {
    /** Only snapshots taken from this VM. */
    sourceVmId?: string;
    limit?: number;
    offset?: number;
}
export interface ListSnapshotsResult {
    snapshots: SnapshotData[];
    totalCount: number;
}
/** The `freestyle.vms.snapshots` namespace: `GET /v5/snapshots`, `/v5/snapshots/{id}`. */
export declare class VmSnapshotsNamespace {
    private readonly client;
    constructor(client: FreestyleClient);
    list(options?: ListSnapshotsOptions): Promise<ListSnapshotsResult>;
    get(snapshotId: string): Promise<SnapshotData>;
    update(snapshotId: string, options: UpdateSnapshotOptions): Promise<SnapshotData>;
    delete(snapshotId: string): Promise<void>;
}
//# sourceMappingURL=snapshots.d.ts.map