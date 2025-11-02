import ParsecSDK
import MetalKit
import UIKit
import QuartzCore
import CoreImage
import CoreVideo

enum RendererType:Int
{
	case opengl
    case metal
}

enum DecoderPref:Int
{
    case h264
    case h265
}

enum CursorMode:Int
{
    case touchpad
    case direct
}

enum RightClickPosition:Int
{
	case firstFinger
	case middle
	case secondFinger
}

struct KeyBoardKeyEvent {
	var input: UIKey?
	var isPressBegin: Bool
}

class ParsecSDKBridge: ParsecService
{
	var hostWidth: Float = 1920
	
	var hostHeight: Float = 1080
	
	
	static let PARSEC_VER:UInt32 = UInt32((PARSEC_VER_MAJOR << 16) | PARSEC_VER_MINOR)
	
	private var _parsec:OpaquePointer!
	private var _audio:OpaquePointer!
	private let _audioPtr:UnsafeRawPointer
	
	private var isVirtualShiftOn = false
	
	public var clientWidth:Float = 1920
	public var clientHeight:Float = 1080
	
	public var netProtocol:Int32 = 1
	public var mediaContainer:Int32 = 0
	public var pngCursor:Bool = false
	var backgroundTaskRunning = true
	var didSetResolution = false
	
	public var mouseInfo = MouseInfo()

	// Video FPS tracking (count new frames via pre-render callback or PollFrame)
	private var videoFrameCount: Int = 0
	private var lastVideoFPSTimestamp: CFTimeInterval = CACurrentMediaTime()

	private func onPreRenderFrame() {
		videoFrameCount += 1
		let now = CACurrentMediaTime()
		let elapsed = now - lastVideoFPSTimestamp
		if elapsed >= 1.0 {
			let fps = Double(videoFrameCount) / elapsed
			DispatchQueue.main.async {
				DataManager.model.videoFps = fps
			}
			videoFrameCount = 0
			lastVideoFPSTimestamp = now
		}
	}

	private static let preRenderThunk: @convention(c) (UnsafeMutableRawPointer?) -> Bool = { opaque in
		guard let opaque = opaque else { return true }
		let instance = Unmanaged<ParsecSDKBridge>.fromOpaque(opaque).takeUnretainedValue()
		instance.onPreRenderFrame()
		return true
	}

	// PollFrame-based renderer support
	private var pollFrameRenderingEnabled = false
	private var onVideoFrameImage: ((CGImage) -> Void)?
	private var ciContext = CIContext(options: nil)
	private var pollFrameItem: DispatchWorkItem?

	private static let framePollThunk: @convention(c) (UnsafePointer<ParsecFrame>?, UnsafeRawPointer?, UnsafeMutableRawPointer?) -> Void = { framePtr, imagePtr, opaque in
		guard let opaque = opaque, let framePtr = framePtr, let imagePtr = imagePtr else { return }
		let instance = Unmanaged<ParsecSDKBridge>.fromOpaque(opaque).takeUnretainedValue()
		instance.handlePolledFrame(frame: framePtr.pointee, imagePtr: imagePtr)
	}

	private func handlePolledFrame(frame: ParsecFrame, imagePtr: UnsafeRawPointer) {
		// Update FPS counter
		onPreRenderFrame()
		guard let consumer = onVideoFrameImage else { return }
		guard let cg = convertFrameToCGImage(frame: frame, imagePtr: imagePtr) else { return }
		DispatchQueue.main.async {
			consumer(cg)
		}
	}

