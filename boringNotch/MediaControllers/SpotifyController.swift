//
//  SpotifyController.swift
//  boringNotch
//
//  Created by Alexander on 2025-03-29.
//

import Foundation
import Combine
import SwiftUI

class SpotifyController: MediaControllerProtocol {
    func setFavorite(_ favorite: Bool) async {
        //Placeholder
    }
    
    // MARK: - Properties
    @Published private var playbackState: PlaybackState = PlaybackState(
        bundleIdentifier: "com.spotify.client"
    )
    
    var playbackStatePublisher: AnyPublisher<PlaybackState, Never> {
        $playbackState.eraseToAnyPublisher()
    }

    var supportsVolumeControl: Bool {
        return true
    }

    var supportsFavorite: Bool { false }

    private var notificationTask: Task<Void, Never>?
    private var pollingTask: Task<Void, Never>?

    // Spotify doesn't notify on seeks or buffering stalls, so re-sync periodically while playing
    private let pollingInterval: Duration = .seconds(2)

    // Refreshes run concurrently; IDs let us drop results that finish after a newer one was applied
    @MainActor private var nextUpdateID = 0
    @MainActor private var lastAppliedUpdateID = -1
    
    // Constant for time between command and update
    private let commandUpdateDelay: Duration = .milliseconds(25)

    private var lastArtworkURL: String?

    // Spotify's AppleScript only exposes an on/off `repeating` flag, so repeat-one is emulated:
    // Spotify stays on repeat-all and we seek back to the start just before the track ends.
    @MainActor private var repeatOneEnabled = false
    private var repeatOneTask: Task<Void, Never>?
    private let repeatOneLeadTime: Double = 0.5
    @MainActor private var currentArtworkURL: String?
    @MainActor private var fetchingArtworkURL: String?
    private var artworkFetchTask: Task<Void, Never>?
    
    init() {
        setupPlaybackStateChangeObserver()
        setupPolling()
        Task {
            if isActive() {
                await updatePlaybackInfo()
            }
        }
    }
    
    private func setupPlaybackStateChangeObserver() {
        notificationTask = Task { @Sendable [weak self] in
            let notifications = DistributedNotificationCenter.default().notifications(
                named: NSNotification.Name("com.spotify.client.PlaybackStateChanged")
            )
            
            for await _ in notifications {
                await self?.updatePlaybackInfo()
            }
        }
    }
    
