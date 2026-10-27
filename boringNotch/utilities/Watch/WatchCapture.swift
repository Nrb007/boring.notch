// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint
//
// Ported from Vorssaint (https://github.com/vorssaint/vorssaint-utils): the parts of
// ScreenshotCaptureEngine.swift, WindowPreviewProvider.swift, SwitcherSupport.swift,
// ScreenTextService.swift and QuickToolsSupport.swift that Watch reads through.
// Adapted for boring.notch: ScreenCaptureKit only (Vorssaint's private window-server capture
// is left out), and recognition reads English with automatic language detection.

import AppKit
import ScreenCaptureKit
import Vision

/// What the window server knows about one window right now.
struct WatchWindowInfo: Sendable {
    let id: CGWindowID
    /// Global top-left coordinates, in points.
    let bounds: CGRect
    let appName: String
    let processID: pid_t?
    let title: String?
    let onScreen: Bool
}

enum WatchCapture {
    /// The display that holds a capture `crop`: its own pixels, set up once.
    final class RegionCapture: @unchecked Sendable {
        private let filter: SCContentFilter
        private let configuration: SCStreamConfiguration

        init(filter: SCContentFilter, configuration: SCStreamConfiguration) {
            self.filter = filter
            self.configuration = configuration
        }

        func image() async -> CGImage? {
            try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
        }
    }

    static func windowInfo(_ windowID: CGWindowID) -> WatchWindowInfo? {
        guard let list = CGWindowListCopyWindowInfo([.optionIncludingWindow], windowID) as? [[String: Any]],
              let entry = list.first(where: {
                  ($0[kCGWindowNumber as String] as? NSNumber)?.uint32Value == windowID
              }),
              let boundsDict = entry[kCGWindowBounds as String] as? NSDictionary,
              let bounds = CGRect(dictionaryRepresentation: boundsDict),
              bounds.width > 0, bounds.height > 0 else { return nil }
        let pid = entry[kCGWindowOwnerPID as String] as? pid_t
        let app = pid.flatMap { NSRunningApplication(processIdentifier: $0)?.localizedName }
            ?? entry[kCGWindowOwnerName as String] as? String ?? ""
        let title = (entry[kCGWindowName as String] as? String).flatMap { $0.isEmpty ? nil : $0 }
        return WatchWindowInfo(id: windowID, bounds: bounds, appName: app, processID: pid, title: title,
                               onScreen: entry[kCGWindowIsOnscreen as String] as? Bool ?? false)
    }

