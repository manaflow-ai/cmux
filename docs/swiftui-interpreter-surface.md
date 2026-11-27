# Runtime SwiftUI Interpreter: Capability Surface & Roadmap

## 1. Framing: what a tree-walker can reach

The interpreter is a swift-syntax tree-walker that lowers a `.swift` sidebar file into a `RenderNode` IR bridged to native SwiftUI. There is no compiler, no toolchain, and no type checker. The type system is *erased*: correctness is not verified, values carry runtime tags, and dispatch is by tag. This is the decisive simplification. Almost everything SwiftUI exposes is a pure value transform over a child view, and a tree-walker renders pure value transforms natively. What it cannot reach is anything that requires (a) state that survives between renders, (b) a closure re-invoked by the host at a moment the walker did not produce, or (c) child-to-parent value flow.

Four architectural unlocks gate roughly 90% of the remaining surface. They are independent and should land in this order:

1. **A mutable `@State` / `$binding` engine.** Today `evaluate()` rebuilds a fresh read-only `Environment` every call, `Environment` has only `define`/`lookup` with no write-back, and `ButtonAction` is a frozen `[ActionCommand]` of `cmux`/`log`/`openURL`. Replace this with a host-owned mutable state bag keyed by `@State` declaration site (stable across re-walks), a `$value` binding handle (a get/set pair carried as a new `SwiftValue`/`RenderNode` field), and an action executor that runs assignments (`=`, `+=`, `.toggle()`, `.append`) against the bag and schedules a re-walk. This converts the renderer from one-shot to interactive and unblocks every input control.

2. **User struct/enum/custom-View interpretation.** Register `struct`/`enum`/`extension` declarations into a per-type method/computed-property/operator table; add tagged values (`.object(typeName,fields)`, `.enumCase`, `.optional`, `.closure`); bind init args by label. Because types are erased, this needs rich tagged values and tag-keyed dispatch, not a checker. It unlocks custom `View` structs, `@ViewBuilder`, `switch`, `guard`, optionals, and protocol conformances (Identifiable/Equatable/Comparable).

3. **A generic modifier + style registry.** Replace the flat `ModifierArg.value: String` and the Color-only `fill`/`foregroundStyle` path with a structured `StyleValue` (Color | gradient | Material | hierarchical | shadowed) routed through one `resolveShapeStyle`, plus structured geometry values (`Angle`, `UnitPoint`, `CGPoint/Size/Rect`). One resolver turns the whole surface from flat colors into real styling and feeds gradients, trim, rotation, paths, and `.shadow`/`.border`.

4. **Arbitrary-child modifiers.** Give `RenderModifier` an optional child `RenderNode` subtree plus an alignment, and lower a modifier's trailing closure through the existing `evalItems` path (today a modifier's trailing closure is silently dropped and `.background` takes only a color). This single IR change unlocks `.overlay { }`, `.background { }`, `.mask`, `.safeAreaInset`, and `Section` header/footer.

A fifth, smaller unlock — **deferred (fire-time / render-time) closure evaluation** — is needed for the genuinely host-driven cases: `GeometryReader`, `alignmentGuide`, `TimelineView` author body, gesture value payloads, and drop actions. It stores the unevaluated closure plus a parameter name and re-runs `ExpressionEvaluator` when the host supplies the value.

---

## 2. Capability matrix (deduped, grouped by feasibility tier)

Support legend: ● supported · ◐ partial · ○ missing. Priority: P0 highest.

### Tier: leaf (pure RenderNode/bridge additions, no new runtime)

