//
//  SmartwatchManagerHost.swift
//  Loop
//
//  Copyright © 2026 LoopKit Authors. All rights reserved.
//

import Foundation
import HealthKit
import LoopAlgorithm
import LoopKit

/// Sends Loop's state to the watch plugin in Settings → Devices.
///
/// A new glucose reading is sent as soon as the glucose store saves it, before
/// the loop runs; the snapshot is sent again when the loop's output changes.
/// Unchanged snapshots are not resent.
@MainActor
final class SmartwatchManagerHost {
    private unowned let deviceManager: DeviceDataManager
    private unowned let loopDataManager: LoopDataManager
    private unowned let settingsManager: SettingsManager
    private let glucoseStore: GlucoseStore
    private let healthStore: HKHealthStore

    private let log = DiagnosticLog(category: "SmartwatchManagerHost")

    private var lastSentSnapshot: SmartwatchStatusSnapshot?
    /// Incremented per update so a slower glucose fetch cannot overwrite a newer snapshot.
    private var updateGeneration = 0
    private var notificationObservers: [Any] = []

    init(
        deviceManager: DeviceDataManager,
        loopDataManager: LoopDataManager,
        settingsManager: SettingsManager,
        glucoseStore: GlucoseStore,
        healthStore: HKHealthStore
    ) {
        self.deviceManager = deviceManager
        self.loopDataManager = loopDataManager
        self.settingsManager = settingsManager
        self.glucoseStore = glucoseStore
        self.healthStore = healthStore

        notificationObservers = [
            // Posted as soon as new samples are saved, before LoopDataManager
            // recomputes its display state for them.
            NotificationCenter.default.addObserver(forName: GlucoseStore.glucoseSamplesDidChange, object: glucoseStore, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.update() }
            },
            NotificationCenter.default.addObserver(forName: .LoopDataUpdated, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.update() }
            },
            NotificationCenter.default.addObserver(forName: .HealthStorePreferredGlucoseUnitDidChange, object: healthStore, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.update() }
            },
            NotificationCenter.default.addObserver(forName: .LoopCycleCompleted, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.update() }
            },
            NotificationCenter.default.addObserver(forName: .SmartwatchManagerChanged, object: deviceManager, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            },
        ]
    }

    /// Sends the current snapshot even if unchanged, for a new watch manager or
    /// one that reconnected.
    func refresh() {
        lastSentSnapshot = nil
        update()
    }

    private func update() {
        guard let smartwatchManager = deviceManager.smartwatchManager else {
            return
        }
        updateGeneration += 1
        let generation = updateGeneration
        // Fill only what the watch asks for now (the user may have turned a display
        // element off), within what the plugin declares.
        let capabilities = smartwatchManager.effectiveCapabilities

        Task {
            let snapshot: SmartwatchStatusSnapshot
            do {
                snapshot = try await makeSnapshot(capabilities: capabilities)
            } catch {
                log.error("Unable to read glucose for the watch: %{public}@", String(describing: error))
                return
            }
            guard generation == updateGeneration,
                  let current = deviceManager.smartwatchManager, (current as AnyObject) === (smartwatchManager as AnyObject),
                  snapshot != lastSentSnapshot
            else {
                return
            }
            lastSentSnapshot = snapshot
            current.watchDataDidUpdate(snapshot)
        }
    }

    /// The glucose unit from HealthKit's stored preference, which is what Loop's own
    /// display settles on. Loop's in-memory preference starts at mg/dL until
    /// HealthKit's first answer arrives, so reading it at launch briefly sent mg/dL
    /// to the watch of a mmol/L user. Falls back to it when HealthKit can't answer,
    /// for example while protected data is unavailable.
    private func displayUnit() async -> SmartwatchGlucoseUnit {
        await preferredGlucoseUnit() == .millimolesPerLiter ? .millimolesPerLiter : .milligramsPerDeciliter
    }

    private func preferredGlucoseUnit() async -> LoopUnit {
        if let hkUnit = await healthStore.cachedPreferredUnits(for: .bloodGlucose) {
            return LoopUnit(from: hkUnit)
        }
        return deviceManager.displayGlucosePreference.unit
    }

    private func makeSnapshot(capabilities: SmartwatchCapabilities) async throws -> SmartwatchStatusSnapshot {
        let historyStart = Date().addingTimeInterval(-SmartwatchStatusSnapshot.historyInterval)
        let samples = try await glucoseStore.getGlucoseSamples(start: historyStart)

        let readings = samples.map(SmartwatchGlucoseReading.init)
        var snapshot = SmartwatchStatusSnapshot(
            displayUnit: await displayUnit(),
            glucose: readings.last,
            glucoseHistory: capabilities.contains(.history) ? readings : []
        )
        if capabilities.contains(.loopStatus) {
            snapshot.insulinOnBoard = loopDataManager.activeInsulin?.value
            snapshot.carbsOnBoard = loopDataManager.activeCarbs?.quantity.doubleValue(for: .gram)
            snapshot.lastLoopCompleted = loopDataManager.lastLoopCompleted
            snapshot.isClosedLoop = settingsManager.loopSettings.dosingEnabled
        }
        if capabilities.contains(.therapy) {
            snapshot.therapy = currentTherapyContext()
        }
        return snapshot
    }

    /// What the algorithm is working with now, in mg/dL, with any active preset
    /// applied.
    private func currentTherapyContext(now: Date = Date()) -> SmartwatchTherapyContext {
        let presets = loopDataManager.temporaryPresetsManager
        var tempBasalRate: Double?
        if case .tempBasal(let dose) = deviceManager.pumpManager?.status.basalDeliveryState {
            tempBasalRate = dose.unitsPerHour
        }
        let range = presets.effectiveCorrectionRangeSchedule()?.quantityRange(at: now)
        let override = presets.scheduleOverride.flatMap { $0.isActive(at: now) ? $0 : nil }
        let presetName: String? = switch override?.context {
        case .preMeal: NSLocalizedString("Pre-Meal", comment: "Name of the pre-meal preset sent to a watch")
        case .preset(let preset): preset.name
        case .activity(let activity): activity.activityType.name
        case .custom: NSLocalizedString("Custom Preset", comment: "Name of a custom preset sent to a watch")
        case nil: nil
        }
        return SmartwatchTherapyContext(
            tempBasalRate: tempBasalRate,
            scheduledBasalRate: presets.basalRateScheduleApplyingOverrideHistory?.value(at: now),
            insulinSensitivity: presets.insulinSensitivityScheduleApplyingOverrideHistory?.quantity(at: now).doubleValue(for: .milligramsPerDeciliter),
            eventualGlucose: loopDataManager.displayState.output?.predictedGlucose.last?.quantity.doubleValue(for: .milligramsPerDeciliter),
            correctionRange: range.map { $0.lowerBound.doubleValue(for: .milligramsPerDeciliter)...$0.upperBound.doubleValue(for: .milligramsPerDeciliter) },
            activePresetName: presetName,
            activePresetEnd: override?.scheduledEndDate
        )
    }

    /// Which glucose alert this is, so plugins needn't know Loop's alert identifiers.
    static func glucoseAlertType(of identifier: Alert.Identifier) -> SmartwatchGlucoseAlertType? {
        guard identifier.managerIdentifier == GlucoseAlertManager.managerIdentifier else { return nil }
        switch identifier.alertIdentifier {
        case GlucoseAlertManager.urgentLowAlertIdentifier: return .urgentLow
        case GlucoseAlertManager.lowAlertIdentifier: return .low
        case GlucoseAlertManager.highAlertIdentifier: return .high
        case GlucoseAlertManager.predictedLowAlertIdentifier: return .predictedLow
        default: return nil
        }
    }

    /// Writes an alert note to the device log.
    private func logAlert(_ manager: SmartwatchManager, _ message: String) {
        deviceManager.deviceLog.log(managerIdentifier: manager.pluginIdentifier, deviceIdentifier: nil, type: .delegate, message: message, completion: nil)
    }
}

