plugins {
    id("com.android.application")
}

// Version lives in BuildInfo.java so the Gradle and on-device (build.sh) builds always agree.
val buildInfo = file("src/main/java/app/buddy/assistant/BuildInfo.java").readText()
val appVersionName = Regex("""VERSION = "([^"]+)"""").find(buildInfo)!!.groupValues[1]
val appVersionCode = Regex("""VERSION_CODE = (\d+)""").find(buildInfo)!!.groupValues[1].toInt()

// proot and friends are gitignored under jniLibs/; without them the APK cannot start Buddy's Linux.
val jniProot = file("src/main/jniLibs/arm64-v8a/libproot.so")
tasks.matching { it.name.startsWith("assemble") || it.name.startsWith("install") }.configureEach {
    doFirst {
        if (!jniProot.isFile) {
            throw GradleException(
                "Missing ${jniProot.path}. Build natives first: on Windows run .\\native\\build.ps1 " +
                    "(Git Bash + NDK); elsewhere run ANDROID_NDK_HOME=… native/build.sh. " +
                    "Also: git submodule update --init"
            )
        }
    }
}

// assets/linux and assets/third_party are git symlinks. On Windows (core.symlinks=false) they become
// 17-byte text files, so the APK ships no buddy-run and every agent install fails with "linux/buddy-run".
// Always pack the real trees into a generated assets dir and skip those placeholders.
val packedAssets = layout.buildDirectory.dir("packedAssets")
val prepareBuddyAssets = tasks.register<Sync>("prepareBuddyAssets") {
    into(packedAssets)
    from("src/main/assets") {
        exclude("linux")
        exclude("third_party")
    }
    from(rootProject.file("linux")) {
        into("linux")
        exclude("test/**")
    }
    from(rootProject.file("third_party")) {
        into("third_party")
        include("README.md", "*-LICENSE.txt")
    }
    doLast {
        val buddyRun = packedAssets.get().file("linux/buddy-run").asFile
        if (!buddyRun.isFile) {
            throw GradleException("prepareBuddyAssets did not produce linux/buddy-run from ${rootProject.file("linux")}")
        }
        // Windows checkouts often have CRLF (core.autocrlf). Alpine bash then dies with exit 2 on `{`.
        val linuxDir = packedAssets.get().dir("linux").asFile
        linuxDir.walkTopDown().filter { it.isFile }.forEach { f ->
            val name = f.name
            val script = name == "buddy-run" || name == "buddy-copilot" || name == "buddy-browser"
                    || name == "codex-remote" || name == "arecord" || name == "onphone-get"
                    || name.endsWith(".sh")
            if (!script) return@forEach
            val bytes = f.readBytes()
            if (!bytes.contains('\r'.code.toByte())) return@forEach
            f.writeBytes(bytes.filterNot { it == '\r'.code.toByte() }.toByteArray())
        }
    }
}
tasks.named("preBuild").configure { dependsOn(prepareBuddyAssets) }

android {
    sourceSets.getByName("main").assets.setSrcDirs(listOf(packedAssets))
    // proot for the built-in Linux ships as native libraries and must be extracted to disk to run
    packaging {
        jniLibs {
            useLegacyPackaging = true
        }
    }
    namespace = "app.buddy.assistant"
    compileSdk = 36

    defaultConfig {
        applicationId = "app.buddy.assistant"
        minSdk = 30
        targetSdk = 36
        versionCode = appVersionCode
        versionName = appVersionName
    }

    // Release signing comes from environment variables (set as GitHub Actions secrets).
    // Without them, assembleRelease produces an unsigned APK.
    val keystorePath = System.getenv("BUDDY_KEYSTORE")
    signingConfigs {
        if (keystorePath != null) {
            create("release") {
                storeFile = file(keystorePath)
                storePassword = System.getenv("BUDDY_KEYSTORE_PASSWORD")
                keyAlias = System.getenv("BUDDY_KEY_ALIAS") ?: "buddy"
                keyPassword = System.getenv("BUDDY_KEY_PASSWORD") ?: System.getenv("BUDDY_KEYSTORE_PASSWORD")
            }
        }
    }

    // github: the release on GitHub, which updates itself from GitHub releases.
    // fdroid: built and signed by F-Droid from this source; the same app without the self-updater (F-Droid updates it).
    flavorDimensions += "store"
    productFlavors {
        create("github") { dimension = "store" }
        create("fdroid") { dimension = "store" }
    }

    // No Google-only dependency blob and no git details in the APK: F-Droid requires the first, and both keep the
    // fdroid APK the same whoever builds it (F-Droid's reproducible build compares its APK with the one on GitHub).
    dependenciesInfo {
        includeInApk = false
        includeInBundle = false
    }

    buildTypes {
        release {
            isMinifyEnabled = false
            vcsInfo.include = false
            if (keystorePath != null) signingConfig = signingConfigs.getByName("release")
        }
    }

    compileOptions {
        sourceCompatibility = JavaVersion.VERSION_1_8
        targetCompatibility = JavaVersion.VERSION_1_8
    }

    buildFeatures {
        buildConfig = false
    }
}
