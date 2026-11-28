// Versions match the manaflow-ai/iroh-ffi fork's Kotlin build, so its AAR can
// fold into this one (MOBILE-RUST-2). AGP 8.13 needs Gradle 8.13.
plugins {
    id("com.android.library") version "8.13.0" apply false
    id("org.jetbrains.kotlin.android") version "2.2.20" apply false
}
