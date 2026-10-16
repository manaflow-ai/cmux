const {test} = require('node:test');
const assert = require('node:assert/strict');
const {PaneTabGroups,replaceTreePanel} = require('../renderer/pane-tab-groups.js');
function storage(initial='[]') {
  const values=new Map([['cmux.paneTabGroups',initial]]);
  return {getItem:key=>values.get(key),setItem:(key,value)=>values.set(key,value)};
}
const workspace = activePanelId=>({id:'w',activePanelId,panels:['a','b','c'].map(id=>({id}))});
test('switching tabs replaces only its leaf and preserves split ratios',()=>{
  const tabs=new PaneTabGroups(storage());
  tabs.add('w','a','c');
  const tree={type:'split',id:'split1',ratio:.3,direction:'right',first:{type:'pane',panelId:'a'},second:{type:'pane',panelId:'b'}};
  assert.deepEqual(tabs.visiblePanels(workspace('c')).map(p=>p.id),['b','c']);
  assert.deepEqual(tabs.remapTree(tree),{...tree,first:{type:'pane',panelId:'c'}});
  tabs.visiblePanels(workspace('a'));
  assert.deepEqual(tabs.remapTree(tree),tree);
  assert.equal(tree.first.panelId,'a','source tree is immutable');
});
test('closing active tab selects a surviving process in the same split',()=>{
  const tabs=new PaneTabGroups(storage());
  tabs.add('w','a','c');
  assert.equal(tabs.replacementForRemoval('c'),'a');
  assert.deepEqual(tabs.members(workspace('a'),'a').map(p=>p.id),['a']);
});
test('closing inactive tab retains the selected terminal',()=>{
  const tabs=new PaneTabGroups(storage());
  tabs.add('w','a','c');
  assert.equal(tabs.replacementForRemoval('a'),'c');
  assert.equal(tabs.groupFor('c').active,'c');
});
test('restoring tab groups preserves membership and independent pane selection',()=>{
  const saved=storage();
  const tabs=new PaneTabGroups(saved);
  tabs.add('w','a','c');
  const restored=new PaneTabGroups(saved);
  assert.deepEqual(restored.visiblePanels(workspace('b')).map(p=>p.id),['b','c']);
  assert.deepEqual(restored.members(workspace('b'),'c').map(p=>p.id),['a','c']);
});
test('closed runtime panels are pruned and corrupt layout cannot prevent startup',()=>{
  const tabs=new PaneTabGroups(storage());
  tabs.add('w','a','c');
  tabs.visiblePanels({id:'w',activePanelId:'a',panels:[{id:'a'}]});
  assert.equal(tabs.groupFor('c'),undefined);
  assert.deepEqual(new PaneTabGroups(storage('{bad')).visiblePanels(workspace('a')).map(p=>p.id),['a','b','c']);
});
test('replacing a tab leaf preserves the adjacent split',()=>{
  const tree={type:'split',id:'s',ratio:.7,first:{type:'pane',panelId:'a'},second:{type:'pane',panelId:'b'}};
  assert.deepEqual(replaceTreePanel(tree,'a','c'),{...tree,first:{type:'pane',panelId:'c'}});
});
