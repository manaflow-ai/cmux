# ``DynamicNotchKit``

Seamlessly adapt your macOS app to the notch era.

@Metadata {
    @Available(macOS, introduced: "13.0")
}

## Overview

@Video(source: "intro", alt: "DynamicNotchKit Introduction")

DynamicNotchKit provides a set of tools to help you integrate your macOS app with the new notch on modern MacBooks. It attempts to provide a similar experience to iOS's Dynamic Island, allowing you to display notifications and updates in a visually appealing way. It handles the complexities of managing the notch area, such as drawing a custom window, ensuring proper content insets and safe areas. This enables you to create a polished user experience that feels native to the platform, while still feeling innovative and fresh.

Unfortunately, a limitation (much like iOS), is that not all devices have this notch. Lucky for you, DynamicNotchKit is designed to be flexible and can adapt to different screen types and sizes, and provides a floating window style as backup. This ensures that your app looks great on _all_ devices.

## The Vision

There are _many_, _**many**_ macOS apps that attempt to add functionality to the notch. Unfortunately, what a lot of them do is to attempt to put *too* much functionality into such a small popover. The goal for DynamicNotchKit is not to replace the main app window, but to provide a simple and elegant way to display notifications and updates in a way that feels native to the platform, similar to iOS's Dynamic Island.
