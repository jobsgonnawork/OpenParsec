import ParsecSDK
import UIKit


class TouchController
{
	let viewController: UIViewController
	init(viewController: UIViewController) {
		self.viewController = viewController
	}

	private func aspectFitContentRect(in bounds: CGRect, imageSize: CGSize) -> CGRect {
		if imageSize.width <= 0 || imageSize.height <= 0 { return bounds }
		let scale = min(bounds.width / imageSize.width, bounds.height / imageSize.height)
		let w = imageSize.width * scale
		let h = imageSize.height * scale
		let x = bounds.midX - w / 2
		let y = bounds.midY - h / 2
		return CGRect(x: x, y: y, width: w, height: h)
	}

	private func mapPointToVideo(_ p: CGPoint) -> CGPoint {
		let bounds = viewController.view.bounds
		let imgSize = CGSize(width: CGFloat(CParsec.hostWidth), height: CGFloat(CParsec.hostHeight))
		let rect = aspectFitContentRect(in: bounds, imageSize: imgSize)
		let x = max(0, min(1, (p.x - rect.minX) / rect.width)) * imgSize.width
		let y = max(0, min(1, (p.y - rect.minY) / rect.height)) * imgSize.height
		return CGPoint(x: x, y: y)
	}
	
	func onTouch(typeOfTap:Int, location:CGPoint, state:UIGestureRecognizer.State)
	{
		let mapped = mapPointToVideo(location)
		let x = Int32(mapped.x)
		let y = Int32(mapped.y)

		// Send the mouse input to the host
		let parsecTap = ParsecMouseButton(rawValue:UInt32(typeOfTap))
		switch state
		{
			case .began:
				CParsec.sendMouseMessage(parsecTap, x, y, true)
			case .changed:
				CParsec.sendMousePosition(x, y)
			case .ended, .cancelled:
				CParsec.sendMouseMessage(parsecTap, x, y, false)
			default:
				break
		}
	}

	func onTap(typeOfTap:Int, location:CGPoint)
	{
		let parsecTap = ParsecMouseButton(rawValue:UInt32(typeOfTap))
		if SettingsHandler.cursorMode == .direct {
			let mapped = mapPointToVideo(location)
			let x = Int32(mapped.x)
			let y = Int32(mapped.y)

			// Send the mouse input to the host
			// add release delay in case some games ignore instant key release
			CParsec.sendMouseMessage(parsecTap, x, y, true)
			DispatchQueue.global().asyncAfter(deadline: .now() + 0.02) {
				CParsec.sendMouseMessage(parsecTap, x, y, false)
			}

		} else {
			CParsec.sendMouseClickMessage(parsecTap, true)
			DispatchQueue.global().asyncAfter(deadline: .now() + 0.02) {
				CParsec.sendMouseClickMessage(parsecTap, false)
			}
		}

	}

	public func viewDidLoad()
	{


		
	}



	
}
