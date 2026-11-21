// The group info sheet (HomeGroupInfoView over HomeGroupInfoModel). A group shows its name
// (editable), its members with Remove, Add People…, the Chiefs Reply row, Hide Alerts and Leave
// Group…; a DM shows the person and Hide Alerts. Each control runs one GroupInfoActions call; a
// refusal stays in the status line, and a `not_reachable` one offers Invite by Email…. The sheet
// follows newer reads of the conversation (`info`): an unedited name follows the owner's.
// Done (⎋) closes it; Return renames from the name field, or adds the chosen people.
import { useEffect, useMemo, useRef, useState } from "react";
import type { Strings } from "../../shared/i18n";
import { DialogButton } from "../../../ui/DialogButton";
import { Select } from "../../../ui/Select";
import { Switch } from "../../../ui/Switch";
import { VirtualList } from "../../../ui/VirtualList";
import { Avatar } from "../../home-channels/Avatar";
import { FormDialog } from "../../home-channels/FormDialog";
import type { GroupInfoActions } from "./actions";
import {
  CHIEF_REPLY_POLICIES,
  canAddPeople,
  canRenameGroup,
  contactSourceLabel,
  groupMessage,
  groupSucceeded,
  memberTags,
  membersHeader,
  type ChiefReplyPolicy,
  type GroupInfo,
  type GroupMember,
  type GroupOutcome,
} from "./model";
import type { HomeContact } from "./recipients";
import "./sheets.css";

const MEMBER_ROW = 32;
const CONTACT_ROW = 28;

export interface GroupInfoSheetProps {
  strings: Strings;
  /** The conversation as the app last read it. */
  info: GroupInfo;
  /** The people the user may add (contacts not in it). */
  addable: readonly HomeContact[];
  actions: GroupInfoActions;
  /** The sheet closed (Done, Escape, Leave Group…, Invite by Email…). */
  onClose(): void;
  /** Open with Add People showing (the gallery). */
  initialAdding?: boolean;
}

const fold = (text: string) => text.normalize("NFD").replace(/\p{M}/gu, "").toLocaleLowerCase();

