import GLKit
import OpenGLES
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
    var lastSampledPixel: UInt32 = 0
	
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
        let newFrame = CParsec.renderGLFrameDetectNew(timeout: timeoutMs)
		
		updateImage()

        // FPS measurement: prefer SDK-new-frame signal; fallback to pixel sample when unavailable
        if CParsec.fpsMeterEnabled {
            var counted = false
            if newFrame {
                frameCounter += 1
                counted = true
            }
            if !counted {
                var pixel: UInt32 = 0
                let x = GLsizei(max(0, Int(view.bounds.midX)))
                let y = GLsizei(max(0, Int(view.bounds.midY)))
                glReadPixels(x, y, 1, 1, GLenum(GL_RGBA), GLenum(GL_UNSIGNED_BYTE), &pixel)
                if pixel != lastSampledPixel {
                    frameCounter += 1
                    lastSampledPixel = pixel
                }
            }
            let end = CACurrentMediaTime()
            let windowElapsed = end - lastFpsTimestamp
            if windowElapsed >= 1.0 {
                var measured = Double(frameCounter) / windowElapsed
                if DataManager.model.constantFps {
                    measured = Double(glkViewController.preferredFramesPerSecond)
                }
                measured = min(measured, Double(glkViewController.preferredFramesPerSecond))
                CParsec.displayedFps = measured
                frameCounter = 0
                lastFpsTimestamp = end
            }
        }
		

//		glFinish()
		//glFlush()
	}

	func glkViewControllerUpdate(_ controller:GLKViewController) { }
}