| Symbol(s) | Support | Pri | Mechanism (one line) |
|---|---|---|---|
| `Text(_:)` | ● | P0 | Shipped: `.text` node; string/interpolation flow through `displayString`. |
| `Text` + LocalizedStringKey markdown / `Text(verbatim:)` | ○/◐ | P0/P1 | Add `isMarkdownLiteral` Bool; literal-no-interpolation → `Text(LocalizedStringKey)`, else `Text(verbatim:)`. |
| Text concatenation `+` | ○ | P0 | Detect `InfixOperatorExpr "+"` over two `.text` nodes → new `.textRun` kind folding `Text + Text` per-run. |
| `.font` / `.fontWeight` / `.bold` / `.italic` | ◐/●/◐/○ | P0 | Broaden `resolveFont`/`dslFontWeight` token tables; add `italic`, bool-arg forms read from `firstValue`. |
| `.monospaced` / `.monospacedDigit` | ◐ | P0 | Add standalone `apply` cases mapping to the `Text` methods. |
| `.lineLimit` (Int/nil/range/reservesSpace) | ◐ | P0 | Parse range tokens + labeled `reservesSpace` from existing `ModifierArg`. |
| `.truncationMode` / `.multilineTextAlignment` / `.textCase` | ○ | P1 | Token → enum in bridge. |
| `.strikethrough` / `.underline` (active/pattern/color) | ◐ | P1 | Read bool + `color` via `dslColor`; conditional apply. |
| `.tracking` / `.kerning` / `.baselineOffset` | ○ | P1/P2 | Double `firstValue` → Text method. |
| `.fontDesign` / `.fontWidth` | ○ | P1 | Token → `Font.Design` / `Font.Width`. |
| `.dynamicTypeSize` (token/range) | ○ | P2 | Token or range → `DynamicTypeSize`. |
| `Text(_:format:)` / `.formatted` (byteCount, etc.) | ◐ | P1 | Add format styles to evaluator; render to static verbatim string. |
| `Label(_:systemImage:)` / `.labelStyle` | ○ | P0/P1 | Dedicated `.label` kind (title text + icon image); `labelStyle` token switches child. |
| `VStack`/`HStack`/`ZStack(alignment:spacing:)` | ◐ | P0 | Thread the dropped alignment arg into the node; add per-axis alignment resolvers. |
| `Spacer(minLength:)` / `Divider` | ●/● | P0 | Wire `minLength:` label into `node.spacing`; Divider context-sensitive (rule vs menu separator). |
| `.padding(edges,length)` / `EdgeInsets` | ◐ | P0 | Parse leading edge-set token + optional Double → `padding(Edge.Set, CGFloat)`. |
| `.frame(...idealWidth:idealHeight:)` | ◐ | P0 | Add ideal dims to the labeled-arg dispatch `applyFrame` already uses. |
| `LazyVStack`/`LazyHStack(alignment:spacing:pinnedViews:)` | ○ | P0/P1 | New lazy kinds mirroring stacks; `pinnedViews` token set; real `LazyVStack/HStack`. |
| `ScrollView(axes,showsIndicators:)` | ◐ | P0 | Promote passthrough to a real `.scrollView` kind carrying axis set + indicators. |
| `Grid`/`GridRow` + `.gridCellColumns`/`.gridColumnAlignment`/`.gridCellAnchor` | ○ | P1/P2 | New `.grid`/`.gridRow` kinds → real SwiftUI Grid (stacks cannot reproduce column sizing). |
| `LazyVGrid`/`LazyHGrid` + `GridItem` | ○ | P1/P2 | New kind + **typed `[GridItem]` payload channel** (.fixed/.flexible/.adaptive). |
| `ViewThatFits(in:)` | ○ | P1 | New kind whose children are alternatives; SwiftUI picks the fit. |
| `.layoutPriority` / `.fixedSize` / `.clipped` / `.compositingGroup` | ○ | P1 | Scalar/bool/no-arg `apply` cases. |
| `Group` / `EmptyView` | ○ | P1/P2 | Group flattens into parent via existing multi-node splice; EmptyView is a no-op node. |
| `List` / `List(data,id:)` | ○ | P0 | New `.list` kind reusing `evalItems`; data form mirrors `evalForEach`. |
| `Section(header:footer:)` / `Section("title")` | ○ | P0 | `.section` kind with header/content/footer child buckets via `evalItems`. |
| `ForEach(data,id:)` / `ForEach(0..<n, id:\.self)` / index+element | ◐ | P0/P1 | Already splices flat siblings; add `id:` keypath parse, 2-arg closure, `.indices`. |
| `if`/`else` as row generators | ● | P0 | `evalIf` already emits 0/1/N sibling rows. |
| `.swipeActions` / `.refreshable` | ○ | P1 | Reuse `ButtonAction` capture; pure command dispatch, host owns data. |
| `.listStyle` / `.listRow*` / `.scroll*` token modifiers | ○ | P1/P2 | Generic token capture → bridge enum map; `scrollContentBackground(.hidden)` is the high-value one. |
| `.tag` / `.id` | ○ | P0/P2 | Intercept in member-access branch; store resolved value on a node field. |
| Shapes: `Ellipse`, `RoundedRectangle(style:)`, `UnevenRoundedRectangle`, `Capsule(style:)`, `ContainerRelativeShape` | ○/◐ | P0–P2 | New/extended shape kinds; pure copies of the `Circle`/`Rectangle` path. |
| `.fill(_:style:)` / `.stroke` / `.strokeBorder` / `.trim` | ◐/○ | P0/P1 | **StyleValue payload** + `StrokeStyle` parse; shape-level pipeline (trim before stroke), insettability flag. |
| `LinearGradient` / `RadialGradient` / `AngularGradient` / `Color.gradient` | ○ | P0–P2 | New gradient cases in StyleValue; `UnitPoint`/`Angle`/Color-array resolution. |
| Material (`.regularMaterial`/`.bar`/…) | ○ | P1 | Token → Material case in StyleValue. |
| Hierarchical styles (`.secondary`/`.tertiary`/…) + multi-arg `foregroundStyle` | ◐ | P0/P1 | StyleValue hierarchical cases; read up to 3 positional args. |
| `.clipShape(_:style:)` / `.cornerRadius` | ◐/● | P0 | Generalize the rounded-rect clip to a `ShapeSpec` modifier arg; Kind→Shape builder. |
| `.border` / `.shadow(color:radius:x:y:)` / `.blur` | ○ | P0/P1 | Labeled scalar+color args → direct view modifier. |
| `.brightness`/`.contrast`/`.saturation`/`.grayscale`/`.hueRotation`/`.blendMode` | ○ | P2 | Single-double / token filters; `hueRotation` shares the Angle resolver. |
| `.aspectRatio` / `.rotationEffect` / `.scaleEffect` / `.offset` / `.position` / `.zIndex` / `.rotation3DEffect` | ○ | P1/P2 | Direct transforms; rotation needs Angle (`.degrees`/`.radians`) value. |
| `Angle`/`UnitPoint`/`CGPoint`/`CGSize`/`CGRect` literals | ○ | P0 | Structured `SwiftValue` cases via existing member-access/call paths. Substrate for gradients, transforms, paths. |
| Image: `.resizable`, `.renderingMode`, `.interpolation`, `.antialiased`, `capInsets` | ○ | P0–P2 | **ImageConfig bucket** consumed on the concrete `Image` *before* AnyView erasure (today erasure no-ops these). |
| `.scaledToFit`/`.scaledToFill`/`.aspectRatio` on images | ○ | P0/P1 | Generic-chain sugar for `aspectRatio(contentMode:)`. |
| `.symbolRenderingMode`/`.symbolVariant`/`.imageScale`/`.symbolEffect(isActive:)`/`.symbolEffectsRemoved` | ○ | P1/P2 | Token-mapped generic modifiers; SF Symbol variants already ride the interpreted `systemName` string. |
| Color labeled inits / named statics / `Color("name")` (host resolver) | ◐ | P0 | Extend `colorValue` for colorspace + opacity + asset name; widen `dslColor` palette. |
| `.opacity` (view) / `.opacity` (style transform) | ●/◐ | P0 | View form works; style form needs `StyleValue.opacityWrapped`. |
| `.foregroundColor`/`.foregroundStyle` generalized | ◐ | P0 | Route through `resolveShapeStyle`; accept gradients/Material/hierarchical. |
| `.tint` (real, inherited) | ◐ | P0 | Stop folding tint into `foregroundStyle`; emit real `.tint` so SwiftUI propagates. |
| `.background(_:in:)`/`.background { }`/`.overlay { }`/`.mask`/`.safeAreaInset` | ◐/○ | P0/P1 | **Arbitrary-child modifier** seam + StyleValue + `ShapeSpec`. |
| `.preferredColorScheme` / `.environment(\.key,_)` (write) | ○ | P2 | Emit real SwiftUI modifier; SwiftUI propagates down the subtree. |
| Menus: `Menu` (title/label/nested), `.contextMenu`, `Section`, `ControlGroup`, `.menuStyle` | ○ | P0–P2 | New kinds whose children come from `evalItems`; `contextMenu` needs trailing-closure capture (like `onTapGesture`). |
| `.keyboardShortcut` / `KeyEquivalent` / `EventModifiers` / `.help` / `.disabled` | ○/◐ | P0/P1 | Args already captured generically; only bridge `apply` cases (char/`.member` tokens, OptionSet). |
| `Button(role:)` / `Button(action:label:)` | ○/● | P0 | Label closure already lowers to children; add `role:` labeled-arg field. |
| `LabeledContent` | ○ | P2 | Read-only row; string or trailing-content child via `evalItems`. |
| `toolbar` / `ToolbarItem(placement:)` / `navigationTitle` | ○ | P1 | Static structural kinds + pass-through string/token modifiers; buttons reuse `ButtonAction`. |
| `.draggable(_:)` (static payload) | ○ | P1 | Static string payload → `.draggable`; no closure body. |
| `.contentShape` / `.onTapGesture(count:)` / `.onLongPressGesture` | ◐/◐/○ | P0 | Shape token; second tap-action field; long-press reuses static `ButtonAction`. |
| `.accessibilityLabel` / `.accessibilityHidden` | ○ | P2 | String/bool args → modifier. |
| `.presentationDetents` / `.presentationDragIndicator` | ○ | P2 | Token pass-through honored inside a sheet. |
| `enumerated()` / `dropFirst`/`suffix`/`dropLast` / richer literals & conversions (`Double()`/`Int()`/`String(format:)`/`min`/`max`/`abs`) | ○/◐ | P1/P2 | Pure value-method additions to `evalMethod`; no runtime. |

