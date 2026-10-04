allprojects {
    repositories {
        google()
        mavenCentral()
    }
    // Skaner QR (mobile_scanner 5.x) ciągnie ML Kit 17.2.0 i CameraX 1.3.3 z bibliotekami .so wyrównanymi
    // do 4 KB; Google Play wymaga stron 16 KB (Android 15+). Te wersje mają już wyrównanie 16 KB.
    configurations.all {
        resolutionStrategy {
            force("com.google.mlkit:barcode-scanning:17.3.0")
            force("androidx.camera:camera-core:1.6.1")
            force("androidx.camera:camera-camera2:1.6.1")
            force("androidx.camera:camera-lifecycle:1.6.1")
        }
    }
}

val newBuildDir: Directory =
    rootProject.layout.buildDirectory
        .dir("../../build")
        .get()
rootProject.layout.buildDirectory.value(newBuildDir)

subprojects {
    val newSubprojectBuildDir: Directory = newBuildDir.dir(project.name)
    project.layout.buildDirectory.value(newSubprojectBuildDir)
}
subprojects {
    project.evaluationDependsOn(":app")
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
