plugins {
    id("com.android.application")
    id("kotlin-android")
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

val releaseRequested = gradle.startParameter.taskNames.any {
    it.contains("release", ignoreCase = true)
}
val wardrobeKeystorePath = System.getenv("WARDROBE_KEYSTORE_PATH")
val wardrobeKeystorePassword = System.getenv("WARDROBE_KEYSTORE_PASSWORD")
val wardrobeKeyAlias = System.getenv("WARDROBE_KEY_ALIAS") ?: "wardrobe"

if (releaseRequested) {
    require(!wardrobeKeystorePath.isNullOrBlank()) {
        "Release signing requires WARDROBE_KEYSTORE_PATH. See apps/wardrobe_flutter/README.md."
    }
    require(!wardrobeKeystorePassword.isNullOrBlank()) {
        "Release signing requires WARDROBE_KEYSTORE_PASSWORD. See apps/wardrobe_flutter/README.md."
    }
    require(file(wardrobeKeystorePath).isFile) {
        "WARDROBE_KEYSTORE_PATH does not point to a readable file."
    }
}

android {
    namespace = "app.wardrobe.viewer"
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
        applicationId = "app.wardrobe.viewer"
        minSdk = flutter.minSdkVersion
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    signingConfigs {
        if (!wardrobeKeystorePath.isNullOrBlank() && !wardrobeKeystorePassword.isNullOrBlank()) {
            create("wardrobeRelease") {
                storeFile = file(wardrobeKeystorePath)
                storePassword = wardrobeKeystorePassword
                keyAlias = wardrobeKeyAlias
                keyPassword = wardrobeKeystorePassword
                storeType = "PKCS12"
            }
        }
    }

    buildTypes {
        release {
            if (releaseRequested) {
                signingConfig = signingConfigs.getByName("wardrobeRelease")
            }
        }
    }
}

flutter {
    source = "../.."
}