    /// On-screen windows of other apps a click or a drag can pick, front to back, in the window
    /// server's global top-left coordinates. Ordinary layer-zero windows only, so a menu or the
    /// Dock is never picked, and never this app's own windows, the notch among them.
    static func pickableWindows() -> [(id: CGWindowID, bounds: CGRect)] {
        guard let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements],
                                                    kCGNullWindowID) as? [[String: Any]] else { return [] }
        let ownPID = ProcessInfo.processInfo.processIdentifier
        return info.compactMap { entry in
            guard let layer = entry[kCGWindowLayer as String] as? Int, layer == 0,
                  let pid = entry[kCGWindowOwnerPID as String] as? Int32, pid != ownPID,
                  let id = (entry[kCGWindowNumber as String] as? NSNumber)?.uint32Value,
                  let boundsDict = entry[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict),
                  bounds.width >= 40, bounds.height >= 40 else { return nil }
            if let alpha = entry[kCGWindowAlpha as String] as? Double, alpha <= 0.01 { return nil }
            return (id: id, bounds: bounds)
        }
    }

    /// The window drawn on its own by ScreenCaptureKit, whole wherever it sits, even covered.
    static func captureWindow(_ windowID: CGWindowID, scale: CGFloat) async -> CGImage? {
        guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true),
              let window = content.windows.first(where: { $0.windowID == windowID }) else { return nil }
        let configuration = SCStreamConfiguration()
        configuration.width = max(1, Int((window.frame.width * scale).rounded()))
        configuration.height = max(1, Int((window.frame.height * scale).rounded()))
        configuration.captureResolution = .best
        configuration.showsCursor = false
        configuration.colorSpaceName = CGColorSpace.sRGB
        let filter = SCContentFilter(desktopIndependentWindow: window)
        return try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
    }

    /// A fixed part of a display, `pointRect` in points from its top-left corner, with this
    /// app's windows left out so the notch never reads itself opening and closing as a change.
    static func prepareDisplayRegion(displayID: CGDirectDisplayID, pointRect: CGRect,
                                     scale: CGFloat) async -> RegionCapture? {
        guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true),
              let display = content.displays.first(where: { $0.displayID == displayID }) else { return nil }
        let bounds = CGRect(x: 0, y: 0, width: CGFloat(display.width), height: CGFloat(display.height))
        let clamped = pointRect.intersection(bounds)
        guard !clamped.isNull, clamped.width >= 4, clamped.height >= 4 else { return nil }
        let ownPID = ProcessInfo.processInfo.processIdentifier
        let own = content.windows.filter { $0.owningApplication?.processID == ownPID }
        let filter = SCContentFilter(display: display, excludingWindows: own)
        let configuration = SCStreamConfiguration()
        configuration.sourceRect = clamped
        configuration.width = max(1, Int((clamped.width * scale).rounded()))
        configuration.height = max(1, Int((clamped.height * scale).rounded()))
        configuration.showsCursor = false
        configuration.colorSpaceName = CGColorSpace.sRGB
        return RegionCapture(filter: filter, configuration: configuration)
    }

    /// A capture that is not the whole window, as some system windows return a strip of
    /// themselves, would put the crop over other pixels.
    static func coversWindow(_ image: CGImage, size: CGSize, tolerance: Double = 0.08) -> Bool {
        guard size.width > 1, size.height > 1 else { return true }
        let horizontal = Double(image.width) / Double(size.width)
        let vertical = Double(image.height) / Double(size.height)
        guard horizontal > 0, vertical > 0 else { return true }
        return max(horizontal, vertical) / min(horizontal, vertical) <= 1 + tolerance
    }

    /// Recognition is slower on big areas and no more accurate past a few hundred pixels, so a
    /// large area is read at a smaller size.
    static func scaledForRecognition(_ image: CGImage) -> CGImage? {
        let longest = max(image.width, image.height)
        guard longest > NotchWatchSupport.maximumRecognitionSide else { return nil }
        let scale = CGFloat(NotchWatchSupport.maximumRecognitionSide) / CGFloat(longest)
        let width = max(1, Int(CGFloat(image.width) * scale))
        let height = max(1, Int(CGFloat(image.height) * scale))
        guard let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        context.interpolationQuality = .high
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        return context.makeImage()
    }

    // MARK: Text recognition

    private struct RecognizedLine {
        let text: String
        let x: CGFloat
        let y: CGFloat
    }

    /// The text in an image, read on the Mac with Vision, line by line from the top. Accurate
    /// first; the fast model is a second chance when the accurate one finds nothing.
    static func recognizeText(in image: CGImage) -> String {
        var lines = recognizedLines(in: image, level: .accurate, automaticallyDetectLanguage: true)
        if lines.isEmpty {
            lines = recognizedLines(in: image, level: .fast, automaticallyDetectLanguage: false)
        }
        return lines
            .filter { !$0.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
            .sorted {
                // Vision's y grows upward; bucket rows so tiny baseline wobbles don't shuffle
                // words of the same line.
                let rowA = (1 - $0.y) * 50
                let rowB = (1 - $1.y) * 50
                if abs(rowA - rowB) >= 0.5 { return rowA < rowB }
                return $0.x < $1.x
            }
            .map(\.text)
            .joined(separator: "\n")
    }

    private static func recognizedLines(in image: CGImage, level: VNRequestTextRecognitionLevel,
                                        automaticallyDetectLanguage: Bool) -> [RecognizedLine] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = level
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = automaticallyDetectLanguage
        let preferred = Locale.preferredLanguages.prefix(2) + ["en-US"]
        if let supported = try? request.supportedRecognitionLanguages() {
            let available = preferred.filter { supported.contains($0) }
            if !available.isEmpty { request.recognitionLanguages = Array(available) }
        }
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        guard (try? handler.perform([request])) != nil else { return [] }
        return (request.results ?? []).compactMap { observation in
            guard let candidate = observation.topCandidates(1).first else { return nil }
            return RecognizedLine(text: candidate.string, x: observation.boundingBox.minX,
                                  y: observation.boundingBox.midY)
        }
    }
}

extension NSScreen {
    /// The CoreGraphics display id behind this screen; 0 when missing.
    var watchDisplayID: CGDirectDisplayID {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }
}