// MARK: - AlertForwarder

extension SmartwatchManagerHost: AlertForwarder {
    /// Forwards Loop's immediate, unmuted alerts to the watch so it buzzes in step
    /// with the phone. Delayed/repeating alerts are left to the phone's notification
    /// schedule. Muted alerts are not sent: Loop's mute covers critical alerts too
    /// (they are delivered at volume 0), so the watch follows the mute for every
    /// alert. Each alert that isn't sent is logged with the reason. Only plugins
    /// that declare and request `.alerts` are fed.
    func alertManager(_ manager: AlertManager, didIssueAlert alert: Alert, muted: Bool) {
        guard let smartwatchManager = deviceManager.smartwatchManager,
              smartwatchManager.effectiveCapabilities.contains(.alerts)
        else {
            return
        }
        let content = alert.foregroundContent ?? alert.backgroundContent
        // Log why an alert doesn't reach the watch, so a watch alert level of 0
        // can be explained from the device log.
        // The watch is a glucose display, so only forward glucose alerts (from
        // GlucoseAlertManager). Pump/pod reminders, CGM sensor-expiry and other
        // system alerts stay on the phone. This also avoids a stale watch level:
        // a pod reminder is acknowledged but never retracted, so it would otherwise
        // linger in the plugin's active set forever.
        guard alert.identifier.managerIdentifier == GlucoseAlertManager.managerIdentifier else {
            logAlert(smartwatchManager, "\(content.title) not sent to the watch: only glucose alerts are forwarded")
            return
        }
        guard case .immediate = alert.trigger else {
            logAlert(smartwatchManager, "\(content.title) not sent to the watch: it is scheduled for later, and only immediate alerts are forwarded")
            return
        }
        guard !muted else {
            logAlert(smartwatchManager, "\(content.title) not sent to the watch: Loop's alerts are muted")
            return
        }
        smartwatchManager.watchAlertDidIssue(
            SmartwatchAlert(
                identifier: SmartwatchAlertIdentifier(alert.identifier.value),
                level: alert.interruptionLevel.smartwatchAlertLevel,
                title: content.title,
                body: content.body,
                issuedAt: Date(),
                glucoseAlertType: Self.glucoseAlertType(of: alert.identifier)
            )
        )
    }

