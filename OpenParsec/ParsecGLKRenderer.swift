import GLKit
import ParsecSDK

class ParsecGLKRenderer:NSObject, GLKViewDelegate, GLKViewControllerDelegate
{
	var glkView:GLKView
	var glkViewController:GLKViewController
	
	var lastWidth:CGFloat = 1.0

	var lastImg: CGImage?
	let updateImage: () -> Void
    var lastFpsTimestamp: CFTimeInterval = CACurrentMediaTime()
    var frameCounter: Int = 0
	
	init(_ view:GLKView, _ viewController:GLKViewController,_ updateImage: @escaping () -> Void)
	{
		self.updateImage = updateImage
		glkView = view
		glkViewController = viewController

		super.init()

		glkView.delegate = self
		glkViewController.delegate = self

	}

	deinit
	{
		glkView.delegate = nil
		glkViewController.delegate = nil
	}

	func glkView(_ view:GLKView, drawIn rect:CGRect)
	{
		let deltaWidth: CGFloat = view.frame.size.width - lastWidth
		if deltaWidth > 0.1 || deltaWidth < -0.1
		{
		    CParsec.setFrame(view.frame.size.width, view.frame.size.height, view.contentScaleFactor)
	        lastWidth = view.frame.size.width
		}
        // Derive timeout from the current preferred FPS (ms per frame)
		let fps = max(glkViewController.preferredFramesPerSecond, 1)
		let timeoutMs = UInt32(1000 / fps)
		let start = CACurrentMediaTime()
		CParsec.renderGLFrame(timeout: timeoutMs)
		
		updateImage()

		// FPS measurement: count only when a new frame likely arrived (returned before timeout)
        if CParsec.fpsMeterEnabled {
			let end = CACurrentMediaTime()
			let callDuration = end - start
			let expectedTimeout = Double(timeoutMs) / 1000.0
			// If the call returned significantly before the timeout, a new frame likely arrived
			if callDuration < expectedTimeout * 0.8 {
				frameCounter += 1
			}
			let windowElapsed = end - lastFpsTimestamp
			if windowElapsed >= 0.5 {
				CParsec.displayedFps = Double(frameCounter) / windowElapsed
				frameCounter = 0
				lastFpsTimestamp = end
			}
        }
		

//		glFinish()
		//glFlush()
	}

	func glkViewControllerUpdate(_ controller:GLKViewController) { }
}
