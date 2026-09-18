import java.io.FileInputStream
import java.util.Properties

plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

// Release signing is loaded from android/key.properties, which is git-ignored
// so the keystore path + passwords never enter source control (a Play Store
// requirement). When the file is absent, debug builds still work normally;
// *release* builds fail loudly rather than quietly self-signing with the
// public debug key (see the release buildType below).
val keystoreProperties = Properties()
val keystorePropertiesFile = rootProject.file("key.properties")
val hasReleaseSigning = keystorePropertiesFile.exists()
if (hasReleaseSigning) {
    keystoreProperties.load(FileInputStream(keystorePropertiesFile))
}

android {
    namespace = "com.vincent.watbal"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    buildFeatures {
        // The widget receivers guard their balance logging with
        // `BuildConfig.DEBUG`; AGP 8+ stops generating BuildConfig unless asked.
        buildConfig = true
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    kotlinOptions {
        jvmTarget = JavaVersion.VERSION_17.toString()
    }

    defaultConfig {
        // Real, unique application ID (matches the iOS bundle / app group family
        // `com.vincent.watbal`). Google Play rejects the `com.example.*` default.
        applicationId = "com.vincent.watbal"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        // Only define the release signing config when key.properties is present;
        // otherwise there's nothing to sign with and referencing empty values
        // would fail the configuration phase.
        if (hasReleaseSigning) {
            create("release") {
                keyAlias = keystoreProperties["keyAlias"] as String
                keyPassword = keystoreProperties["keyPassword"] as String
                storeFile = keystoreProperties["storeFile"]?.let { file(it) }
                storePassword = keystoreProperties["storePassword"] as String
            }
        }
    }

    buildTypes {
        release {
            // Sign with the real release key when key.properties is present,
            // otherwise fall back to the debug key *for configuration only* —
            // the taskGraph guard below aborts the build before any release
            // artifact is actually produced with it. Assigning something here
            // is unavoidable: this block is evaluated on every Gradle
            // invocation (including assembleDebug), so throwing at this point
            // would break ordinary `flutter run`.
            signingConfig = if (hasReleaseSigning) {
                signingConfigs.getByName("release")
            } else {
                signingConfigs.getByName("debug")
            }
        }
    }
}

// Refuse to actually *build* a release artifact with the debug key.
//
// The debug keystore ships with the Android SDK and its password is the literal
// string "android", so a debug-signed release is effectively unsigned — anyone
// can forge an "update" for it. Play rejects such uploads, but a sideloaded or
// CI-produced artifact would carry a publicly-known key with no warning.
//
// This runs once the task graph is known, so it trips only on a real release
// build (assembleRelease / bundleRelease / installRelease …) and never on debug
// or profile builds. Opt out for local testing with -PallowDebugSigning=true.
val allowDebugSigning =
    (project.findProperty("allowDebugSigning") as String?)?.toBoolean() ?: false

if (!hasReleaseSigning) {
    gradle.taskGraph.whenReady {
        val buildingRelease = allTasks.any { task ->
            task.project == project &&
                Regex("^(assemble|bundle|install|package)\\w*Release$").matches(task.name)
        }
        if (buildingRelease) {
            if (allowDebugSigning) {
                logger.warn(
                    "WARNING: signing this release build with the DEBUG key " +
                        "(android/key.properties is missing). The resulting " +
                        "artifact must never be distributed."
                )
            } else {
                throw GradleException(
                    "Release signing is not configured: android/key.properties is missing.\n" +
                        "Copy android/key.properties.example to android/key.properties and " +
                        "fill it in (see that file for keytool instructions).\n" +
                        "To build an undistributable debug-signed release anyway, pass " +
                        "-PallowDebugSigning=true."
                )
            }
        }
    }
}

// home_widget 0.9.x pulls androidx.glance:glance-appwidget:1.3.0-alpha01, an
// alpha that demands compileSdk 37 + AGP 9.1.0. The Android widget isn't built
// for this project yet (iOS-only), so pin Glance to the stable 1.1.1, which
// builds fine against the current compileSdk/AGP. Remove this once the project
// formally adopts AGP 9 for Android.
configurations.all {
    resolutionStrategy {
        force("androidx.glance:glance:1.1.1")
        force("androidx.glance:glance-appwidget:1.1.1")
    }
}

flutter {
    source = "../.."
}