export function GroupInfoSheet({ strings, info, addable, actions, onClose, initialAdding }: GroupInfoSheetProps) {
  const { t } = strings;
  const [nameDraft, setNameDraft] = useState(info.title);
  const [status, setStatus] = useState<string | null>(null);
  const [offersInvite, setOffersInvite] = useState(false);
  const [running, setRunning] = useState(false);
  const [adding, setAdding] = useState(initialAdding === true);
  const [search, setSearch] = useState("");
  const [chosen, setChosen] = useState<string[]>([]);
  const live = useRef(true);
  const searchField = useRef<HTMLInputElement | null>(null);
  // Add People opens with the search field focused.
  useEffect(() => {
    if (adding) searchField.current?.focus();
  }, [adding]);
  useEffect(() => {
    live.current = true;
    return () => {
      live.current = false;
    };
  }, []);
  // A newer read: an unedited name follows it; chosen people no longer addable drop out.
  const lastTitle = useRef(info.title);
  useEffect(() => {
    setNameDraft((draft) => (draft === lastTitle.current ? info.title : draft));
    lastTitle.current = info.title;
  }, [info.title]);
  useEffect(() => {
    setChosen((before) => before.filter((id) => addable.some((contact) => contact.id === id)));
  }, [addable]);

  const show = (outcome: GroupOutcome) => {
    setStatus(groupMessage(outcome, strings));
    setOffersInvite(outcome.kind === "notReachable");
  };
  const run = (action: () => Promise<GroupOutcome>, after?: (outcome: GroupOutcome) => void) => {
    if (running) return;
    setRunning(true);
    setStatus(null);
    setOffersInvite(false);
    void action().then((outcome) => {
      if (!live.current) return;
      setRunning(false);
      after?.(outcome);
      show(outcome);
    });
  };

  const renamable = canRenameGroup(info);
  const addPeople = canAddPeople(info);
  const canRename = !running && nameDraft.trim() !== info.title;
  const rename = () => {
    if (canRename) run(() => actions.rename(nameDraft));
  };
  const addChosen = () => {
    if (chosen.length === 0 || running) return;
    const people = chosen;
    const names = addable
      .filter((contact) => people.includes(contact.id))
      .map((contact) => contact.name)
      .join(", ");
    run(
      () => actions.add(people, names),
      (outcome) => {
        if (!groupSucceeded(outcome)) return;
        setChosen([]);
        setAdding(false);
        setSearch("");
      },
    );
  };
  const setReplies = (policy: ChiefReplyPolicy) => {
    if (policy !== info.chiefReplies) run(() => actions.setChiefReplies(policy));
  };
  const leave = () => {
    onClose();
    actions.leave();
  };
  const inviteByEmail = () => {
    onClose();
    actions.inviteByEmail();
  };
  const shownAddable = useMemo(() => {
    const query = fold(search.trim());
    return query ? addable.filter((contact) => fold(contact.name).includes(query)) : addable;
  }, [addable, search]);
  // Remove: another member of a group (a person I shared my Chief with) while no action runs.
  const removable = (member: GroupMember) => (renamable || (addPeople && !member.isAgent)) && !member.isMe && !running;

  return (
    <FormDialog
      title={t(info.isGroup ? "home.info.title.group" : "home.info.title.direct")}
      onClose={onClose}
      onSubmit={() => (adding && chosen.length > 0 ? addChosen() : rename())}
      busy={running}
      actions={
        <>
          {info.isGroup && (
            <DialogButton
              dialogKey={null}
              className="hc-text-button danger hm-sheet-leading"
              data-testid="cmux.home.groupInfo.leave"
              onClick={leave}
            >
              {t("home.info.leave")}
            </DialogButton>
          )}
          <DialogButton
            dialogKey="escape"
            className="hc-text-button"
            data-testid="cmux.home.groupInfo.done"
            onClick={onClose}
          >
            {t("home.info.done")}
          </DialogButton>
        </>
      }
    >
      <div className="hm-sheet" data-testid="cmux.home.groupInfo">
        {renamable ? (
          <div className="hm-sheet-row">
            <input
              className="hc-link-field"
              value={nameDraft}
              placeholder={t("home.info.name")}
              aria-label={t("home.info.name")}
              data-testid="cmux.home.groupInfo.name"
              onChange={(event) => setNameDraft(event.target.value)}
            />
            <DialogButton
              dialogKey={null}
              className="hc-text-button"
              disabled={!canRename}
              data-testid="cmux.home.groupInfo.rename"
              onClick={rename}
            >
              {t("home.info.rename")}
            </DialogButton>
          </div>
        ) : (
          <p className="hm-sheet-title">{info.displayTitle}</p>
        )}
        <div className="hm-sheet-field">
          <span className="hm-sheet-caption">{membersHeader(info, strings)}</span>
          <VirtualList
            className="hm-members"
            // oxlint-disable-next-line jsx-a11y/prefer-tag-over-role -- the windowed list draws its own rows.
            role="list"
            label={membersHeader(info, strings)}
            count={info.members.length}
            estimateSize={() => MEMBER_ROW}
            renderRow={(index, style) => {
              const member = info.members[index]!;
              return (
                // oxlint-disable-next-line jsx-a11y/prefer-tag-over-role -- a row of the windowed list above.
                <div key={member.id} role="listitem" className="hm-member" style={style}>
                  <Avatar
                    participant={{
                      id: member.id,
                      name: member.name || "?",
                      kind: member.isAgent ? "agent" : "human",
                      chief: false,
                    }}
                    size={24}
                  />
                  <span className="hm-member-name">{member.name || t("home.list.untitled")}</span>
                  {memberTags(member, strings).map((tag) => (
                    <span key={tag} className="hm-sheet-tag">
                      {tag}
                    </span>
                  ))}
                  {removable(member) && (
                    <DialogButton
                      dialogKey={null}
                      className="hm-member-remove"
                      data-testid={`cmux.home.groupInfo.remove.${member.id}`}
                      onClick={() => run(() => actions.remove(member.id))}
                    >
                      {t("home.info.remove")}
                    </DialogButton>
                  )}
                </div>
              );
            }}
          />
        </div>
        {addPeople &&
          (adding ? (
            <div className="hm-sheet-field">
              <input
                className="hc-link-field"
                type="search"
                ref={searchField}
                value={search}
                placeholder={t("home.info.addSearch")}
                aria-label={t("home.info.addSearch")}
                data-testid="cmux.home.groupInfo.search"
                onChange={(event) => setSearch(event.target.value)}
              />
              {addable.length === 0 ? (
                <p className="hm-sheet-caption">{t("home.info.noOneToAdd")}</p>
              ) : (
                <VirtualList
                  className="hm-addable"
                  // oxlint-disable-next-line jsx-a11y/prefer-tag-over-role -- the windowed list draws its own rows.
                  role="list"
                  label={t("home.info.addSearch")}
                  count={shownAddable.length}
                  estimateSize={() => CONTACT_ROW}
                  renderRow={(index, style) => {
                    const contact = shownAddable[index]!;
                    const isChosen = chosen.includes(contact.id);
                    return (
                      // oxlint-disable-next-line jsx-a11y/prefer-tag-over-role -- a row of the windowed list above.
                      <label key={contact.id} role="listitem" className="hm-addable-row" style={style}>
                        <input
                          type="checkbox"
                          aria-label={contact.name}
                          checked={isChosen}
                          data-testid={`cmux.home.groupInfo.add.${contact.id}`}
                          onChange={() =>
                            setChosen((before) =>
                              before.includes(contact.id)
                                ? before.filter((id) => id !== contact.id)
                                : [...before, contact.id],
                            )
                          }
                        />
                        <span className={isChosen ? "hm-member-name chosen" : "hm-member-name"}>{contact.name}</span>
                        <span className="hm-sheet-caption">{contactSourceLabel(contact, strings)}</span>
                      </label>
                    );
                  }}
                />
              )}
              <div className="hm-sheet-row end">
                <DialogButton dialogKey={null} className="hc-text-button" onClick={() => setAdding(false)}>
                  {t("home.compose.cancel")}
                </DialogButton>
                <DialogButton
                  dialogKey={null}
                  className="hc-text-button"
                  disabled={chosen.length === 0 || running}
                  data-testid="cmux.home.groupInfo.addChosen"
                  onClick={addChosen}
                >
                  {t("home.info.add")}
                </DialogButton>
              </div>
            </div>
          ) : (
            <DialogButton
              dialogKey={null}
              className="hc-text-button hm-sheet-start"
              disabled={running}
              data-testid="cmux.home.groupInfo.addPeople"
              onClick={() => setAdding(true)}
            >
              {t("home.info.addPeople")}
            </DialogButton>
          ))}
        {info.chiefReplies && (
          <div className="hm-sheet-field">
            <div className="hm-sheet-row">
              <span className="hm-sheet-label">{t("home.groupInfo.chiefReplies")}</span>
              <Select
                value={info.chiefReplies}
                label={t("home.groupInfo.chiefReplies")}
                disabled={running}
                closeOnPick
                options={CHIEF_REPLY_POLICIES.map((policy) => ({
                  value: policy,
                  label: t(`home.groupInfo.chiefReplies.${policy}`),
                }))}
                onChange={(value) => setReplies(value as ChiefReplyPolicy)}
              />
            </div>
            <p className="hm-sheet-caption">{t(`home.groupInfo.chiefReplies.${info.chiefReplies}.detail`)}</p>
          </div>
        )}
        {info.canMute && (
          <label className="hm-sheet-row">
            <span className="hm-sheet-label">{t("home.info.hideAlerts")}</span>
            <Switch
              checked={info.muted}
              data-testid="cmux.home.groupInfo.hideAlerts"
              onCheckedChange={(on) => run(() => actions.setMuted(on))}
            />
          </label>
        )}
        <output className="hm-sheet-status" aria-live="polite" data-testid="cmux.home.groupInfo.status">
          {status ?? ""}
        </output>
        {offersInvite && (
          <DialogButton
            dialogKey={null}
            className="hc-text-button hm-sheet-start"
            data-testid="cmux.home.groupInfo.invite"
            onClick={inviteByEmail}
          >
            {t("home.groupInfo.inviteByEmail")}
          </DialogButton>
        )}
      </div>
    </FormDialog>
  );
}
