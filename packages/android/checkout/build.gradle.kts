import org.jetbrains.kotlin.gradle.dsl.JvmTarget

plugins {
    id("com.android.library")
    id("org.jetbrains.kotlin.android")
    id("org.jetbrains.kotlin.plugin.compose")
    id("org.jetbrains.kotlin.plugin.parcelize")
    id("com.vanniktech.maven.publish")
}

val sdkVersion = providers.gradleProperty("VERSION_NAME").get()

android {
    namespace = "com.vezmo.checkout"
    compileSdk = 36
    resourcePrefix = "vezmo_"

    defaultConfig {
        minSdk = 24
        testInstrumentationRunner = "androidx.test.runner.AndroidJUnitRunner"
        // Sent as `Vezmo-SDK: android/<version>` so a payment records which SDK took it.
        buildConfigField("String", "SDK_VERSION", "\"$sdkVersion\"")
    }

    buildFeatures {
        compose = true
        buildConfig = true
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_17
        targetCompatibility = JavaVersion.VERSION_17
    }

    testOptions {
        unitTests.isReturnDefaultValues = true
    }

    lint {
        abortOnError = true
        checkReleaseBuilds = true
    }
}

kotlin {
    compilerOptions {
        jvmTarget.set(JvmTarget.JVM_17)
    }
}

dependencies {
    // In the public API: VezmoCheckout(activity, …) and rememberVezmoCheckout().
    api("androidx.activity:activity-compose:1.10.1")
    // The native payment engine the sheet runs on, pinned exactly (the same release as the React Native package).
    implementation("com.stripe:stripe-android:23.23.0")
    // Instant ACH's bank step, drawn natively (without it the engine falls back to a web page).
    implementation("com.stripe:financial-connections:23.23.0")
    implementation(platform("androidx.compose:compose-bom:2025.06.01"))
    implementation("androidx.compose.ui:ui")
    implementation("androidx.compose.foundation:foundation")
    implementation("androidx.lifecycle:lifecycle-runtime-compose:2.9.1")
    implementation("androidx.lifecycle:lifecycle-viewmodel-compose:2.9.1")
    implementation("org.jetbrains.kotlinx:kotlinx-coroutines-android:1.10.2")

    testImplementation("junit:junit:4.13.2")
    testImplementation("org.jetbrains.kotlinx:kotlinx-coroutines-test:1.10.2")
    // A real org.json for JVM tests (Android's is a stub there).
    testImplementation("org.json:json:20250517")

    // The sheet's screenshot tests, on the emulator in CI.
    androidTestImplementation(platform("androidx.compose:compose-bom:2025.06.01"))
    androidTestImplementation("androidx.compose.ui:ui-test-junit4")
    androidTestImplementation("androidx.compose.ui:ui-test-manifest")
    androidTestImplementation("androidx.test:runner:1.6.2")
    androidTestImplementation("androidx.test.ext:junit:1.2.1")
}

mavenPublishing {
    coordinates("com.vezmo", "vezmo-checkout", sdkVersion)
    publishToMavenCentral()
    // Signed only when the release key is present (the release workflow); publishToMavenLocal works without it.
    if (providers.gradleProperty("signingInMemoryKey").isPresent) signAllPublications()

    pom {
        name.set("Vezmo Checkout")
        description.set("The Vezmo payment sheet for Android apps: cards with 3D Secure, Google Pay, pay-later methods, UPI and Pix, in the buyer's own currency.")
        inceptionYear.set("2026")
        url.set("https://github.com/vezmoPay/vezmo-mobile-sdk")
        licenses {
            license {
                name.set("MIT License")
                url.set("https://opensource.org/licenses/MIT")
                distribution.set("repo")
            }
        }
        developers {
            developer {
                id.set("vezmo")
                name.set("Vezmo")
                url.set("https://vezmo.com")
            }
        }
        scm {
            url.set("https://github.com/vezmoPay/vezmo-mobile-sdk")
            connection.set("scm:git:https://github.com/vezmoPay/vezmo-mobile-sdk.git")
            developerConnection.set("scm:git:ssh://git@github.com/vezmoPay/vezmo-mobile-sdk.git")
        }
    }
}
