//
//  LupedSmartwatchManager+UI.swift
//  LupedSmartwatchKitUI
//
//  Copyright © 2026 LoopKit Authors. All rights reserved.
//

import LoopKit
import LoopKitUI
import LupedSmartwatchKit
import SwiftUI
import UIKit

extension LupedSmartwatchManager: @retroactive SmartwatchManagerUI {
    public static var onboardingImage: UIImage? {
        PebbleArtwork.image
    }

    public var smallImage: UIImage? {
        PebbleArtwork.image
    }

    /// The Pebble app pairs the watch, and the watchface finds Loop once Loop
    /// publishes the Bluetooth service, so setup only explains what is needed,
    /// adds the watch, and confirms that a reading reached it.
    @MainActor
    public static func setupViewController(bluetoothProvider: BluetoothProvider, displayGlucosePreference: DisplayGlucosePreference, colorPalette: LoopUIColorPalette, allowDebugFeatures: Bool) -> SetupUIResult<SmartwatchManagerViewController, SmartwatchManagerUI> {
        .userInteractionRequired(LupedSetupNavigationController())
    }

    @MainActor
    public func settingsViewController(bluetoothProvider: BluetoothProvider, displayGlucosePreference: DisplayGlucosePreference, colorPalette: LoopUIColorPalette, allowDebugFeatures: Bool) -> SmartwatchManagerViewController {
        LupedSettingsNavigationController(manager: self)
    }

}

/// A drawn Pebble (steel case, black bezel, one left and three right
/// buttons, strap ends) showing a plain clock, used wherever Loop shows the
/// device. Drawn rather than bundled so no product artwork ships with Loop.
enum PebbleArtwork {
    static let image: UIImage = draw(size: CGSize(width: 120, height: 160))

    static func draw(size: CGSize) -> UIImage {
        let format = UIGraphicsImageRendererFormat()
        format.opaque = false
        return UIGraphicsImageRenderer(size: size, format: format).image { context in
            let cg = context.cgContext
            let w = size.width, h = size.height

            func roundedRect(_ rect: CGRect, _ radius: CGFloat, fill: UIColor) {
                fill.setFill()
                UIBezierPath(roundedRect: rect, cornerRadius: radius).fill()
            }

            // Strap ends above and below the case, with a lighter edge so they
            // still show on a dark background.
            let strap = UIColor(white: 0.17, alpha: 1)
            let strapEdge = UIColor(white: 0.42, alpha: 1)
            for rect in [CGRect(x: w * 0.25, y: 0, width: w * 0.5, height: h * 0.3), CGRect(x: w * 0.25, y: h * 0.7, width: w * 0.5, height: h * 0.3)] {
                roundedRect(rect, w * 0.06, fill: strap)
                strapEdge.setStroke()
                let edge = UIBezierPath(roundedRect: rect.insetBy(dx: 0.75, dy: 0.75), cornerRadius: w * 0.06)
                edge.lineWidth = 1.5
                edge.stroke()
            }

            // Buttons: back on the left, up/select/down on the right.
            let button = UIColor(white: 0.62, alpha: 1)
            roundedRect(CGRect(x: w * 0.06, y: h * 0.42, width: w * 0.06, height: h * 0.1), w * 0.02, fill: button)
            for y in [0.33, 0.45, 0.57] {
                roundedRect(CGRect(x: w * 0.88, y: h * y, width: w * 0.06, height: h * 0.1), w * 0.02, fill: button)
            }

            // Steel case with a vertical sheen.
            let caseRect = CGRect(x: w * 0.1, y: h * 0.16, width: w * 0.8, height: h * 0.68)
            let casePath = UIBezierPath(roundedRect: caseRect, cornerRadius: w * 0.13)
            cg.saveGState()
            casePath.addClip()
            let steel = [UIColor(white: 0.86, alpha: 1).cgColor, UIColor(white: 0.6, alpha: 1).cgColor, UIColor(white: 0.8, alpha: 1).cgColor]
            if let gradient = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: steel as CFArray, locations: [0, 0.55, 1]) {
                cg.drawLinearGradient(gradient, start: CGPoint(x: caseRect.minX, y: caseRect.minY), end: CGPoint(x: caseRect.maxX, y: caseRect.maxY), options: [])
            }
            cg.restoreGState()

            // Colored accent between the steel and the bezel, then the bezel.
            let accentRect = caseRect.insetBy(dx: w * 0.035, dy: w * 0.035)
            roundedRect(accentRect, w * 0.1, fill: UIColor(red: 0.78, green: 0.16, blue: 0.18, alpha: 1))
            let bezelRect = accentRect.insetBy(dx: w * 0.012, dy: w * 0.012)
            roundedRect(bezelRect, w * 0.09, fill: UIColor(white: 0.08, alpha: 1))

            // Reflective display (200 × 228) with a plain clock.
            let screenWidth = bezelRect.width * 0.8
            let screenHeight = screenWidth * 228 / 200
            let screenRect = CGRect(x: bezelRect.midX - screenWidth / 2, y: bezelRect.midY - screenHeight / 2, width: screenWidth, height: screenHeight)
            roundedRect(screenRect, w * 0.02, fill: UIColor(red: 0.86, green: 0.87, blue: 0.84, alpha: 1))
            let clock = NSAttributedString(string: "10:09", attributes: [
                .font: UIFont.monospacedDigitSystemFont(ofSize: screenHeight * 0.28, weight: .bold),
                .foregroundColor: UIColor(white: 0.1, alpha: 1),
            ])
            let clockSize = clock.size()
            clock.draw(at: CGPoint(x: screenRect.midX - clockSize.width / 2, y: screenRect.midY - clockSize.height / 2))
        }
    }
}

/// Hosts the Pebble settings screens.
final class LupedSettingsNavigationController: UINavigationController, SmartwatchManagerOnboarding, CompletionNotifying {
    weak var smartwatchManagerOnboardingDelegate: SmartwatchManagerOnboardingDelegate?
    weak var completionDelegate: CompletionDelegate?

    init(manager: LupedSmartwatchManager) {
        super.init(nibName: nil, bundle: nil)
        let model = LupedSettingsModel(manager: manager)
        let view = LupedWatchSettingsView(model: model) { [weak self] in
            guard let self else { return }
            self.completionDelegate?.completionNotifyingDidComplete(self)
        }
        setViewControllers([UIHostingController(rootView: view)], animated: false)
        navigationBar.prefersLargeTitles = true
    }

    required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}
