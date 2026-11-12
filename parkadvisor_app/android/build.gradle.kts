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

tasks.register<Delete>("clean") {
    delete(rootProject.layout.buildDirectory)
}

// PARKNOW_SDK_OVERRIDE
subprojects {
    plugins.withId("com.android.library") {
        extensions.configure<com.android.build.api.variant.LibraryAndroidComponentsExtension>("androidComponents") {
            finalizeDsl { dsl ->
                dsl.compileSdk = 37
            }
        }
    }
}