### Tier: stateEngine (needs the mutable state bag + binding + action executor + re-walk)

| Symbol(s) | Support | Pri | Mechanism |
|---|---|---|---|
| Re-walk on state change | ○ | P0 | Host-owned observable `StateBag` keyed by `@State` site; writes mark dirty and re-run `evaluate()`. **The gate for this whole tier.** |
| `@State` / `$value` (projection) / `Binding(get:set:)` / `@Binding` param | ◐/○ | P0/P1 | Seed bag once; `$name` → binding handle (get/set path); bridge → real `Binding<T>`. |
| Assignment & compound mutation (`=`,`+=`,`.toggle()`,`.append`) | ○ | P0 | Replace `parseAction` 3-case matcher with a statement executor that writes the bag + re-walks. |
| `TextField` / `SecureField` / `TextEditor` | ○ | P0/P1 | Leaf kinds consuming a string binding. |
| `Toggle` / `Slider` | ○ | P0 | Bool/Double binding; rich-label children reuse Button pattern; range already in `SwiftValue`. |
| `Picker` + selection matching against `.tag` | ○ | P0 | Selection binding; options from static rows or `ForEach`; match value against captured tags. |
| `Stepper` (onIncrement/onDecrement) | ○ | P1 | Value form is leaf; action form needs the statement executor. |
| `.onSubmit` / `.onChange(of:)` | ○ | P1 | Closure capture + statement executor; `onChange` diffs values across re-walks. |
| `DatePicker` / `ColorPicker` | ○ | P2 | Binding engine + `SwiftValue.date` (or hex-string) case. |
| `ForEach($collection)` (element binding) | ○ | P1 | Synthesize per-index get/set; `$item.field` composes a deeper keypath setter. |
| `List(selection:)` of `NavigationLink` | ◐ | P0 | Selection cell + route push + lazy detail share one bag. |
| `Form` | ○ | P2 | Styled List; input value depends on binding engine. |
| `withAnimation` / `.animation(_:value:)` / `.transition` / `.contentTransition` / `.symbolEffect(value:)` | ○ | P0/P1 | Modifier/action wiring is small; inert until a watched value actually changes between renders. Transition also needs stable identity diffing. |
| `matchedGeometryEffect` / `@Namespace` | ○ | P1 | Host-owned stable `Namespace.ID` surviving re-renders + state-driven branch swap. |
| `TimelineView` (author body) / `.phaseAnimator` | ◐/○ | P0/P1 | Re-evaluable body thunk + host driver re-binds `ctx`/phase each tick (deferred-closure seam). |
| `.onAppear`/`.onDisappear` as drivers / `.onChange` as driver / `.transaction` | ○ | P1/P2 | Capture closure; fire on hook; bodies mutate `@State` via the action path. |
| Gestures: `.onHover`, `DragGesture(onChanged/onEnded)`, `.gesture`/`.simultaneous`/`.highPriority`, drop highlight, `.focusable` action, gesture `.value` exposure | ○ | P0–P2 | Deferred fire-time action (store unevaluated arg exprs + callback scope); live-appearance forms additionally need `@State`. |
| `.dropDestination(for:action:)` | ○ | P1 | Deferred action re-evaluated with dropped-ids/location at drop time. |
| Menus: `Toggle`/`Picker` in menus, `contextMenu(forSelectionType:)` | ○ | P1/P2 | Two-way binding + `.tag` matching. |
| Navigation: `NavigationStack(path:)`, `NavigationLink(value:/destination:)`, `navigationDestination`, `NavigationSplitView`, `dismiss`, `TabView(selection:)` | ○ | P0/P1 | Internal `navigate.push/pop/present/dismiss` command family resolved against host path/selection cells; destination closures evaluated lazily. |
| Presentation: `sheet(isPresented:/item:)`, `popover`, `fullScreenCover`, `alert`, `confirmationDialog` | ○ | P0–P2 | `$isPresented`/`$item` cell + lazily-walked content closure; dismiss flips the cell. |
| `class` / `mutating func` / `@Bindable` | ○ | P2 | Reference-identity cells in the bag; mutation visible through aliases. |
| `let`/`var` reassignment, while/repeat loops, custom operator `+=` write-back | ◐/○ | P0–P2 | Reassignment needs mutable scope cells; loops need a bounded cap + control-flow signal. |

