import { useEffect, useRef, useState } from "react";
import { loadAttachedCloudRepos, type AttachedCloudRepo, type PendingCloudRepo } from "../CloudRepositoryPicker";
import type { NativeInfoRect } from "./model";

/// The same repository route as EnvironmentSection. Closing the panel or changing chats retires its read.
export function useCloudRepositories(session: string | undefined, shown: boolean) {
  const [attachedRepos, setAttachedRepos] = useState<AttachedCloudRepo[]>([]);
  const [pendingRepos, setPendingRepos] = useState<PendingCloudRepo[]>([]);
  const [picker, setPicker] = useState<NativeInfoRect>();
  const anchor = useRef<HTMLElement>(null);
  useEffect(() => {
    setAttachedRepos([]);
    setPendingRepos([]);
    setPicker(undefined);
    if (!session || !shown) return;
    let live = true;
    void loadAttachedCloudRepos(session)
      .then(({ repos, pending }) => {
        if (!live) return;
        setAttachedRepos(repos);
        setPendingRepos(pending);
      })
      .catch(() => undefined);
    return () => {
      live = false;
    };
  }, [session, shown]);
  return {
    attachedRepos,
    pendingRepos,
    picker,
    anchor,
    open: (rect?: NativeInfoRect) => {
      if (rect) setPicker(rect);
    },
    close: () => setPicker(undefined),
    attached: (repo: AttachedCloudRepo) => setAttachedRepos((current) => [...current, repo]),
  };
}
