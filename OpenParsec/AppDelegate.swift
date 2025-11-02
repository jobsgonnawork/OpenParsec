import UIKit

@main
class AppDelegate:UIResponder, UIApplicationDelegate
{
	func application(_ application:UIApplication, didFinishLaunchingWithOptions launchOptions:[UIApplication.LaunchOptionsKey: Any]?) -> Bool
	{
		// Override point for customization after application launch.
		// Ensure Logs directory exists and has a file so the Files app shows our container
		let fm = FileManager.default
		if let docs = fm.urls(for: .documentDirectory, in: .userDomainMask).first {
			let logsDir = docs.appendingPathComponent("Logs", isDirectory: true)
			try? fm.createDirectory(at: logsDir, withIntermediateDirectories: true)
			let logURL = logsDir.appendingPathComponent("OpenParsec.log")
			if !fm.fileExists(atPath: logURL.path) {
				fm.createFile(atPath: logURL.path, contents: Data())
			}
		}
		UTMViewControllerPatches.patchAll()
		return true
	}

	func application(_ application:UIApplication, configurationForConnecting connectingSceneSession:UISceneSession, options:UIScene.ConnectionOptions) -> UISceneConfiguration
	{
		// Called when a new scene session is being created.
		// Use this method to select a configuration to create the new scene with.
		return UISceneConfiguration(name: "Default Configuration", sessionRole: connectingSceneSession.role)
	}

	func application(_ application:UIApplication, didDiscardSceneSessions sceneSessions:Set<UISceneSession>)
	{
		// Called when the user discards a scene session.
		// If any sessions were discarded while the application was not running, this will be called shortly after application:didFinishLaunchingWithOptions.
		// Use this method to release any resources that were specific to the discarded scenes, as they will not return.
	}

	func applicationWillTerminate(_ application: UIApplication)
	{
		CParsec.destroy()
	}
}
