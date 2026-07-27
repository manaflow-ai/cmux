# DynamicNotchKit

<div><video controls src="https://github.com/user-attachments/assets/09a139a8-1a40-4214-bcd9-1937764fb071" muted="true"></video></div>

DynamicNotchKit provides a set of tools to help you integrate your macOS app with the new notch on modern MacBooks. It attempts to provide a similar experience to iOS's Dynamic Island, allowing you to display notifications and updates in a visually appealing way. It handles the complexities of managing the notch area, such as drawing a custom window, ensuring proper content insets and safe areas. This enables you to create a polished user experience that feels native to the platform, while still feeling innovative and fresh.

## Installation

Compatibility: **macOS 13+**

Add `https://github.com/MrKai77/DynamicNotchKit` in the [“Swift Package Manager” tab in Xcode](https://developer.apple.com/documentation/xcode/adding_package_dependencies_to_your_app).

## Usage

It's really easy! All the UI is handled by SwiftUI. That means that you can use your existing views *directly* in DynamicNotchKit!

Here's an example:
```swift
let notch = DynamicNotch {
    ContentView()
}
await notch.expand()
```

Where `ContentView` conforms to `View`.

DynamicNotchKit also supports Macs without a notch, meaning that this package supports _all_ Mac styles! You will see an example of that below.

## DynamicNotchInfo

In addition, there is also a `DynamicNotchInfo`, which is a fine-tuned version of the DynamicNotch specifically tailored to show general information:
```swift
let notch = DynamicNotchInfo(
    icon: .init(systemName: "figure"),
    title: "Figure",
    description: "Looks like a person"
)
await notch.expand()
```

This will result in a popover as so:

<img src="media/demo.gif" width="50%"/>

Furthermore, there is a `.floating` style, which will **automatically** be used on Macs without a notch:

<img src="media/demo-floating.gif" width="50%"/>

This is only a basic glimpse into this framework's capabilities. Documentation is available for **all** public methods and properties, so I encourage you to take a look at it for more advanced usage. Alternatively, you can take a look at the unit tests for this package, where I have added some usage examples as well.

Feel free to ask questions/report issues in the Issues tab!

# License

This project is licensed under the [MIT license](LICENSE).
