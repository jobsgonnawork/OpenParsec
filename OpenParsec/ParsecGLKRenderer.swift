import GLKit
import ParsecSDK

class ParsecGLKRenderer:NSObject, GLKViewDelegate, GLKViewControllerDelegate
{
	var glkView:GLKView
	var glkViewController:GLKViewController
	
	var lastWidth:CGFloat = 1.0

	private var frameCount:Int = 0
	private var lastFPSTimestamp:CFTimeInterval = CACurrentMediaTime()

	var lastImg: CGImage?
	let updateImage: () -> Void
	
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
		if SettingsHandler.usePollFrameRenderer {
			return
		}
		let deltaWidth: CGFloat = view.frame.size.width - lastWidth
		if deltaWidth > 0.1 || deltaWidth < -0.1
		{
		    CParsec.setFrame(view.frame.size.width, view.frame.size.height, view.contentScaleFactor)
	        lastWidth = view.frame.size.width
		}
		CParsec.renderGLFrame(timeout:16)
		
		// FPS calculation based on actual draw callbacks
		frameCount += 1
		let now = CACurrentMediaTime()
		let elapsed = now - lastFPSTimestamp
		if elapsed >= 1.0 {
			let fps = Double(frameCount) / elapsed
			DispatchQueue.main.async {
				DataManager.model.fps = fps
			}
			frameCount = 0
			lastFPSTimestamp = now
		}
		
		updateImage()
		

//		glFinish()
		//glFlush()
	}

	func glkViewControllerUpdate(_ controller:GLKViewController) { }
}
