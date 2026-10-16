// Tab membership belongs to the desktop layout, alongside the existing split
// tree. Terminal processes remain owned by the runtime when their tab is hidden.
export class PaneTabGroups {
  constructor(storage) {
    this.storage = storage;
    try {
      const saved = JSON.parse(storage.getItem('cmux.paneTabGroups') || '[]');
      this.groups = Array.isArray(saved) ? saved.filter(group => typeof group.workspaceId === 'string' && Array.isArray(group.members) && group.members.every(id => typeof id === 'string')) : [];
    } catch { this.groups = []; }
  }
  save() { this.storage.setItem('cmux.paneTabGroups', JSON.stringify(this.groups)); }
  groupFor(panelId) { return this.groups.find(group => group.members.includes(panelId)); }
  add(workspaceId, anchorId, panelId) {
    let group = this.groupFor(anchorId);
    if (!group) {
      group = {workspaceId, members:[anchorId], active:anchorId};
      this.groups.push(group);
    }
    if (!group.members.includes(panelId)) group.members.push(panelId);
    group.active = panelId;
    this.save();
  }
  visiblePanels(workspace) {
    if (!workspace) return [];
    let changed = false;
    const live = new Set(workspace.panels.map(panel => panel.id));
    for (const group of this.groups.filter(group => group.workspaceId === workspace.id)) {
      const members = group.members.filter(id => live.has(id));
      if (members.length !== group.members.length) { group.members = members; changed = true; }
      const active = members.includes(workspace.activePanelId) ? workspace.activePanelId : members.includes(group.active) ? group.active : members[0];
      if (group.active !== active) { group.active = active; changed = true; }
    }
    if (changed) {
      this.groups = this.groups.filter(group => group.members.length > 0);
      this.save();
    }
    return workspace.panels.filter(panel => {
      const group = this.groupFor(panel.id);
      return !group || group.active === panel.id;
    });
  }
  members(workspace, panelId) {
    const group = this.groupFor(panelId);
    return group ? group.members.map(id => workspace.panels.find(panel => panel.id === id)).filter(Boolean) : workspace.panels.filter(panel => panel.id === panelId);
  }
  replacementForRemoval(panelId) {
    const group = this.groupFor(panelId);
    if (!group) return null;
    group.members = group.members.filter(id => id !== panelId);
    if (group.active === panelId) group.active = group.members[0];
    this.groups = this.groups.filter(group => group.members.length > 0);
    this.save();
    return group.active || null;
  }
  remapTree(tree) {
    if (!tree) return tree;
    if (tree.type === 'pane') {
      const group = this.groupFor(tree.panelId);
      return group?.active ? {...tree, panelId:group.active} : tree;
    }
    return {...tree, first:this.remapTree(tree.first), second:this.remapTree(tree.second)};
  }
}

export function replaceTreePanel(tree, fromId, toId) {
  if (!tree) return tree;
  if (tree.type === 'pane') return tree.panelId === fromId ? {...tree, panelId:toId} : tree;
  return {...tree, first:replaceTreePanel(tree.first,fromId,toId), second:replaceTreePanel(tree.second,fromId,toId)};
}
