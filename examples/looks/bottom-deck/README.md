# Bottom deck

Every bar moves to the bottom edge, near where you type.

| Setting | Moves |
| --- | --- |
| `tabs.barPosition: bottom`, `tabs.barOrder: belowToolbar` | Each pane's tab bar to its bottom, under the address bar |
| `browser.toolbarPosition: bottom` | Browser and Markdown address bars to the bottom |
| `sidebar.spacesPosition: bottom`, `sidebar.spacesVisibility: always` | The sidebar's spaces to its foot, always shown |
| `home.chiefDock.edge: bottom`, `home.chiefPanel.style: composeBar` | The Chief docks along the bottom as a compose bar |
| `layout.dockColumnEdge: bottom`, `layout.frameOrientation: rowMajor` | Columns you dock go to the bottom and run the window's full width |

It changes settings only; `remove` puts each one back as it was.

```sh
cmux setup install github.com/manaflow-ai/cmux/examples/looks/bottom-deck@feat-cmux-next
cmux setup remove manaflow-ai/bottom-deck
```

Or try it as a preview: `cmux customize recipes --open`, then the Bottom deck recipe's Run button.
