import UIKit
import SwiftUI
import MetalKit
import ParsecSDK

class SceneDelegate: UIResponder, UIWindowSceneDelegate {
	var window: UIWindow?

	func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
		if connectionOptions.shortcutItem?.type == ParsecBackgroundManager.reconnectShortcut {
			ParsecBackgroundManager.shared.reconnectPending = true
		}
		ParsecBackgroundManager.shared.updateShortcut()
		let contentView = ContentView()

		if let windowScene = scene as? UIWindowScene {
		    let window = UIWindow(windowScene: windowScene)
		    window.rootViewController = UIHostingController(rootView: contentView)
		    self.window = window
		    window.makeKeyAndVisible()
		}
	}

	func windowScene(_ windowScene: UIWindowScene, performActionFor shortcutItem: UIApplicationShortcutItem, completionHandler: @escaping (Bool) -> Void) {
		guard shortcutItem.type == ParsecBackgroundManager.reconnectShortcut, !ParsecBackgroundManager.shared.hasActiveConnection, !ParsecBackgroundManager.shared.isMarkedForReconnect, let reconnect = ParsecBackgroundManager.shared.onShortcutReconnect else {
			completionHandler(false)
			return
		}
		reconnect()
		completionHandler(true)
	}

	func sceneDidDisconnect(_ scene: UIScene) {
		if ParsecBackgroundManager.shared.hasActiveConnection {
			CParsec.sendReleaseMessage()
			CParsec.disconnect()
		}
	}

	private var pendingUnpause: DispatchWorkItem?

	func sceneDidBecomeActive(_ scene: UIScene) {
		if #available(iOS 15.0, *) {
			PictureInPictureManager.shared.stopPiP()
			if PictureInPictureManager.shared.stopFramePump() {
				ParsecBackgroundManager.shared.glkViewController?.isPaused = false
			}
		}
		if ParsecBackgroundManager.shared.isPaused {
			ParsecBackgroundManager.shared.glkViewController?.isPaused = false
			CParsec.resume()
			ParsecBackgroundManager.shared.resumedAt = Date()
			pendingUnpause?.cancel()
			let unpause = DispatchWorkItem { ParsecBackgroundManager.shared.isPaused = false }
			pendingUnpause = unpause
			DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: unpause)
		}
		// drop any input the host still thinks is held, a stuck modifier survives the resume
		if ParsecBackgroundManager.shared.hasActiveConnection {
			CParsec.sendReleaseMessage()
		}
		ParsecBackgroundManager.shared.sceneDidBecomeActive()
	}

	func sceneWillResignActive(_ scene: UIScene) {
		if ParsecBackgroundManager.shared.hasActiveConnection {
			CParsec.sendReleaseMessage()
		}
		ParsecBackgroundManager.shared.sceneWillResignActive()
	}

	func sceneWillEnterForeground(_ scene: UIScene) {
	}

	func sceneDidEnterBackground(_ scene: UIScene) {
		pendingUnpause?.cancel()
		pendingUnpause = nil
		var pipAttempted = false
		if #available(iOS 15.0, *) {
			if ParsecBackgroundManager.shared.hasActiveConnection && SettingsHandler.enablePiP {
				PictureInPictureManager.shared.startPiP()
				pipAttempted = PictureInPictureManager.shared.isPiPActive || PictureInPictureManager.shared.isStarting
			}
		}

		if pipAttempted {
			ParsecBackgroundManager.shared.isPaused = false
			if #available(iOS 15.0, *) {
				ParsecBackgroundManager.shared.glkViewController?.isPaused = true
				PictureInPictureManager.shared.startFramePump()
			}
		}

		if !pipAttempted && ParsecBackgroundManager.shared.hasActiveConnection {
			ParsecBackgroundManager.shared.glkViewController?.isPaused = true
			CParsec.sendReleaseMessage()
			CParsec.pause()
			ParsecBackgroundManager.shared.isPaused = true
		}

		if ParsecBackgroundManager.shared.hasActiveConnection {
			appNote("[background] picture in picture \(pipAttempted ? "starting" : "off"), stream \(pipAttempted ? "running" : "paused")")
		}
		ParsecBackgroundManager.shared.sceneDidEnterBackground()
	}
}