### Tier: typeSystem (needs declaration registry + tagged values + control-flow signal)

| Symbol(s) | Support | Pri | Mechanism |
|---|---|---|---|
| `struct` definition + memberwise init | ○ | P0 | Register `StructDeclSyntax`; tag `.object(typeName,fields)`; synthesize label-matched init. |
| custom `View` struct + `var body: some View` | ○ | P0 | Bind init args by label into scope + self; `evalItems(body)`. |
| `@ViewBuilder` (param + func) | ○ | P0 | Store as `.closure(params,body,capturedScope)`; expand `content` later via `evalItems`. |
| `enum` (raw + associated values) | ○ | P0 | `.enumCase(typeName,case,payload)`; `.rawValue`/`init?(rawValue:)`. |
| `switch`/`case` (+where, value/enum/tuple/range patterns, let-binding) | ○ | P0 | Pattern matcher in `evalItems` (view) and `evalBlockValue` (value); bind let names in child scope. |
| `if let` / `guard let` / `?.` / `??` | ○ | P0 | `SwiftValue.optional`; `evalIf` reads `OptionalBindingCondition`; member/subscript propagate `nil`. |
| `guard` statement | ○ | P0 | Control-flow signal: else block must emit `.return/.break/.continue`. |
| computed property `var x: T { ... }` | ○ | P0/P1 | Detect getter accessor; evaluate block with self-members bound. |
| `@ViewBuilder` helper func + labels/defaults/variadics/tuple-return | ◐ | P0/P1 | Core path exists; add label-matched binding, defaults, tuple returns. |
| `extension` (methods/computed props on existing/built-in type) | ○ | P1 | Merge members into the per-type table; dispatch by runtime tag/kind. |
| protocols (Identifiable/Equatable/Comparable/Hashable) | ○ | P1 | Identity by `.id` member; `==` structural; `<` routes to declared `static func <`. |
| generics (erased) | ○ | P1 | Parse and ignore constraints; a generic container is a struct with a closure field. |
| `break`/`continue`/`return` | ◐ | P1 | Replace bare-value block evaluator with a `ControlFlow` signal enum. The keystone refactor for guard/loops/early-return. |
| `do`/`try`/`catch` + throwing funcs / `try?` | ○ | P2 | `.throw(value)` signal unwinds to nearest `do/catch`; `try?` → `.optional(nil)`. |
| `KeyPath` literal `\.member` | ○ | P0 | `.keyPath([String])`; powers `id:`, `sorted(by:)`, `map(\.x)`, grouping. |
| `@Observable` model + `@State` ownership / static members | ○ | P1/P2 | Register class def; seed mutable `.object`; `$m.field` projects a binding keypath. |
| `Dictionary(grouping:by:)` / collection derivations (`min`/`max(by:)`/`allSatisfy`/keyPath-`sorted`) | ◐ | P1 | Extend `evalMethod`; accept KeyPath projection. |
| `AsyncImage(content:placeholder:)` (closure) / `Label(title:icon:)` (closure) | ○ | P1 | Evaluate `@ViewBuilder` closure *args* into subtrees; bind the single `Image` param. |
| `AsyncImage` (phase form) | ○ | P2 | Needs `switch` over phase enum + associated-value binding. |
| `@Environment(\.key)` reads / `.environment` write-back-to-author | ○ | P1/P2 | Parse property-wrapper var decl; seed read-only allowlist from host. |

### Tier: runtimeLimited (works only because the host/SwiftUI owns the capability)

