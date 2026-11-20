import AppKit

// Parsec doesn't put the cursor in the video, each client draws its own, and a client only draws
// it for the guest moving it. When OpenParsec on the iPad moves the cursor onto a display another
// device watches (Add Screens on a PC), that device never shows it. This draws a copy of the
// cursor in a click-through window on the chosen displays, so it is captured into their stream.

private let defaults = UserDefaults.standard
private let hiddenScreensKey = "hiddenScreens"

final class OverlayWindow: NSWindow {
	let imageView = NSImageView()

	init(screen: NSScreen) {
		super.init(contentRect: screen.frame, styleMask: .borderless, backing: .buffered, defer: false)
		setFrame(screen.frame, display: false)
		isOpaque = false
		backgroundColor = .clear
		hasShadow = false
		ignoresMouseEvents = true
		level = .screenSaver
		collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
		// must stay capturable, or Parsec won't see it
		sharingType = .readOnly
		isReleasedWhenClosed = false
		imageView.imageScaling = .scaleNone
		imageView.isHidden = true
		contentView = NSView(frame: NSRect(origin: .zero, size: screen.frame.size))
		contentView?.addSubview(imageView)
	}
}

final class Overlay: NSObject, NSApplicationDelegate, NSMenuDelegate {
	private var statusItem: NSStatusItem!
	private var windows: [CGDirectDisplayID: OverlayWindow] = [:]
	private var timer: Timer?
	private var lastImage: NSImage?
	private var enabled = true

	// displays are remembered by id; the menu bar display is skipped unless picked, its client draws the cursor already
	private var hiddenScreens: Set<UInt32> {
		get {
			if let saved = defaults.array(forKey: hiddenScreensKey) as? [UInt32] { return Set(saved) }
			return NSScreen.screens.first.map { [Overlay.displayID($0)] } ?? []
		}
		set { defaults.set(Array(newValue), forKey: hiddenScreensKey) }
	}

	static func displayID(_ screen: NSScreen) -> CGDirectDisplayID {
		(screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
	}

	func applicationDidFinishLaunching(_ notification: Notification) {
		statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
		statusItem.button?.image = NSImage(systemSymbolName: "cursorarrow.rays", accessibilityDescription: "Cursor Overlay")
		let menu = NSMenu()
		menu.delegate = self
		statusItem.menu = menu

		NotificationCenter.default.addObserver(self, selector: #selector(screensChanged), name: NSApplication.didChangeScreenParametersNotification, object: nil)
		screensChanged()

		let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in self?.tick() }
		RunLoop.main.add(timer, forMode: .common)
		self.timer = timer
	}

	@objc private func screensChanged() {
		let screens = NSScreen.screens
		let ids = Set(screens.map(Overlay.displayID))
		for (id, window) in windows where !ids.contains(id) {
			window.close()
			windows[id] = nil
		}
		for screen in screens {
			let id = Overlay.displayID(screen)
			if let window = windows[id] {
				window.setFrame(screen.frame, display: false)
				window.contentView?.frame = NSRect(origin: .zero, size: screen.frame.size)
			} else {
				let window = OverlayWindow(screen: screen)
				window.orderFrontRegardless()
				windows[id] = window
			}
		}
	}

	private func tick() {
		let location = NSEvent.mouseLocation
		let screen = NSScreen.screens.first { NSMouseInRect(location, $0.frame, false) }
		let target = screen.map(Overlay.displayID)
		let hidden = hiddenScreens
		let cursor = NSCursor.currentSystem ?? NSCursor.arrow
		let image = cursor.image

		for (id, window) in windows {
			guard enabled, id == target, !hidden.contains(id), let screen = screen else {
				window.imageView.isHidden = true
				continue
			}
			if image !== lastImage {
				window.imageView.image = image
			}
			let hot = cursor.hotSpot
			// window coordinates have a bottom left origin, the hot spot is measured from the top left
			let x = location.x - screen.frame.minX - hot.x
			let y = location.y - screen.frame.minY - (image.size.height - hot.y)
			window.imageView.frame = NSRect(x: x.rounded(), y: y.rounded(), width: image.size.width, height: image.size.height)
			window.imageView.isHidden = false
		}
		lastImage = image
	}

	func menuNeedsUpdate(_ menu: NSMenu) {
		menu.removeAllItems()
		let toggle = NSMenuItem(title: "Draw Cursor", action: #selector(toggleEnabled), keyEquivalent: "")
		toggle.target = self
		toggle.state = enabled ? .on : .off
		menu.addItem(toggle)
		menu.addItem(.separator())
		menu.addItem(NSMenuItem(title: "Draw on", action: nil, keyEquivalent: ""))
		let hidden = hiddenScreens
		for (index, screen) in NSScreen.screens.enumerated() {
			let id = Overlay.displayID(screen)
			let item = NSMenuItem(title: "\(index + 1). \(screen.localizedName)\(index == 0 ? " (menu bar)" : "")", action: #selector(toggleScreen(_:)), keyEquivalent: "")
			item.target = self
			item.tag = Int(id)
			item.state = hidden.contains(id) ? .off : .on
			item.indentationLevel = 1
			menu.addItem(item)
		}
		menu.addItem(.separator())
		menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
	}

	@objc private func toggleEnabled() {
		enabled.toggle()
	}

	@objc private func toggleScreen(_ item: NSMenuItem) {
		let id = UInt32(item.tag)
		var hidden = hiddenScreens
		if hidden.contains(id) {
			hidden.remove(id)
		} else {
			hidden.insert(id)
		}
		hiddenScreens = hidden
	}
}

let app = NSApplication.shared
let overlay = Overlay()
app.delegate = overlay
app.setActivationPolicy(.accessory)
app.run()
