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
    // Some plugins (e.g. home_widget, workmanager_android) declare both their
    // own Java *and* Kotlin compile targets at 1.8, independently of anything
    // set here. A `tasks.withType<KotlinCompile>` block executed at this point
    // in *this* script runs before those plugins' own `android {}` blocks
    // configure their tasks, so it gets silently overwritten — Gradle then sees
    // Java at 17 (from the block below) and Kotlin still at 1.8, and fails with
    // "Inconsistent JVM Target Compatibility". Applying both overrides once the
    // plugin's own config has already run fixes Java and Kotlin together.
    //
    // `:app`'s `evaluationDependsOn(":app")` above forces `:app` itself to
    // finish evaluating before *this* subprojects block even starts, so
    // `afterEvaluate` on `:app` throws ("already evaluated") — apply the fix to
    // it immediately instead. Every other subproject is still pending, so
    // `afterEvaluate` is what defers past its own plugin's configuration.
    // `:app`'s `evaluationDependsOn(":app")` above forces `:app` itself to
    // finish evaluating — and have AGP finalize its `compileOptions` — before
    // *this* subprojects block even starts. Rewriting compileOptions there
    // throws ("has been finalized") regardless of the value written, so `:app`
    // is skipped outright: it's already 17/17 via its own block in
    // app/build.gradle.kts and needs none of this fix. Every other subproject
    // is still pending, and `afterEvaluate` is what defers past its own
    // plugin's configuration for those.
    if (name == "app") return@subprojects
    fun applyJvmTargetFix() {
        (extensions.findByName("android") as? com.android.build.gradle.BaseExtension)
            ?.compileOptions?.apply {
                sourceCompatibility = JavaVersion.VERSION_17
                targetCompatibility = JavaVersion.VERSION_17
            }
        tasks.withType<org.jetbrains.kotlin.gradle.tasks.KotlinCompile>().configureEach {
            compilerOptions {
                jvmTarget.set(org.jetbrains.kotlin.gradle.dsl.JvmTarget.JVM_17)
            }
        }
    }
    if (state.executed) applyJvmTargetFix() else afterEvaluate { applyJvmTargetFix() }
}

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}