| Symbol(s) | Support | Pri | Mechanism |
|---|---|---|---|
| `Image("name")` / `Image(decorative:)` (asset catalog) | ○ | P1/P2 | Host-injected `(String)→PlatformImage?` resolver; placeholder on miss. |
| `AsyncImage(url:)` (load lifecycle) | ○ | P1 | Lowering is leaf; SwiftUI owns async networking. |
| `@FocusState` + `.focused` | ○ | P2 | Bridge `RenderNodeView` owns the real `@FocusState` and two-way syncs to a bag cell; the walker cannot own keyboard focus. |
| `alignmentGuide(computeValue:)` | ○ | P2 | Deferred closure re-invoked per layout against host `ViewDimensions`; needs callable `SwiftValue`. |
| `GeometryReader` / `.coordinateSpace` | ○ | P2 | Deferred 1-arg closure re-invoked per layout with a host `GeometryProxy`. Highest-value deferred primitive. |
| `Text(_:style:)` / `Text(timerInterval:)` (self-updating) | ○ | P1/P2 | `SwiftValue.date` + payload; SwiftUI self-animates from the runloop (no `@State`). |
| `.scrollPosition(id:)` / `ScrollViewReader.scrollTo` | ○ | P2 | Needs `$binding` + a proxy object; only a host-pushed scroll-to-id intent is feasible without it. |

### Tier: infeasible (cannot be expressed in a single-pass view-only tree-walker)

| Symbol(s) | Why |
|---|---|
| `PreferenceKey` + `.preference` / `onPreferenceChange` | Child-to-parent aggregation with a user `reduce`; contradicts one-pass top-down flow and needs protocol conformance. |
| `commands` / `CommandMenu` / `CommandGroup` | Attach to a `Scene`/`WindowGroup`; the interpreted sidebar is a view embedded in the host window with no author-controllable Scene. Route global shortcuts through `KeyboardShortcutSettings`. |
| `Canvas`, `Path { p in … }` builder, custom `struct: Shape` | Need a stateful imperative builder/context object plus (for custom Shape) struct+protocol conformance and a render-time rect; the union of every hard part. (Non-closure `Path(roundedRect:)`/`Path(ellipseIn:)` convenience inits are leaf once `CGRect` exists.) |
| `.keyframeAnimator` general form | Needs a user value struct + `KeyframeTrack(\.keypath)` keypaths. A hardcoded named-track subset (scale/opacity/offset/angle) is `typeSystem`-feasible; `phaseAnimator` covers most needs cheaply. |
| Custom `HorizontalAlignment`/`VerticalAlignment` IDs | Need `extension { static let }` + `AlignmentID` conformance synthesis. |
| Swift Charts, arbitrary `AttributedString` value building | Out of vocabulary; `AttributedString(markdown:)` via a recognized nested-call shape is a leaf, general construction is not. |

---

## 3. Phased roadmap

### Phase 1 — leaf wins (pure IR + bridge, no new runtime)

**Interpreter changes.** Add the structured value substrate to `SwiftValue` (`Angle`, `UnitPoint`, `CGPoint/Size/Rect`, `Date`). Replace `ModifierArg.value: String` with a structured `StyleValue` and add one shared `resolveShapeStyle`. Add a typed payload channel on `RenderNode` for non-string values (`[GridItem]`, axis sets, edge sets). Add the arbitrary-child modifier seam (`RenderModifier.content: [RenderNode]` + `alignment`) and lower modifier trailing closures via `evalItems`. Add an `ImageConfig` bucket consumed on the concrete `Image` before AnyView erasure. Add the new view kinds and thread the already-dropped stack alignment args.

**Unlocks.** Real layout (alignment on every stack, edge-set padding, ideal frame); `List`/`Section`/`LazyVStack`/`LazyHStack`/`ScrollView(axes)`/`Grid`/`LazyVGrid`/`ViewThatFits`/`Group`/`EmptyView`; all text typography (markdown discriminator, `Label`, text concatenation, italic/monospaced/tracking/case/design, line-limit ranges); full styling (gradients, Material, hierarchical styles, `.fill`/`.stroke`/`.strokeBorder`/`.trim`, `.clipShape`/`.clipped`/`.mask`, `.border`/`.shadow`/`.blur`, transforms, `.overlay { }`/`.background { }`/`.safeAreaInset`); image config (`.resizable`/`.scaledToFit`/`.aspectRatio`/`.renderingMode`, SF Symbol expressiveness); menus (`Menu`/`.contextMenu`/`Section`/`ControlGroup`/`.keyboardShortcut`/`.help`/`.disabled`/`Button(role:)`); static `toolbar`/`navigationTitle`; `.draggable` (static), `.onLongPressGesture`, `.contentShape`, tap count; richer value methods (`enumerated`/`dropFirst`/conversions). Self-updating `Text(_:style:)`/`Text(timerInterval:)` land here too (host-driven, no `@State`).

### Phase 2 — state engine (`@State`/`@Binding`/`$` + input controls)

**Interpreter changes.** Lift a host-owned observable `StateBag` (`[siteKey: SwiftValue]`) into the model, seeded once from `@State` decls and surviving re-walks. Add a binding handle (`SwiftValue.binding(get,set)` produced by `$name`/`$obj.field`/`$arr[i]`). Replace `parseAction`'s three-call matcher with a statement executor (`=`,`+=`,`-=`,`.toggle()`,`.append`, multi-statement) that writes the bag and schedules a re-walk; keep `cmux`/`log`/`openURL` as terminal side effects. Add value-diffing across re-walks (for `onChange`) and stable identity stamping on `RenderNode` (for transitions/diffing). Add a deferred fire-time action variant (store unevaluated arg exprs + callback param name) for gesture/drop payloads.

