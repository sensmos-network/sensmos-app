import java.util.Properties

plugins {
    id("com.android.application")
    // START: FlutterFire Configuration
    id("com.google.gms.google-services")
    // END: FlutterFire Configuration
    // The Flutter Gradle Plugin must be applied after the Android and Kotlin Gradle plugins.
    id("dev.flutter.flutter-gradle-plugin")
}

android {
    namespace = "com.zkv.sensmos"
    compileSdk = flutter.compileSdkVersion
    ndkVersion = flutter.ndkVersion

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    defaultConfig {
        // TODO: Specify your own unique Application ID (https://developer.android.com/studio/build/application-id.html).
        applicationId = "com.zkv.sensmos"
        // You can update the following values to match your application needs.
        // For more information, see: https://flutter.dev/to/review-gradle-config.
        minSdk = flutter.minSdkVersion  // firebase_messaging wymaga min. 23
        targetSdk = flutter.targetSdkVersion
        versionCode = flutter.versionCode
        versionName = flutter.versionName
    }

    // Google Play odrzuca klucz debug: build dla Play podpisuje kluczem przesyłania z pliku wskazanego
    // w SENSMOS_UPLOAD_KEY (key.properties). Bez zmiennej — klucz debug, jak APK z GitHuba (21:9E).
    val uploadKey = System.getenv("SENSMOS_UPLOAD_KEY")?.let { file(it) }?.takeIf { it.exists() }
    signingConfigs {
        if (uploadKey != null) {
            val p = Properties().apply { uploadKey.inputStream().use { load(it) } }
            create("upload") {
                storeFile = file(p.getProperty("storeFile"))
                storePassword = p.getProperty("storePassword")
                keyAlias = p.getProperty("keyAlias")
                keyPassword = p.getProperty("keyPassword")
            }
        }
    }

    buildTypes {
        release {
            signingConfig = signingConfigs.getByName(if (uploadKey != null) "upload" else "debug")
        }
    }
}

// Skaner QR (mobile_scanner 5.x) ciągnie ML Kit 17.2.0 i CameraX 1.3.3 z bibliotekami .so wyrównanymi do 4 KB;
// Google Play wymaga stron 16 KB (Android 15+). Tylko w :app — CameraX 1.6 wymaga compileSdk 36, a wtyczka ma niższy.
configurations.all {
    resolutionStrategy {
        force("com.google.mlkit:barcode-scanning:17.3.0")
        force("androidx.camera:camera-core:1.6.1")
        force("androidx.camera:camera-camera2:1.6.1")
        force("androidx.camera:camera-lifecycle:1.6.1")
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

flutter {
    source = "../.."
}
