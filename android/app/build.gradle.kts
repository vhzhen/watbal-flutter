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
// requirement). When the file is absent — fresh clone, CI, or day-to-day debug
// work — we fall back to debug signing below so `flutter run` still works.
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
            // Sign with the real release key when configured (Play uploads);
            // fall back to debug signing so `flutter run --release` and fresh
            // clones without the keystore still build.
            signingConfig = if (hasReleaseSigning) {
                signingConfigs.getByName("release")
            } else {
                signingConfigs.getByName("debug")
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