    private func setupPolling() {
        let interval = pollingInterval
        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard let self else { return }
                if self.isActive() && self.playbackState.isPlaying {
                    await self.updatePlaybackInfo()
                }
            }
        }
    }
    
    deinit {
        notificationTask?.cancel()
        pollingTask?.cancel()
        repeatOneTask?.cancel()
        artworkFetchTask?.cancel()
    }
    
    // MARK: - Protocol Implementation
    func play() async { await executeCommand("play") }
    func pause() async { await executeCommand("pause") }
    func togglePlay() async { await executeCommand("playpause") }
    func nextTrack() async { await executeCommand("next track") }
    func previousTrack() async {
        await executeAndRefresh("previous track")
    }
    
    func seek(to time: Double) async {
        await executeAndRefresh("set player position to \(time)")
    }
    
    func toggleShuffle() async {
        await executeAndRefresh("set shuffling to not shuffling")
    }
    
    func toggleRepeat() async {
        // Cycle off -> all -> one -> off
        let current = await MainActor.run { playbackState.repeatMode }
        switch current {
        case .off:
            await executeCommand("set repeating to true")
        case .all:
            await MainActor.run { repeatOneEnabled = true }
        case .one:
            await MainActor.run { repeatOneEnabled = false }
            await executeCommand("set repeating to false")
        }
        try? await Task.sleep(for: commandUpdateDelay)
        await updatePlaybackInfo()
    }
    
    func setVolume(_ level: Double) async {
        let clampedLevel = max(0.0, min(1.0, level))
        let volumePercentage = Int(clampedLevel * 100)
        await executeCommand("set sound volume to \(volumePercentage)")
        try? await Task.sleep(for: commandUpdateDelay)
        await updatePlaybackInfo()
    }
    
    func isActive() -> Bool {
        NSWorkspace.shared.runningApplications.contains { $0.bundleIdentifier == playbackState.bundleIdentifier }
    }
    
    func updatePlaybackInfo() async {
        let updateID = await MainActor.run { () -> Int in
            defer { nextUpdateID += 1 }
            return nextUpdateID
        }
        guard let descriptor = try? await fetchPlaybackInfoAsync() else { return }
        guard descriptor.numberOfItems >= 10 else { return }
        
        let isPlaying = descriptor.atIndex(1)?.booleanValue ?? false
        let currentTrack = descriptor.atIndex(2)?.stringValue ?? "Unknown"
        let currentTrackArtist = descriptor.atIndex(3)?.stringValue ?? "Unknown"
        let currentTrackAlbum = descriptor.atIndex(4)?.stringValue ?? "Unknown"
        let currentTime = descriptor.atIndex(5)?.doubleValue ?? 0
        let duration = (descriptor.atIndex(6)?.doubleValue ?? 0)/1000
        let isShuffled = descriptor.atIndex(7)?.booleanValue ?? false
        let isRepeating = descriptor.atIndex(8)?.booleanValue ?? false
        let volumePercentage = descriptor.atIndex(9)?.int32Value ?? 50
        let artworkURL = descriptor.atIndex(10)?.stringValue ?? ""
        
        let state = PlaybackState(
            bundleIdentifier: "com.spotify.client",
            isPlaying: isPlaying,
            title: currentTrack,
            artist: currentTrackArtist,
            album: currentTrackAlbum,
            currentTime: currentTime,
            duration: duration,
            playbackRate: 1,
            isShuffled: isShuffled,
            repeatMode: isRepeating ? .all : .off,
            lastUpdated: Date(),
            artwork: nil,
            volume: Double(volumePercentage) / 100.0
        )

        await MainActor.run {
            guard updateID > lastAppliedUpdateID else { return }
            lastAppliedUpdateID = updateID
            applyPlaybackState(state, artworkURL: artworkURL)
        }
    }

    @MainActor
    private func applyPlaybackState(_ newState: PlaybackState, artworkURL: String) {
        var state = newState
        // Repeat was switched off from within Spotify itself
        if repeatOneEnabled && state.repeatMode == .off {
            repeatOneEnabled = false
        }
        if repeatOneEnabled {
            state.repeatMode = .one
        }
        if artworkURL == lastArtworkURL, let existingArtwork = self.playbackState.artwork {
            state.artwork = existingArtwork
        }

        playbackState = state
        currentArtworkURL = artworkURL
        scheduleRepeatOneLoop(for: state)

        guard !artworkURL.isEmpty, let url = URL(string: artworkURL) else { return }
        guard artworkURL != lastArtworkURL || state.artwork == nil else { return }
        // Polling can land mid-download; don't restart a fetch for the same artwork
        guard artworkURL != fetchingArtworkURL else { return }
        artworkFetchTask?.cancel()
        fetchingArtworkURL = artworkURL

        artworkFetchTask = Task {
            do {
                let data = try await ImageService.shared.fetchImageData(from: url)

                await MainActor.run { [weak self] in
                    guard let self = self, self.fetchingArtworkURL == artworkURL else { return }
                    self.artworkFetchTask = nil
                    self.fetchingArtworkURL = nil
                    // Only attach artwork to the latest state, and only if the track hasn't changed since
                    guard self.currentArtworkURL == artworkURL else { return }
                    var updatedState = self.playbackState
                    updatedState.artwork = data
                    self.playbackState = updatedState
                    self.lastArtworkURL = artworkURL
                }
            } catch {
                await MainActor.run { [weak self] in
                    guard let self = self, self.fetchingArtworkURL == artworkURL else { return }
                    self.artworkFetchTask = nil
                    self.fetchingArtworkURL = nil
                }
            }
        }
    }
    
    @MainActor
    private func scheduleRepeatOneLoop(for state: PlaybackState) {
        repeatOneTask?.cancel()
        guard repeatOneEnabled, state.isPlaying, state.duration > 0 else { return }

        let remaining = state.duration - state.currentTime - repeatOneLeadTime
        let title = state.title
        let artist = state.artist
        repeatOneTask = Task { [weak self] in
            if remaining > 0 {
                try? await Task.sleep(for: .seconds(remaining))
            }
            guard !Task.isCancelled, let self else { return }
            let stillOnTrack = await MainActor.run {
                self.repeatOneEnabled && self.playbackState.title == title && self.playbackState.artist == artist
            }
            guard stillOnTrack else { return }
            await self.executeAndRefresh("set player position to 0")
        }
    }

// MARK: - Private Methods
    
    private func executeCommand(_ command: String) async {
        let script = "tell application \"Spotify\" to \(command)"
        try? await AppleScriptHelper.executeVoid(script)
    }

    private func executeAndRefresh(_ command: String) async {
        await executeCommand(command)
        try? await Task.sleep(for: commandUpdateDelay)
        await updatePlaybackInfo()
    }
    
    private func fetchPlaybackInfoAsync() async throws -> NSAppleEventDescriptor? {
        let script = """
        tell application "Spotify"
            set isRunning to true
            try
                set playerState to player state is playing
                set currentTrackName to name of current track
                set currentTrackArtist to artist of current track
                set currentTrackAlbum to album of current track
                set trackPosition to player position
                set trackDuration to duration of current track
                set shuffleState to shuffling
                set repeatState to repeating
                set currentVolume to sound volume
                set artworkURL to artwork url of current track
                return {playerState, currentTrackName, currentTrackArtist, currentTrackAlbum, trackPosition, trackDuration, shuffleState, repeatState, currentVolume, artworkURL}
            on error
                return {false, "Unknown", "Unknown", "Unknown", 0, 0, false, false, 50, ""}
            end try
        end tell
        """
        
        return try await AppleScriptHelper.execute(script)
    }
    
}