**Unlocks.** `TextField`/`SecureField`/`TextEditor`/`Toggle`/`Picker`(+`.tag`)/`Slider`/`Stepper`/`DatePicker`/`ColorPicker`; `ForEach($collection)`; `.onSubmit`/`.onChange`; `withAnimation`/`.animation(value:)`/`.transition`/`.contentTransition`/`.symbolEffect(value:)`/`matchedGeometryEffect`/`@Namespace`; author-controllable `TimelineView`/`.phaseAnimator`; live gestures (`onHover`, `DragGesture`, drop highlight, gesture `.value`); `.onAppear`/`.onDisappear` drivers. `@FocusState` rides here but stays runtime-limited (bridge owns the real focus state).

### Phase 3 — type-system layer (user types + control flow)

**Interpreter changes.** Add the `ControlFlow` signal enum (`.normal/.return/.break/.continue/.throw`) replacing the bare-value block evaluator — the keystone refactor. Add tagged values (`.object(typeName,fields)`, `.enumCase`, `.optional`, `.closure`, `.keyPath`). Walk `struct`/`enum`/`extension`/computed-property/`@Observable` declarations into a per-type method/computed-prop/operator table dispatched by runtime tag. Synthesize label-matched memberwise inits; bind init args by label. Add `switch`/`guard`/optional-binding handling and `?.`/`??`.

**Unlocks.** User `struct`/`enum`, custom `View` structs + `var body`, `@ViewBuilder` content composition, `switch`/`case`, `guard`, `if let`/`guard let`, optionals/optional-chaining, computed properties, labeled/default/variadic func params, `extension`, protocol conformances (Identifiable/Equatable/Comparable), erased generics, `KeyPath`-driven `id:`/sort/group, `AsyncImage`/`Label` closure forms, `@Environment` reads. `do/try/catch` and the constrained `keyframeAnimator` subset are the tail of this phase.

### Phase 4 — runtime-limited (navigation / presentation / async / deferred-layout)

**Interpreter changes.** Add an internal navigation-command family (`navigate.push/pop/present/dismiss`) the host resolves against path/selection/presentation cells (distinct from host-opaque `cmux()`), plus an interaction-driven re-walk that lazily evaluates destination/sheet/popover/tab bodies only when presented, binding the route/item into a child scope. Add the deferred render-time closure seam: a callable `SwiftValue` the bridge re-invokes inside `GeometryReader`/`alignmentGuide` with host-provided `GeometryProxy`/`ViewDimensions`. Add the host asset resolver and let SwiftUI own async image loading.

**Unlocks.** `NavigationStack`/`NavigationLink`/`navigationDestination`/`NavigationSplitView`/`dismiss`/`TabView`; `sheet`/`popover`/`fullScreenCover`/`alert`/`confirmationDialog`; `GeometryReader`/`alignmentGuide`/`.coordinateSpace`; `Image("name")` asset catalog; `AsyncImage(url:)`; `.scrollPosition`/`ScrollViewReader` (host-pushed intent form).

---

## 4. Honest hard limits

A tree-walking interpreter over an erased type system reaches the entire *declarative* surface of SwiftUI: any view, modifier, style, layout, control, navigation, and animation that is ultimately a value transform the host can render or re-render. With the four unlocks it can interpret essentially any *idiomatic* SwiftUI sidebar. The boundary is structural, not a matter of effort:

- **No Scene-level surface.** `commands`/`CommandMenu`/`WindowGroup` attach to a Scene the author does not own. Permanently out of scope; route to host settings.
- **No child-to-parent value flow.** `PreferenceKey`/`onPreferenceChange` need a two-pass collect-reduce-deliver with a user `reduce`; the walk is one-pass top-down. Infeasible without a fundamentally different engine.
- **No imperative drawing builders.** `Canvas` and `Path { p in … }` need a stateful mutable builder/context object with a curated imperative method set; custom `struct: Shape` additionally needs protocol conformance plus a render-time rect. These are the union of every hard part and stay out of scope (convenience non-closure shape inits are fine).
- **No true compile-time guarantees.** Types are erased, so there is no type checking, overload resolution by type, exhaustiveness checking, or `KeyPath`/keyframe generality beyond hardcoded tracks. Authors get runtime behavior, not compiler diagnostics.
- **Deferred-layout values are host-borrowed, not interpreted.** `GeometryReader`, `alignmentGuide`, `@FocusState`, and self-updating date/timer text work only because the SwiftUI bridge owns the real proxy/focus/runloop and re-invokes a stored closure or mirrors a cell. The interpreter never *holds* layout geometry, keyboard focus, or a clock; it projects host-supplied values into a re-evaluated closure.
- **No general user-value animation.** `keyframeAnimator`'s general form (user value struct + keypath tracks) and custom alignment IDs need declaration shapes (`extension { static let }`, arbitrary keypaths into user structs) that the language layer cannot synthesize. Constrained named-track subsets are the pragmatic ceiling.

The pragmatic line for "interpret any SwiftUI": **anything expressible as a `View` value (or a transform over one) that the host can render or be asked to re-render is reachable; anything requiring Scene ownership, bottom-up aggregation, a user-defined imperative drawing/animation object, or real compile-time type guarantees is not.**

---

## Completeness Critique & Additions

