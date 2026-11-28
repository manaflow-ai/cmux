// Android library (AAR) and JVM host tests for the generated Kotlin bindings
// of cmux-mobile-ffi. .github/workflows/cmux-mobile-ffi.yml passes the
// generated sources, the per-ABI .so files, the host library and the fixture
// corpus as -P properties; see ffi/build.gradle.kts.
pluginManagement {
    repositories {
        google()
        mavenCentral()
        gradlePluginPortal()
    }
}

dependencyResolutionManagement {
    repositoriesMode.set(RepositoriesMode.FAIL_ON_PROJECT_REPOS)
    repositories {
        google()
        mavenCentral()
    }
}

rootProject.name = "cmux-mobile"
include(":ffi")