    /// Retractions go to every plugin that declares `.alerts`, even one that has
    /// stopped requesting it, so an alert it was given doesn't stay active there.
    func alertManager(_ manager: AlertManager, didRetractAlertWithIdentifier identifier: Alert.Identifier) {
        guard let smartwatchManager = deviceManager.smartwatchManager,
              type(of: smartwatchManager).capabilities.contains(.alerts),
              identifier.managerIdentifier == GlucoseAlertManager.managerIdentifier
        else {
            return
        }
        smartwatchManager.watchAlertDidRetract(SmartwatchAlertIdentifier(identifier.value))
    }
}

private extension Alert.InterruptionLevel {
    var smartwatchAlertLevel: SmartwatchAlertLevel {
        switch self {
        case .active: return .informational
        case .timeSensitive: return .warning
        case .critical: return .critical
        }
    }
}

extension SmartwatchGlucoseReading {
    init(_ sample: StoredGlucoseSample) {
        self.init(
            date: sample.startDate,
            milligramsPerDeciliter: sample.quantity.doubleValue(for: .milligramsPerDeciliter),
            trend: sample.trend.flatMap { SmartwatchGlucoseTrend(rawValue: $0.rawValue) },
            trendRate: sample.trendRate?.doubleValue(for: .milligramsPerDeciliterPerMinute),
            wasUserEntered: sample.wasUserEntered,
            isDisplayOnly: sample.isDisplayOnly
        )
    }
}
