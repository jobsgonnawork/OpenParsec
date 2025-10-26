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
		CParsec.renderGLFrame(timeout: timeoutMs)
		
		updateImage()

        // FPS measurement: update once per 0.5s for stability (only when enabled)
        if CParsec.fpsMeterEnabled {
            frameCounter += 1
            let now = CACurrentMediaTime()
            let elapsed = now - lastFpsTimestamp
            if elapsed >= 0.5 {
                CParsec.displayedFps = Double(frameCounter) / elapsed
                frameCounter = 0
                lastFpsTimestamp = now
            }
        }
		

//		glFinish()
		//glFlush()
	}

	func glkViewControllerUpdate(_ controller:GLKViewController) { }
}