	private func convertFrameToCGImage(frame: ParsecFrame, imagePtr: UnsafeRawPointer) -> CGImage? {
		let width = Int(frame.width)
		let height = Int(frame.height)
		switch frame.format {
		case FORMAT_BGRA:
			let bytesPerRow = Int(frame.fullWidth) * 4
			let colorSpace = CGColorSpaceCreateDeviceRGB()
			let bitmapInfo = CGBitmapInfo.byteOrder32Little.union(CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue))
			guard let provider = CGDataProvider(dataInfo: nil, data: imagePtr, size: Int(frame.size), releaseData: {_,_,_ in }) else { return nil }
			return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: bytesPerRow, space: colorSpace, bitmapInfo: bitmapInfo, provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
		case FORMAT_RGBA:
			let bytesPerRow = Int(frame.fullWidth) * 4
			let colorSpace = CGColorSpaceCreateDeviceRGB()
			let bitmapInfo = CGBitmapInfo.byteOrder32Big.union(CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue))
			guard let provider = CGDataProvider(dataInfo: nil, data: imagePtr, size: Int(frame.size), releaseData: {_,_,_ in }) else { return nil }
			return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: bytesPerRow, space: colorSpace, bitmapInfo: bitmapInfo, provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
		case FORMAT_NV12:
			let yStride = Int(frame.fullWidth)
			let uvStride = Int(frame.fullWidth)
			let ySize = yStride * Int(frame.fullHeight)
			let uvSize = yStride * Int(frame.fullHeight) / 2
			var pixelBuffer: CVPixelBuffer?
			let planeBaseAddresses: [UnsafeMutablePointer<UInt8>?] = [UnsafeMutablePointer<UInt8>(mutating: imagePtr.assumingMemoryBound(to: UInt8.self)),
				UnsafeMutablePointer<UInt8>(mutating: imagePtr.advanced(by: ySize).assumingMemoryBound(to: UInt8.self))]
			let planeWidths = [Int(frame.fullWidth), Int(frame.fullWidth)]
			let planeHeights = [Int(frame.fullHeight), Int(frame.fullHeight) / 2]
			let planeBytesPerRow = [yStride, uvStride]
			let status = CVPixelBufferCreateWithPlanarBytes(nil, Int(frame.fullWidth), Int(frame.fullHeight), kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, nil, ySize + uvSize, 2, planeBaseAddresses, planeWidths, planeHeights, planeBytesPerRow, nil, nil, nil, &pixelBuffer)
			if status != kCVReturnSuccess { return nil }
			guard let pb = pixelBuffer else { return nil }
			let ci = CIImage(cvPixelBuffer: pb)
			return ciContext.createCGImage(ci, from: CGRect(x: 0, y: 0, width: width, height: height))
		default:
			return nil
		}
	}

	func enablePollFrameRendering(_ consumer: @escaping (CGImage) -> Void) {
		onVideoFrameImage = consumer
		pollFrameRenderingEnabled = true
		if pollFrameItem == nil {
			let item = DispatchWorkItem { [weak self] in
				guard let self = self else { return }
				let opaque = Unmanaged.passUnretained(self).toOpaque()
				while self.backgroundTaskRunning && self.pollFrameRenderingEnabled {
					_ = ParsecClientPollFrame(self._parsec, UInt8(DEFAULT_STREAM), ParsecSDKBridge.framePollThunk, 16, opaque)
				}
			}
			pollFrameItem = item
			DispatchQueue.global().async(execute: item)
		}
	}
	
	init() {
		print("Parsec SDK Version: " + String(ParsecSDKBridge.PARSEC_VER))
		
		ParsecSetLogCallback(
			{ (level, msg, opaque) in
				print("[\(level == LOG_DEBUG ? "D" : "I")] \(String(cString:msg!))")
			}, nil)
		
		audio_init(&_audio)
		
		self._audioPtr = UnsafeRawPointer(_audio)
		
		do {
			let reservedCfg = ["ssHost": "kessel-ws.parsec.app"]
			let json = JSONEncoder()
			try json.encode(reservedCfg).withUnsafeBytes { (jsonStrBPtr: UnsafeRawBufferPointer) in
				guard let jsonStrPtr = jsonStrBPtr.baseAddress else {
					return
				}
				ParsecInit(ParsecSDKBridge.PARSEC_VER, nil, jsonStrPtr, &_parsec)
			}

		} catch {
			print("error: \(error)")
		}

	}
	
	deinit
	{
		
		ParsecDestroy(_parsec)
		audio_destroy(&_audio)
	}
	
	func connect(_ peerID:String) -> ParsecStatus
	{
		var parsecClientCfg = ParsecClientConfig()
		parsecClientCfg.video.0.decoderIndex = 1
		parsecClientCfg.video.0.resolutionX = 0
		parsecClientCfg.video.0.resolutionY = 0
		parsecClientCfg.video.0.decoderCompatibility = false
		parsecClientCfg.video.0.decoderH265 = true
		
		parsecClientCfg.video.1.decoderIndex = 1
		parsecClientCfg.video.1.resolutionX = 0
		parsecClientCfg.video.1.resolutionY = 0
		parsecClientCfg.video.1.decoderCompatibility = false
		parsecClientCfg.video.1.decoderH265 = true
		
		parsecClientCfg.mediaContainer = 0
		parsecClientCfg.protocol = 1
		//parsecClientCfg.secret = ""
		parsecClientCfg.pngCursor = false
		
		self.startBackgroundTask()
		
		return ParsecClientConnect(_parsec, &parsecClientCfg, NetworkHandler.clinfo?.session_id, peerID)
	}
	
	func disconnect()
	{
		audio_clear(&_audio)
		ParsecClientDisconnect(_parsec)
		backgroundTaskRunning = false
	}
	
	func getStatus() -> ParsecStatus
	{
		return ParsecClientGetStatus(_parsec, nil)
	}
	
	func getStatusEx(_ pcs:inout ParsecClientStatus) -> ParsecStatus
	{
		self.hostHeight = Float(pcs.decoder.0.height)
		self.hostWidth = Float(pcs.decoder.0.width)
		return ParsecClientGetStatus(_parsec, &pcs)
		
	}
	
	func setFrame(_ width:CGFloat, _ height:CGFloat, _ scale:CGFloat)
	{
		ParsecClientSetDimensions(_parsec, UInt8(DEFAULT_STREAM), UInt32(width), UInt32(height), Float(scale))
		
		clientWidth = Float(width)
		clientHeight = Float(height)
		mouseInfo.mouseX = Int32(width / 2)
		mouseInfo.mouseY = Int32(height / 2)
	}
	
	func renderGLFrame(timeout:UInt32 = 16) // timeout in ms, 16 == 60 FPS, 8 == 120 FPS, etc.
	{
		let opaque = Unmanaged.passUnretained(self).toOpaque()
		ParsecClientGLRenderFrame(_parsec, UInt8(DEFAULT_STREAM), ParsecSDKBridge.preRenderThunk, opaque, timeout)
	}
	
	/*static func renderMetalFrame(_ queue:inout MTLCommandQueue, _ texturePtr:UnsafeMutablePointer<UnsafeMutableRawPointer?>, timeout:UInt32 = 16) // timeout in ms, 16 == 60 FPS, 8 == 120 FPS, etc.
	 {
	 ParsecClientMetalRenderFrame(_parsec, UInt8(DEFAULT_STREAM), &queue, texturePtr, nil, nil, timeout)
	 }*/
	
	func pollAudio(timeout:UInt32 = 16) // timeout in ms, 16 == 60 FPS, 8 == 120 FPS, etc.
	{
		ParsecClientPollAudio(_parsec, audio_cb, timeout, _audioPtr)
	}
	
	var getFirstCursor = false
	var mousePositionRelative = false
	
	func pollEvent(timeout:UInt32 = 16) // timeout in ms, 16 == 60 FPS, 8 == 120 FPS, etc.
	{
		var e: ParsecClientEvent!
		var _event = ParsecClientEvent()
		var pollSuccess = false;
		withUnsafeMutablePointer(to: &_event, {(_eventPtr) in
			pollSuccess = ParsecClientPollEvents(_parsec, timeout, _eventPtr)
			e = _eventPtr.pointee
		})
		if !pollSuccess {
			return
		}
		if e.type == CLIENT_EVENT_CURSOR {
			handleCursorEvent(event: e.cursor)
		} else if e.type == CLIENT_EVENT_USER_DATA {
			handleUserDataEvent(event: e.userData)
		}
	}
	
	func handleUserDataEvent(event: ParsecClientUserDataEvent) {
		let pointer = ParsecGetBuffer(_parsec, event.key)
		switch event.id {
		case 11:
			do {
				let decoder = JSONDecoder()
				let config = try decoder.decode(ParsecUserDataVideoConfig.self, from: Data(bytesNoCopy: pointer!, count: strlen(pointer!), deallocator: .none))
				let videoConfig = config.video[0]
				DataManager.model.resolutionX = videoConfig.resolutionX
				DataManager.model.resolutionY = videoConfig.resolutionY
				DataManager.model.bitrate = videoConfig.encoderMaxBitrate
				DataManager.model.constantFps = videoConfig.fullFPS
				if !didSetResolution {
					didSetResolution = true
					DispatchQueue.main.async {
						DataManager.model.resolutionX = SettingsHandler.resolution.width
						DataManager.model.resolutionY = SettingsHandler.resolution.height
						self.updateHostVideoConfig()
					}
				}
				
			} catch {
				print("error while parsing user data: \(error.localizedDescription)")
			}
		case 12:
			do {
				let decoder = JSONDecoder()
				let config = try decoder.decode(Array<ParsecDisplayConfig>.self, from: Data(bytesNoCopy: pointer!, count: strlen(pointer!), deallocator: .none))
				DataManager.model.displayConfigs = config
			} catch {
				print("error while parsing user data: \(error.localizedDescription)")
			}
		default:
			break
		}
		ParsecFree(pointer)
	}
	
	func handleCursorEvent(event: ParsecClientCursorEvent) {
		let prevHidden = mouseInfo.cursorHidden
		mouseInfo.cursorHidden = event.cursor.hidden
		mouseInfo.mousePositionRelative = event.cursor.relative
		
		if event.cursor.imageUpdate || !getFirstCursor{
			getFirstCursor = true
			let imgKey = event.key
			let pointer = ParsecGetBuffer(_parsec, imgKey)
			if pointer == nil{
				return
			}
			let size = event.cursor.size
			let width = event.cursor.width
			let height = event.cursor.height
			mouseInfo.cursorWidth = Int(width)
			mouseInfo.cursorHeight = Int(height)
			// 之前隐藏现在不隐藏了就更新
			if prevHidden && !event.cursor.hidden {
				mouseInfo.mouseX = Int32(event.cursor.positionX)
				mouseInfo.mouseY = Int32(event.cursor.positionY)
			}
			
			mouseInfo.cursorHotX = Int(event.cursor.hotX)
			mouseInfo.cursorHotY = Int(event.cursor.hotY)
			
			let elmentLength: Int = 4
			let render: CGColorRenderingIntent = CGColorRenderingIntent.defaultIntent
			let rgbColorSpace = CGColorSpaceCreateDeviceRGB()
			let bitmapInfo: CGBitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue)
			let providerRef: CGDataProvider? = CGDataProvider(data: NSData(bytes: pointer, length: Int(size)))
			let cgimage: CGImage? = CGImage(width: Int(width), height: Int(height), bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: Int(width) * elmentLength, space: rgbColorSpace, bitmapInfo: bitmapInfo, provider: providerRef!, decode: nil, shouldInterpolate: true, intent: render)
			if cgimage != nil {
				mouseInfo.cursorImg = cgimage
			}
			ParsecFree(pointer)
		}
	}
	
	func setMuted(_ muted:Bool)
	{
		audio_mute(muted, _audioPtr)
	}
	
	func applyConfig()
	{
		var parsecClientCfg = ParsecClientConfig()
		
		parsecClientCfg.video.0.decoderIndex = 1
		parsecClientCfg.video.0.resolutionX = 0
		parsecClientCfg.video.0.resolutionY = 0
		parsecClientCfg.video.0.decoderCompatibility = false
		parsecClientCfg.video.0.decoderH265 = SettingsHandler.decoder == .h265
		
		parsecClientCfg.video.1.decoderIndex = 1
		parsecClientCfg.video.1.resolutionX = 0
		parsecClientCfg.video.1.resolutionY = 0
		parsecClientCfg.video.1.decoderCompatibility = false
		parsecClientCfg.video.1.decoderH265 = SettingsHandler.decoder == .h265
		
		parsecClientCfg.mediaContainer = mediaContainer
		parsecClientCfg.protocol = netProtocol
		//parsecClientCfg.secret = ""
		parsecClientCfg.pngCursor = pngCursor
		
		ParsecClientSetConfig(_parsec, &parsecClientCfg);
	}
	
	func sendMouseMessage(_ button:ParsecMouseButton, _ x:Int32, _ y:Int32, _ pressed:Bool)
	{
		// Send the mouse position
		sendMousePosition(x, y)
		
		// Send the mouse button state
		var buttonMessage = ParsecMessage()
		buttonMessage.type = MESSAGE_MOUSE_BUTTON
		buttonMessage.mouseButton.button = button
		buttonMessage.mouseButton.pressed = pressed
		ParsecClientSendMessage(_parsec, &buttonMessage)
	}
	
	func sendMouseClickMessage(_ button:ParsecMouseButton, _ pressed:Bool) {
		var buttonMessage = ParsecMessage()
		buttonMessage.type = MESSAGE_MOUSE_BUTTON
		buttonMessage.mouseButton.button = button
		buttonMessage.mouseButton.pressed = pressed
		ParsecClientSendMessage(_parsec, &buttonMessage)
	}
	
	func sendMouseDelta(_ dx: Int32, _ dy: Int32) {
		if mouseInfo.mousePositionRelative {
			sendMouseRelativeMove(dx, dy)
		} else {
			sendMousePosition(mouseInfo.mouseX + dx, mouseInfo.mouseY + dy)
		}
		
	}
	static func clamp<T>(_ value: T, minValue: T, maxValue: T) -> T where T : Comparable {
		return min(max(value, minValue), maxValue)
	}
	
	func sendMousePosition(_ x:Int32, _ y:Int32)
	{
		mouseInfo.mouseX = ParsecSDKBridge.clamp(x, minValue: 0, maxValue: Int32(self.clientWidth))
		mouseInfo.mouseY = ParsecSDKBridge.clamp(y, minValue: 0, maxValue: Int32(self.clientHeight))
		var motionMessage = ParsecMessage()
		motionMessage.type = MESSAGE_MOUSE_MOTION
		motionMessage.mouseMotion.x = x
		motionMessage.mouseMotion.y = y
		ParsecClientSendMessage(_parsec, &motionMessage)
	}
	
	func sendMouseRelativeMove(_ dx:Int32, _ dy:Int32)
	{
		var motionMessage = ParsecMessage()
		motionMessage.type = MESSAGE_MOUSE_MOTION
		motionMessage.mouseMotion.x = dx
		motionMessage.mouseMotion.y = dy
		motionMessage.mouseMotion.relative = true
		ParsecClientSendMessage(_parsec, &motionMessage)
	}
	
	func getKeyCodeByText(text: String) -> (ParsecKeycode?, Bool) {
		var keyCode : ParsecKeycode?
		var useShift = false
		if text.count == 1 {
			let char = Character(text)
			if char.isLetter || char.isNumber {
				keyCode = KeyCodeTranslators.parsecKeyCodeTranslator(text.uppercased())
				if char.isUppercase {
					useShift = true
				}
			} else if char.isNewline {
				keyCode = ParsecKeycode(40)
			} else if char.isWhitespace{
				keyCode = ParsecKeycode(44)
			} else {
				let (keycodeRaw, keyMod) = KeyCodeTranslators.getParsecKeycode(for: text)
				if keycodeRaw != -1 {
					keyCode = ParsecKeycode(UInt32(keycodeRaw))
					if keyMod {
						useShift = true
					}
				}
			}
		} else {
			keyCode = KeyCodeTranslators.parsecKeyCodeTranslator(text)
		}
		
		return (keyCode, useShift)
	}
	
	func sendVirtualKeyboardInput(text: String) {
		let (keyCode, useShift) = getKeyCodeByText(text: text)
		
		guard let keyCode else {
			return
		}
		var keyboardMessagePress = ParsecMessage()
		keyboardMessagePress.type = MESSAGE_KEYBOARD
		keyboardMessagePress.keyboard.pressed = true
		if !isVirtualShiftOn && useShift {
			keyboardMessagePress.keyboard.code = ParsecKeycode(rawValue: 225)
			ParsecClientSendMessage(_parsec, &keyboardMessagePress)
		}
		keyboardMessagePress.keyboard.code = keyCode
		ParsecClientSendMessage(_parsec, &keyboardMessagePress)
		
		// add release delay in case some games ignore instant key release
		DispatchQueue.global().asyncAfter(deadline: .now() + 0.02) {
			keyboardMessagePress.keyboard.pressed = false
			if !self.isVirtualShiftOn && useShift {
				keyboardMessagePress.keyboard.code = ParsecKeycode(rawValue: 225)
				ParsecClientSendMessage(self._parsec, &keyboardMessagePress)
				keyboardMessagePress.keyboard.code = keyCode
			}
			ParsecClientSendMessage(self._parsec, &keyboardMessagePress)
		}
	}
	
	func sendVirtualKeyboardInput(text: String, isOn: Bool) {
		let (keyCode, _) = getKeyCodeByText(text: text)
		
		guard let keyCode else {
			return
		}
		
		if keyCode.rawValue == 225 {
			isVirtualShiftOn = isOn
		}
		
		var keyboardMessagePress = ParsecMessage()
		keyboardMessagePress.type = MESSAGE_KEYBOARD
		keyboardMessagePress.keyboard.pressed = isOn
		keyboardMessagePress.keyboard.code = keyCode
		ParsecClientSendMessage(_parsec, &keyboardMessagePress)
		
	}

	func sendKeyboardMessage(event:KeyBoardKeyEvent)
	{
		if event.input == nil {
			return
		}
		
		var keyboardMessagePress = ParsecMessage()
		keyboardMessagePress.type = MESSAGE_KEYBOARD
		keyboardMessagePress.keyboard.code = ParsecKeycode(UInt32(KeyCodeTranslators.uiKeyCodeToInt(key: event.input?.keyCode ?? UIKeyboardHIDUsage.keyboardErrorUndefined)))
		keyboardMessagePress.keyboard.pressed = event.isPressBegin
		ParsecClientSendMessage(_parsec, &keyboardMessagePress)
	}
	
	func sendGameControllerButtonMessage(controllerId:UInt32, _ button:ParsecGamepadButton, pressed:Bool)
	{
		var pmsg = ParsecMessage()
		pmsg.type = MESSAGE_GAMEPAD_BUTTON
		pmsg.gamepadButton.id = controllerId
		pmsg.gamepadButton.button = button
		pmsg.gamepadButton.pressed = pressed
		ParsecClientSendMessage(_parsec, &pmsg)
	}
	
	/*static func sendGameControllerTriggerButtonMessage(controllerId:UInt32, _ button:ParsecGamepadAxis, pressed:Bool)
	{
	    var pmsg = ParsecMessage()
		pmsg.type = MESSAGE_GAMEPAD_AXIS
		pmsg.gamepadAxis.id = controllerId
		pmsg.gamepadAxis.button = button
		pmsg.gamepadAxis.pressed = pressed
		ParsecClientSendMessage(_parsec, &pmsg)
	}*/
	
	func sendGameControllerAxisMessage(controllerId:UInt32, _ button:ParsecGamepadAxis, _ value: Int16)
	{
	    var pmsg = ParsecMessage()
		pmsg.type = MESSAGE_GAMEPAD_AXIS
		pmsg.gamepadAxis.id = controllerId
		pmsg.gamepadAxis.axis = button
		pmsg.gamepadAxis.value = value
		ParsecClientSendMessage(_parsec, &pmsg)
	}
	
	func sendGameControllerUnplugMessage(controllerId:UInt32)
	{
	    var pmsg = ParsecMessage()
		pmsg.type = MESSAGE_GAMEPAD_UNPLUG;
		pmsg.gamepadUnplug.id = controllerId;
		ParsecClientSendMessage(_parsec, &pmsg)
	}
	
	func sendWheelMsg(x: Int32, y: Int32) {
		var pmsg = ParsecMessage()
		pmsg.type = MESSAGE_MOUSE_WHEEL;
		pmsg.mouseWheel.x = x
		pmsg.mouseWheel.y = y
		ParsecClientSendMessage(_parsec, &pmsg)
	}
	
	func startBackgroundTask(){
	
		
		let item1 = DispatchWorkItem {
			while self.backgroundTaskRunning {
				self.pollAudio()
			}
			
		}

		let item2 = DispatchWorkItem {
			while self.backgroundTaskRunning {
				self.pollEvent()
	
				
			}
			
		}
		let mainQueue = DispatchQueue.global()
		mainQueue.async(execute: item1)
		mainQueue.async(execute: item2)
		// NOTE: Polling frames into system memory while also using GL render harms performance; rely on pre-render callback instead
	}
	
	func sendUserData(type: ParsecUserDataType, message: Data) {
		message.withUnsafeBytes { ptr in
			let ptr2 = ptr.baseAddress?.assumingMemoryBound(to: CChar.self)
			ParsecClientSendUserData(_parsec, type.rawValue, ptr2)
		}
	}
	
	func updateHostVideoConfig() {
		var videoConfig = ParsecUserDataVideoConfig()
		videoConfig.video[0].resolutionX = DataManager.model.resolutionX
		videoConfig.video[0].resolutionY = DataManager.model.resolutionY
		videoConfig.video[0].encoderMaxBitrate = DataManager.model.bitrate
		videoConfig.video[0].fullFPS = DataManager.model.constantFps
		videoConfig.video[0].output = DataManager.model.output
		let encoder = JSONEncoder()
		let data = try! encoder.encode(videoConfig)
		CParsec.sendUserData(type: .setVideoConfig, message: data)
	}
}
