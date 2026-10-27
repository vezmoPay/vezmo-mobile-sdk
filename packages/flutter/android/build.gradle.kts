// The plugin's Android side: a thin bridge from Dart to the native Vezmo Android SDK (com.vezmo:vezmo-checkout),
// which draws the sheet.
group = "com.vezmo.flutter.checkout"
version = "0.2.0"

buildscript {
    val kotlinVersion = "2.4.0"
    repositories {
        google()
        mavenCentral()
    }

    dependencies {
        classpath("com.android.tools.build:gradle:9.1.0")
        classpath("org.jetbrains.kotlin:kotlin-gradle-plugin:$kotlinVersion")
    }
}

allprojects {
    repositories {
        // Only for this repository's CI, which builds com.vezmo:vezmo-checkout into Maven local first
        // (ORG_GRADLE_PROJECT_vezmoMavenLocal=true): ahead of Maven Central, which has the released build of the same
        // version. Apps get it from Maven Central.
        if (providers.gradleProperty("vezmoMavenLocal").isPresent) {
            mavenLocal { content { includeGroup("com.vezmo") } }
        }
        google()
        mavenCentral()
    }
}

plugins {
    id("com.android.library")
}

android {
    namespace = "com.vezmo.flutter.checkout"

    compileSdk = 36

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    sourceSets {
        getByName("main") {
            java.srcDirs("src/main/kotlin")
        }
        getByName("test") {
            java.srcDirs("src/test/kotlin")
        }
    }

    // The plugin's lifecycle runs against real activities (Robolectric) and the real native SDK, talking to a local
    // server: `./gradlew :vezmo_checkout:testDebugUnitTest` from example/android, after a `flutter build`.
    testOptions {
        unitTests.isIncludeAndroidResources = true
    }

    defaultConfig {
        minSdk = 24
    }
}

kotlin {
    compilerOptions {
        jvmTarget = org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17
    }
}

dependencies {
    // The native SDK, pinned exactly: the plugin's version and the SDK's move together.
    implementation("com.vezmo:vezmo-checkout:0.2.0")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.10.2")

    testImplementation("junit:junit:4.13.2")
    testImplementation("org.robolectric:robolectric:4.16")
    testImplementation("com.squareup.okhttp3:mockwebserver:4.12.0")
}
