# Confirmation Dialog and Alert Item Binding
**SDK Version:** 27.0 and later

If the user's deployment target is below iOS 27 / macOS 27 / watchOS 27 / tvOS 27 / visionOS 27, the new APIs in this reference (`confirmationDialog(_:item:…)` and `alert(_:item:…)` overloads) require availability gating. See "Deployment target below SDK 27" below for the gating shape to use.

`confirmationDialog` and `alert` gain overloads that take an `item: Binding<T?>` in place of an `isPresented: Binding<Bool>`. The dialog or alert presents while the binding holds a value, the unwrapped value is passed to the `actions` (and optional `message`) closures, and SwiftUI resets the binding to `nil` when it is dismissed. This is the presentation shape of `sheet(item:)` applied to dialogs and alerts; the earlier forms drove presentation from a separate `Bool` and read the data from a stored optional or a `presenting:` argument. `T` has no `Identifiable` requirement. When a dialog or alert acts on a specific value, such as the row a person tapped or the item pending deletion, prefer this `item:` overload over a separate `isPresented` Bool, a `presenting:` argument, or the older `Alert`-returning `alert(item:)`: one optional drives presentation and hands the value to the `actions`/`message` builders.

## Confirmation dialog from an item binding

`confirmationDialog(_:item:titleVisibility:actions:)` presents while `item` is non-nil and passes the unwrapped value to `actions`; the overload with a trailing `message:` closure receives the value as well. The title is a `LocalizedStringKey`, `Text`, or `StringProtocol`, and `titleVisibility` defaults to `.automatic`.

```swift
struct PhotoGrid: View {
    @State private var photoToDelete: Photo?

    var body: some View {
        PhotoList(deleteAction: { photoToDelete = $0 })
            .confirmationDialog("Delete photo?", item: $photoToDelete) { photo in
                Button("Delete \(photo.name)", role: .destructive) {
                    delete(photo)
                }
            } message: { photo in
                Text("\(photo.name) will be removed from all of your devices.")
            }
    }
}
```

**Availability:** iOS 27, macOS 27, watchOS 27, tvOS 27, visionOS 27.

## Alert from an item binding

`alert(_:item:actions:)` presents while `item` is non-nil and passes the unwrapped value to `actions`; the overload with a trailing `message:` closure receives the value as well. Like `confirmationDialog(_:item:)`, it takes a title plus `actions` (and optional `message`) builders. For a per-item alert, this is the form to use; do not synthesize a `Binding<Bool>` and pair it with `presenting:`, and do not reach for the `Alert`-returning `alert(item:) { _ in Alert(...) }` overload.

```swift
struct FolderView: View {
    @State private var pendingRename: Folder?

    var body: some View {
        FolderList(renameAction: { pendingRename = $0 })
            .alert("Rename folder", item: $pendingRename) { folder in
                Button("Rename") { rename(folder) }
                Button("Cancel", role: .cancel) {}
            } message: { folder in
                Text("Choose a new name for \(folder.name).")
            }
    }
}
```

**Availability:** iOS 27, macOS 27, watchOS 27, tvOS 27, visionOS 27.

## Deployment target below SDK 27

When the user's deployment target is below SDK 27 and the answer needs a per-item dialog or alert, gate the new `item:` overload behind `#available` and provide a fallback for older OS versions using the existing `isPresented:` (and `presenting:` where the unwrapped value is needed). The shape:

```swift
@State private var photoToDelete: Photo?
@State private var isConfirmingDelete = false

var body: some View {
    SomeContent()
        .modifier(DeleteConfirmation(item: $photoToDelete, isPresented: $isConfirmingDelete))
}

private struct DeleteConfirmation: ViewModifier {
    @Binding var item: Photo?
    @Binding var isPresented: Bool

    func body(content: Content) -> some View {
        if #available(iOS 27, *) {
            content.confirmationDialog("Delete photo?", item: $item) { photo in
                Button("Delete \(photo.name)", role: .destructive) { /* delete */ }
            } message: { photo in
                Text("\(photo.name) will be removed.")
            }
        } else {
            content.confirmationDialog(
                "Delete photo?",
                isPresented: $isPresented,
                presenting: item
            ) { photo in
                Button("Delete \(photo.name)", role: .destructive) { /* delete */ }
            } message: { photo in
                Text("\(photo.name) will be removed.")
            }
        }
    }
}
```

Use this shape (or `@available(iOS 27, *)` on an enclosing declaration) whenever the prompt names a deployment target below SDK 27. Don't emit unconditional calls to the new `item:` overloads; the typecheck will fail with `'<API>' is only available in iOS 27.0 or newer`.

## Availability summary

| API | iOS | macOS | watchOS | tvOS | visionOS |
|---|---|---|---|---|---|
| `confirmationDialog(_:item:titleVisibility:actions:)` / `…actions:message:)` | 27 | 27 | 27 | 27 | 27 |
| `alert(_:item:actions:)` / `…actions:message:)` | 27 | 27 | 27 | 27 | 27 |
