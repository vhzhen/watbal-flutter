allprojects {
    repositories {
        google()
        mavenCentral()
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

subprojects {
    tasks.withType<org.jetbrains.kotlin.gradle.tasks.KotlinCompile>().configureEach {
        compilerOptions {
            jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17)
        }
    }
    // Some plugins (e.g. home_widget) still declare Java 1.8 while their Kotlin
    // is forced to 17 above, which trips Gradle's "Inconsistent JVM Target
    // Compatibility" check. Rather than rewriting the raw JavaCompile tasks
    // (which drops the Android bootclasspath and breaks plugins like
    // flutter_inappwebview_android), bump the plugin's own AGP compileOptions to
    // 17. This must happen in afterEvaluate: the plugin sets 1.8 in its own
    // android{} script body, and we need to override that afterwards but before
    // AGP consumes compileOptions to configure the compile tasks. `:app` is
    // already evaluated here (via the evaluationDependsOn above) and already
    // targets 17, so skip anything that has finished evaluating.
    if (!state.executed) {
        afterEvaluate {
            (extensions.findByName("android") as? com.android.build.gradle.BaseExtension)
                ?.compileOptions?.apply {
                    sourceCompatibility = JavaVersion.VERSION_17
                    targetCompatibility = JavaVersion.VERSION_17
                }
        }
    }
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