// the system connects this scene when a monitor is attached and the app is in front; it draws video stream 1 there
class ExternalDisplaySceneDelegate: UIResponder, UIWindowSceneDelegate {
	var window: UIWindow?

	func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
		guard let windowScene = scene as? UIWindowScene else { return }
		let screen = windowScene.screen
		appNote("[external] scene connected \(Int(screen.bounds.width))x\(Int(screen.bounds.height))@\(screen.scale) max \(screen.maximumFramesPerSecond) fps")
		let window = UIWindow(windowScene: windowScene)
		window.rootViewController = ExternalStreamViewController()
		window.isHidden = false
		self.window = window
	}

	func sceneDidDisconnect(_ scene: UIScene) {
		appNote("[external] scene disconnected")
		(window?.rootViewController as? ExternalStreamViewController)?.shutDown()
		window = nil
	}
}

class ExternalStreamViewController: UIViewController {
	private var metalView: MTKView?
	private var renderer: ParsecMetalRenderer?
	private let waitingLabel = UILabel()
	private var watchTimer: Timer?
	// stream 1 is started once per connection; picking Off in the menu keeps it off until the next one
	private var autoStarted = false

	override func viewDidLoad() {
		super.viewDidLoad()
		view.backgroundColor = .black

		if let device = MTLCreateSystemDefaultDevice(), let renderer = ParsecMetalRenderer(device, stream: 1, {}) {
			let mtk = MTKView(frame: view.bounds, device: device)
			mtk.autoresizingMask = [.flexibleWidth, .flexibleHeight]
			mtk.colorPixelFormat = .bgra8Unorm
			mtk.clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
			mtk.autoResizeDrawable = false
			mtk.isPaused = true
			mtk.delegate = renderer
			view.addSubview(mtk)
			metalView = mtk
			self.renderer = renderer
		} else {
			appNote("[external] no metal renderer, nothing will be drawn")
		}

		waitingLabel.text = "OpenParsec: waiting for the 2nd screen"
		waitingLabel.textColor = UIColor.white.withAlphaComponent(0.5)
		waitingLabel.font = .systemFont(ofSize: 20, weight: .medium)
		waitingLabel.translatesAutoresizingMaskIntoConstraints = false
		view.addSubview(waitingLabel)
		NSLayoutConstraint.activate([
			waitingLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
			waitingLabel.centerYAnchor.constraint(equalTo: view.centerYAnchor)
		])

		CParsec.stream1Drawn = true
		watchTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
			self?.watch()
		}
		watch()
	}

	override func viewDidAppear(_ animated: Bool) {
		super.viewDidAppear(animated)
		if let screen = view.window?.windowScene?.screen {
			metalView?.preferredFramesPerSecond = screen.maximumFramesPerSecond
		}
		// ask the host for the monitor's size on video[1]
		DataManager.model.stream1ResolutionX = Int(view.bounds.width)
		DataManager.model.stream1ResolutionY = Int(view.bounds.height)
		if DataManager.model.stream1Output != nil {
			CParsec.updateHostVideoConfig()
		}
	}

	private func watch() {
		let model = DataManager.model
		guard CParsec.parsecImpl != nil, CParsec.getStatus() == PARSEC_OK else {
			autoStarted = false
			show(streaming: false)
			return
		}
		if !autoStarted && model.stream1Output == nil && model.displayConfigs.count > 1 {
			autoStarted = true
			let other = model.displayConfigs.first { model.output != "none" && $0.id != model.output } ?? model.displayConfigs[1]
			appNote("[external] starting stream 1 on \(other.name) \(other.id)")
			CParsec.startStream1(output: other.id)
		}
		show(streaming: model.stream1Output != nil)
	}

	private func show(streaming: Bool) {
		guard metalView?.isPaused != !streaming else { return }
		metalView?.isPaused = !streaming
		waitingLabel.isHidden = streaming
		if !streaming {
			renderer?.reset()
		}
	}

	func shutDown() {
		watchTimer?.invalidate()
		watchTimer = nil
		metalView?.isPaused = true
		CParsec.stream1Drawn = false
		// a monitor nobody is looking at shouldn't keep eating bandwidth
		CParsec.stopStream1()
	}
}
