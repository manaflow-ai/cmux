// The cmux-mobile-ffi AAR: generated Kotlin bindings plus libcmux_mobile_ffi.so
// for arm64-v8a and x86_64. Unit tests run on the build host's JVM against the
// host-built library (JNA), not on an emulator.
import org.jetbrains.kotlin.gradle.dsl.JvmTarget

plugins {
    id("com.android.library")
    id("org.jetbrains.kotlin.android")
}

fun requiredPath(name: String): String =
    providers.gradleProperty(name).orNull
        ?: throw GradleException("pass -P$name=<path> (see .github/workflows/cmux-mobile-ffi.yml)")

android {
    namespace = "com.cmuxterm.mobile.ffi"
    compileSdk = 35

    defaultConfig {
        // cargo-ndk builds the .so files for API 24 (--platform 24).
        minSdk = 24
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    sourceSets["main"].java.srcDir(requiredPath("uniffiKotlinDir"))
    sourceSets["main"].jniLibs.srcDir(requiredPath("jniLibsDir"))
}

tasks.withType<Test>().configureEach {
    systemProperty("jna.library.path", requiredPath("hostLibDir"))
    systemProperty("cmux.sizing.fixtures", requiredPath("sizingFixtures"))
    testLogging {
        events("passed", "failed", "skipped")
        exceptionFormat = org.gradle.api.tasks.testing.logging.TestExceptionFormat.FULL
    }
}

kotlin {
    compilerOptions {
        jvmTarget.set(JvmTarget.JVM_17)
    }
}

dependencies {
    // The AAR variant carries libjnidispatch.so for every Android ABI.
    implementation("net.java.dev.jna:jna:5.15.0@aar")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-core:1.9.0")
    // Host tests load the JAR variant, which carries the desktop dispatch library.
    testImplementation("net.java.dev.jna:jna:5.15.0")
    testImplementation("junit:junit:4.13.2")
    testImplementation("org.jetbrains.kotlinx:kotlinx-serialization-json:1.9.0")
}
