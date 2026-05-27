import Flutter
import UIKit
import workmanager

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    // Re-register Flutter plugins inside the background isolate so http /
    // shared_preferences / home_widget work when the workmanager
    // BGProcessingTask runs.
    WorkmanagerPlugin.setPluginRegistrantCallback { registry in
      GeneratedPluginRegistrant.register(with: registry)
    }
    WorkmanagerPlugin.registerTask(
      withIdentifier: "com.vincent.watbal.refresh"
    )

    // Native BGAppRefreshTask path — runs alongside the workmanager
    // BGProcessingTask and fires much more often during normal app use. Must
    // be registered before app launch completes.
    BalanceRefresher.register()
    BalanceRefresher.schedule()

    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  override func applicationDidEnterBackground(_ application: UIApplication) {
    // Re-queue on every background entry. iOS clears pending tasks aggressively;
    // re-submitting here gives us the best odds of being fired before the user
    // reopens the app.
    BalanceRefresher.schedule()
    super.applicationDidEnterBackground(application)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
  }
}
