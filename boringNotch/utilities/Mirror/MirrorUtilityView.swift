//
//  MirrorUtilityView.swift
//  boringNotch
//
//  A wide camera mirror for a quick look before a call. It uses the same camera session as the
//  Home tab's mirror, starting when the page opens and stopping when it closes.
//

import AVFoundation
import SwiftUI

struct MirrorUtilityView: View {
    @ObservedObject private var webcam = WebcamManager.shared

    var body: some View {
        VStack(spacing: 6) {
            UtilityHeader(utility: .mirror)
            ZStack {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color.white.opacity(0.06))
                if let previewLayer = webcam.previewLayer, webcam.isSessionRunning {
                    CameraPreviewLayerView(previewLayer: previewLayer)
                        .scaleEffect(x: -1, y: 1)
                        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .transition(.opacity)
                } else {
                    placeholder
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear(perform: start)
        .onDisappear { webcam.stopSession() }
    }

    @ViewBuilder
    private var placeholder: some View {
        VStack(spacing: 6) {
            switch webcam.authorizationStatus {
            case .denied, .restricted:
                Image(systemName: "exclamationmark.triangle")
                    .font(.title2)
                    .foregroundStyle(.gray)
                Text("Camera access is off")
                    .font(.subheadline)
                    .foregroundStyle(.white)
                Button("Open Privacy Settings") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Camera") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .buttonStyle(.plain)
                .font(.caption)
                .foregroundStyle(.green)
            default:
                if webcam.cameraAvailable || webcam.authorizationStatus == .notDetermined {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: "web.camera")
                        .font(.title2)
                        .foregroundStyle(.gray)
                    Text("No camera found")
                        .font(.subheadline)
                        .foregroundStyle(.gray)
                }
            }
        }
    }

    private func start() {
        switch webcam.authorizationStatus {
        case .authorized:
            if !webcam.isSessionRunning { webcam.startSession() }
        case .notDetermined:
            webcam.checkAndRequestVideoAuthorization()
        default:
            break
        }
    }
}