- **Accessibility (`.accessibilityValue`, `.accessibilityHint`, `.accessibilityAddTraits`, `.accessibilityElement(children:)`, `.accessibilityRepresentation`, `.accessibilitySortPriority`, `.accessibilityActivationPoint`)** — leaf. The spec mentions only `.accessibilityLabel`/`.accessibilityHidden` (P2). The full a11y modifier family is pure value-transform token/string/bool args feeding native modifiers; `accessibilityElement(children:)` and `.accessibilityRepresentation` (closure child) need the arbitrary-child seam but are otherwise leaf. For a sidebar that real users navigate with VoiceOver this is under-prioritized at P2; the label/value/hint/traits core is P1.

- **`.accessibilityAction(named:)` / `accessibilityAction(.default)`** — stateEngine. Custom a11y actions run an author closure, so they need the action executor, not just leaf token mapping. Spec omits a11y actions entirely.

- **`scenePhase` (`@Environment(\.scenePhase)`)** — infeasible (or host-borrowed runtimeLimited at best). The spec covers `@Environment` reads generically (typeSystem, P1/P2) but never calls out scenePhase. It is a Scene-level signal; an embedded sidebar view has no Scene, so active/inactive/background is not author-observable. Belongs explicitly in the infeasible list alongside `commands`/`WindowGroup`, or as a host-pushed read-only allowlisted value if the host chooses to surface it.

- **`@ScaledMetric`** — typeSystem (declaration registry) + runtimeLimited (host owns Dynamic Type scaling). The spec lists `.dynamicTypeSize` (leaf, P2) but not `@ScaledMetric`, which is a property wrapper whose scaled value must be recomputed by the host against the current size category. Needs the property-wrapper var-decl parsing from Phase 3 plus a host-supplied scale factor. Currently unaddressed.

- **Redaction / privacy (`.redacted(reason:)`, `.unredacted`, `.privacySensitive()`, `RedactionReasons`)** — leaf. Pure token-mapped modifiers SwiftUI honors top-down. `.redacted(reason: .placeholder)` is genuinely useful for sidebar loading states and is entirely a value transform. Missing from the matrix; belongs at P1.

- **Coordinate spaces (`.coordinateSpace(name:)` + `.named()` lookups)** — runtimeLimited. The spec mentions `.coordinateSpace` once in passing under GeometryReader (P2) but does not break out the named-coordinate-space registration vs. the proxy conversion. The naming modifier is leaf; resolving a frame in a named space is host-borrowed deferred-layout. Should be split and explicitly tiered.

- **Transferable / typed drag-and-drop (`Transferable` conformance, `.dropDestination(for: MyType.self)`, `.draggable` with a Transferable payload, `.itemProvider`)** — infeasible for the *typed/codable* form; runtimeLimited for the *string-payload* form. The spec covers `.draggable(_:)` static string (leaf) and `.dropDestination(for:action:)` (stateEngine, deferred action), but typed `Transferable` requires synthesizing protocol conformance plus `UTType` registration that the erased type system cannot express. This boundary should be stated, not implied.

- **`UTType` / `ContentType` values** — typeSystem at best, more realistically host-allowlisted. Needed by drag-and-drop, file importers, and `.fileImporter`. The spec never mentions content types; they cannot be synthesized from author code and must be a host-provided named allowlist (`.plainText`, `.url`, etc.). Worth an explicit note.

- **`.fileImporter` / `.fileExporter` / `.fileMover`** — infeasible (or host-mediated runtimeLimited). These present system pickers and hand back security-scoped URLs; the sidebar interpreter has no entitlement-bearing surface. Should be named in the infeasible/host-only set rather than silently absent.

- **Localization beyond markdown (`LocalizedStringKey` interpolation with inflection/`^[..]` automatic grammar agreement, `Text("\(count) item", comment:)`, string catalogs, `.environment(\.locale)`)** — leaf for the discriminator, runtimeLimited for actual catalog lookup. The spec handles the markdown/verbatim discriminator (P0/P1) but says nothing about who owns the localization table. The interpreter cannot hold a `.xcstrings` catalog; lookup is host-borrowed. Inflection/grammar agreement is SwiftUI-owned and rides for free once the key is passed as a real `LocalizedStringKey`. State this ownership split.

- **RTL / layout direction (`.environment(\.layoutDirection)`, `.flipsForRightToLeftLayoutDirection`, leading/trailing semantics)** — leaf. SwiftUI already mirrors leading/trailing automatically, so most of this is free, but `.flipsForRightToLeftLayoutDirection(_:)` and reading `@Environment(\.layoutDirection)` are explicit and currently unlisted. Cheap leaf additions; note that hardcoded `.left`/`.right` alignment defeats RTL and should be discouraged in authored sidebars.

- **Units / measurement & number formatting (`Measurement`, `.formatted(.measurement(...))`, `.number`, `.percent`, `.currency(code:)`, `.list(type:)`, `RelativeDateTimeFormatter`/`.relative`)** — typeSystem (the `FormatStyle` values are tagged values with a `.formatted` method) rendered to a static string (leaf output). The spec lists `.formatted` / `Text(_:format:)` generically (P1) but does not enumerate the format-style surface or note that `Measurement`/units need a tagged `SwiftValue` case. The common money/percent/relative-date styles deserve explicit P1 callouts since sidebars routinely show counts, sizes, and timestamps.

- **`PreferenceKey` — partial host-mediated escape hatch correction.** The spec correctly marks general `PreferenceKey`/`onPreferenceChange` infeasible, but should note the one reachable subset: SwiftUI's *built-in* anchor/preference-backed modifiers that don't require a user `reduce` (e.g. `.navigationTitle` via toolbar, `.matchedGeometryEffect`, `.alignmentGuide`) already work through the host. The hard limit is specifically *author-defined* keys with a custom `reduce`. Tighten the wording so it doesn't read as "no preference mechanism at all."

