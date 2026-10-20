//
//  WatchManagerHost.swift
//  Loop
//
//  Copyright © 2026 LoopKit Authors. All rights reserved.
//

import Combine
import Foundation
import LoopAlgorithm
import LoopKit

/// Sends Loop's state to the watch plugin in Settings → Devices.
///
/// A new glucose reading is sent as soon as the glucose store saves it, before
/// the loop runs; the snapshot is sent again when the loop's output changes.
/// Unchanged snapshots and alert states are not resent.
@MainActor
final class WatchManagerHost {
    private unowned let deviceManager: DeviceDataManager
    private unowned let loopDataManager: LoopDataManager
    private unowned let settingsManager: SettingsManager
    private let glucoseStore: GlucoseStore
    private let glucoseAlertManager: GlucoseAlertManager
    private let alertMuter: AlertMuter

    private let log = DiagnosticLog(category: "WatchManagerHost")

    private var lastSentSnapshot: WatchStatusSnapshot?
    private var lastSentAlertState: WatchGlucoseAlertState?
    /// Incremented per update so a slower glucose fetch cannot overwrite a newer snapshot.
    private var updateGeneration = 0
    private var notificationObservers: [Any] = []
    private var cancellables: Set<AnyCancellable> = []

    init(
        deviceManager: DeviceDataManager,
        loopDataManager: LoopDataManager,
        settingsManager: SettingsManager,
        glucoseStore: GlucoseStore,
        glucoseAlertManager: GlucoseAlertManager,
        alertMuter: AlertMuter
    ) {
        self.deviceManager = deviceManager
        self.loopDataManager = loopDataManager
        self.settingsManager = settingsManager
        self.glucoseStore = glucoseStore
        self.glucoseAlertManager = glucoseAlertManager
        self.alertMuter = alertMuter

        notificationObservers = [
            // Posted as soon as new samples are saved, before LoopDataManager
            // recomputes its display state for them.
            NotificationCenter.default.addObserver(forName: GlucoseStore.glucoseSamplesDidChange, object: glucoseStore, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.update() }
            },
            NotificationCenter.default.addObserver(forName: .LoopDataUpdated, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.update() }
            },
            NotificationCenter.default.addObserver(forName: .LoopCycleCompleted, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.update() }
            },
            NotificationCenter.default.addObserver(forName: .WatchManagerChanged, object: deviceManager, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            },
        ]

        // These publish before the new value is stored; the debounce reads it afterwards.
        Publishers.Merge5(
            glucoseAlertManager.$profiles.map { _ in () },
            glucoseAlertManager.$activeProfileID.map { _ in () },
            glucoseAlertManager.$cgmProvidesOwnAlerts.map { _ in () },
            glucoseAlertManager.$loopAlertsOverrideForOwnAlertingCGM.map { _ in () },
            alertMuter.$configuration.map { _ in () }
        )
        .dropFirst(5)
        .debounce(for: .milliseconds(500), scheduler: RunLoop.main)
        .sink { [weak self] in self?.sendAlertStateIfNeeded() }
        .store(in: &cancellables)
    }

    /// Sends the current snapshot and alert state even if unchanged, for a new
    /// watch manager or one that reconnected.
    func refresh() {
        lastSentSnapshot = nil
        lastSentAlertState = nil
        update()
    }

    private func update() {
        guard let watchManager = deviceManager.watchManager else {
            return
        }
        updateGeneration += 1
        let generation = updateGeneration
        let capabilities = type(of: watchManager).capabilities

        sendAlertStateIfNeeded()

        Task {
            let snapshot: WatchStatusSnapshot
            do {
                snapshot = try await makeSnapshot(capabilities: capabilities)
            } catch {
                log.error("Unable to read glucose for the watch: %{public}@", String(describing: error))
                return
            }
            guard generation == updateGeneration,
                  let current = deviceManager.watchManager, (current as AnyObject) === (watchManager as AnyObject),
                  snapshot != lastSentSnapshot
            else {
                return
            }
            lastSentSnapshot = snapshot
            current.watchDataDidUpdate(snapshot)
        }
    }

    private func makeSnapshot(capabilities: WatchCapabilities) async throws -> WatchStatusSnapshot {
        let historyStart = Date().addingTimeInterval(-WatchStatusSnapshot.historyInterval)
        let samples = try await glucoseStore.getGlucoseSamples(start: historyStart)

        var snapshot = WatchStatusSnapshot(
            displayUnit: deviceManager.displayGlucosePreference.unit,
            glucose: samples.last,
            glucoseHistory: capabilities.contains(.history) ? samples : []
        )
        if capabilities.contains(.prediction) {
            snapshot.predictedGlucose = loopDataManager.displayState.output?.predictedGlucose
        }
        if capabilities.contains(.loopStatus) {
            snapshot.insulinOnBoard = loopDataManager.activeInsulin?.value
            snapshot.carbsOnBoard = loopDataManager.activeCarbs?.quantity.doubleValue(for: .gram)
            snapshot.lastLoopCompleted = loopDataManager.lastLoopCompleted
            snapshot.isClosedLoop = settingsManager.loopSettings.dosingEnabled
        }
        return snapshot
    }

    private func sendAlertStateIfNeeded() {
        guard let watchManager = deviceManager.watchManager,
              type(of: watchManager).capabilities.contains(.alerts)
        else {
            return
        }
        let state = alertState()
        guard state != lastSentAlertState else {
            return
        }
        lastSentAlertState = state
        watchManager.glucoseAlertStateDidUpdate(state)
    }

    /// Loop's active glucose alert profile and alert mute. Low and high alerts
    /// repeat only when their snooze is enabled; urgent low always repeats.
    private func alertState() -> WatchGlucoseAlertState {
        let configuration = glucoseAlertManager.activeConfiguration()
        return WatchGlucoseAlertState(
            configuration: WatchGlucoseAlertState.Configuration(
                urgentLowThreshold: configuration.urgentLowThresholdMgDL,
                lowThreshold: configuration.lowThresholdMgDL,
                highThreshold: configuration.highThresholdMgDL,
                urgentLowEnabled: configuration.urgentLowEnabled,
                lowEnabled: configuration.lowEnabled,
                highEnabled: configuration.highEnabled,
                urgentLowRepeatInterval: configuration.urgentLowRepeatInterval,
                lowRepeatInterval: configuration.lowSnoozeEnabled ? configuration.lowRepeatInterval : nil,
                highRepeatInterval: configuration.highSnoozeEnabled ? configuration.highRepeatInterval : nil
            ),
            loopAlertsActive: glucoseAlertManager.effectiveLoopAlertsEnabled,
            mutedUntil: alertMuter.configuration.shouldMute ? alertMuter.configuration.mutingEndTime : nil
        )
    }
}