- **`.containerRelativeFrame(_:)` / container-relative sizing** — leaf. Modern replacement for many GeometryReader uses; pure axis-set + optional count/span/spacing args mapped to the native modifier. Cheaper and higher-value than GeometryReader for sidebar layout, yet absent. Belongs at P1, and the roadmap should prefer it over GeometryReader where possible.

- **`.scrollTargetBehavior` / `.scrollTargetLayout` / `.scrollClipDisabled` / `.scrollBounceBehavior` / `.scrollIndicators(_:)`** — leaf. The spec lumps "`.scroll*` token modifiers" at P1/P2 but these are concrete, individually useful token-mapped modifiers (paging, snap, indicator visibility) that need no runtime. Worth enumerating; `scrollIndicators` and `scrollClipDisabled` are P1.

- **`.onGeometryChange(for:of:action:)` (iOS 18 / macOS 15)** — stateEngine + runtimeLimited. A modern, less-fragile alternative to `GeometryReader` for feeding geometry into `@State`. It needs the deferred host-supplied value plus the action executor to write the bag. The spec's deferred-closure seam covers GeometryReader but not this newer modifier; it is arguably the *preferred* primitive and should be listed.

- **`.visualEffect { content, proxy in ... }`** — runtimeLimited (deferred render-time closure). Same deferred-proxy mechanism as `GeometryReader`/`alignmentGuide`, applies a value-transform to `content` using a `GeometryProxy`. It is the modern idiomatic way to do scroll-driven effects and is entirely within the deferred-closure seam already proposed, yet unlisted. P2.

- **`ScrollView` paging / `TabView(.page)` style** — leaf for the style token; the selection form is correctly stateEngine. The spec lists `TabView(selection:)` (stateEngine) but not the no-selection `.tabViewStyle(.page)` carousel, which is leaf. Minor addition.

- **`Gauge` / `ProgressView(value:total:)`** — leaf for the static/determinate value form, stateEngine only if bound. The spec lists no progress/gauge controls at all. `ProgressView()` (indeterminate) and `ProgressView(value:)` (static Double) are pure leaf nodes SwiftUI animates itself; `Gauge` is leaf with a `StyleValue`-resolved tint. A common sidebar element entirely missing from the matrix; P1.

- **`ControlSize` / `.controlSize(_:)`, `.buttonStyle(_:)`, `.buttonBorderShape`, `.pickerStyle`, `.toggleStyle`, `.textFieldStyle`** — leaf (token) for built-in styles; the *custom* `ButtonStyle`/`ToggleStyle` struct form is typeSystem (needs struct + protocol + the `configuration.label` child) or arguably runtimeLimited. The spec mentions `.labelStyle`/`.menuStyle`/`.listStyle` but is silent on the button/toggle/picker/textfield style modifiers, which are high-frequency. Built-in token forms are P1 leaf; flag the custom-style-struct form as a typeSystem item that needs the `StyleConfiguration` child plumbed through the arbitrary-child seam.

- **`@AppStorage` / `@SceneStorage`** — runtimeLimited (host-owned persistence) layered on the state engine. The spec's `@State` bag is in-memory only. `@AppStorage` is a binding cell whose get/set is backed by host `UserDefaults` (cmux settings); feasible and useful for a persistent sidebar, but needs an explicit host-backed cell distinct from the ephemeral `StateBag`. Currently unaddressed.

- **`mis-tier correction: `withAnimation`/`.transition`** — the spec places these in stateEngine (P0/P1), which is correct, but `.transition(_:)` and `.animation(_:value:)` as *inert modifiers* (no state change yet) are leaf and could ship in Phase 1 so the IR/bridge plumbing exists before the state engine arrives. Worth splitting "plumb the modifier" (leaf, Phase 1) from "make it fire" (stateEngine, Phase 2).

- **`mis-tier correction: `.tag`/`.id`** — listed as leaf (P0/P2), which is right for parsing, but `.id(_:)` forcing identity-based view replacement only has observable effect once re-walks happen (stateEngine). Note the dependency so it isn't assumed fully functional in Phase 1.

- **`Color(nsColor:)` / `Color(uiColor:)` / `Color.accentColor` / system semantic colors (`.primary`, `Color(.systemGray)`)** — leaf, host-mediated for platform/asset colors. The spec widens `dslColor` palette and asset names but doesn't call out platform color bridges or the full semantic-color set (`.primary`/`.secondary` as colors vs. as hierarchical styles is ambiguous in the current spec). Clarify and enumerate; P0/P1.

- **Composition pattern not unlocked: closure-typed view *parameters* on user structs (`init(@ViewBuilder content: () -> Content)` plus `let content: Content` stored and rendered via `content`)** — typeSystem. Phase 3 unlocks `@ViewBuilder` content and custom Views, but the spec doesn't explicitly state that a stored `Content` generic property rendered as `content` (the canonical container-component pattern, e.g. a custom `Card { ... }`) works. This is the single most common reusable-component idiom for a sidebar library; confirm it falls out of `.closure` capture + erased generics, and call it a first-class Phase 3 deliverable.

- **Composition pattern not unlocked: `ViewModifier` structs + `.modifier(_:)` / `.modifier` extension sugar** — typeSystem. Custom `struct: ViewModifier { func body(content:) }` is the idiomatic way authors package reusable modifier chains. It needs struct + protocol conformance + the `content` child (arbitrary-child seam). The roadmap unlocks the seam and custom structs separately but never states that their composition yields user `ViewModifier`s. Should be an explicit Phase 3 deliverable.