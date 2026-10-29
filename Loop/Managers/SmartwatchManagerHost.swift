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
///
/// For plugins that declare `.remoteBolus`, it also issues the bolus context and
/// decides on bolus requests with `SmartwatchBolusPolicy`. Watch boluses stay off
/// unless the user allows them in Watch Permissions.
@MainActor
final class SmartwatchManagerHost {
    private unowned let deviceManager: DeviceDataManager
    private unowned let loopDataManager: LoopDataManager
    private unowned let settingsManager: SettingsManager
    private let glucoseStore: GlucoseStore
    private let healthStore: HKHealthStore
    private let deliverBolus: (Double) async throws -> Void
    private let alertMuter: AlertMuter
    private let deliverCarbs: (Double) async throws -> Void
    private let startOverride: (String) async throws -> Void
    private let cancelOverride: () async throws -> Void

    private let log = DiagnosticLog(category: "SmartwatchManagerHost")

    private var lastSentSnapshot: SmartwatchStatusSnapshot?
    /// Hands out the bolus context and tracks the watch bolus being delivered.
    private var bolusContextIssuer = SmartwatchBolusContextIssuer()
    /// Incremented per update so a slower glucose fetch cannot overwrite a newer snapshot.
    private var updateGeneration = 0
    private var notificationObservers: [Any] = []

    init(
        deviceManager: DeviceDataManager,
        loopDataManager: LoopDataManager,
        settingsManager: SettingsManager,
        glucoseStore: GlucoseStore,
        healthStore: HKHealthStore,
        alertMuter: AlertMuter,
        deliverBolus: @escaping (Double) async throws -> Void,
        deliverCarbs: @escaping (Double) async throws -> Void,
        startOverride: @escaping (String) async throws -> Void,
        cancelOverride: @escaping () async throws -> Void
    ) {
        self.deviceManager = deviceManager
        self.loopDataManager = loopDataManager
        self.settingsManager = settingsManager
        self.glucoseStore = glucoseStore
        self.healthStore = healthStore
        self.deliverBolus = deliverBolus
        self.alertMuter = alertMuter
        self.deliverCarbs = deliverCarbs
        self.startOverride = startOverride
        self.cancelOverride = cancelOverride

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
        loggedUndeclaredRequest = []
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
        logUndeclaredRequest(smartwatchManager)

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
        if capabilities.contains(.prediction) {
            snapshot.predictedGlucose = loopDataManager.displayState.output?.predictedGlucose.map {
                SmartwatchPredictedGlucose(date: $0.startDate, milligramsPerDeciliter: $0.quantity.doubleValue(for: .milligramsPerDeciliter))
            }
        }
        if capabilities.contains(.loopStatus) {
            snapshot.insulinOnBoard = loopDataManager.activeInsulin?.value
            snapshot.carbsOnBoard = loopDataManager.activeCarbs?.quantity.doubleValue(for: .gram)
            snapshot.lastLoopCompleted = loopDataManager.lastLoopCompleted
            snapshot.isClosedLoop = settingsManager.loopSettings.dosingEnabled
        }
        if capabilities.contains(.therapy) {
            snapshot.therapy = currentTherapyContext()
        }
        if capabilities.contains(.remoteBolus) {
            snapshot.bolusContext = await currentBolusContext(latestGlucoseDate: samples.last?.startDate)
        }
        if capabilities.contains(.remoteOverride) {
            snapshot.overridePresets = currentOverridePresets()
        }
        return snapshot
    }

    /// What the algorithm is working with now, in mg/dL, with any active preset
    /// applied. Loop has no sensitivity ratio (an oref/autosens value), so that
    /// stays nil.
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

    /// Loop's presets, with the running one marked.
    private func currentOverridePresets(now: Date = Date()) -> [SmartwatchPreset] {
        let running = loopDataManager.temporaryPresetsManager.scheduleOverride.flatMap { $0.isActive(at: now) ? $0 : nil }
        let runningID: String? = if case .preset(let preset) = running?.context { preset.id } else { nil }
        return settingsManager.settings.overridePresets.map { preset in
            let duration: TimeInterval? = if case .finite(let interval) = preset.duration { interval } else { nil }
            return SmartwatchPreset(id: preset.id, name: preset.name, isActive: preset.id == runningID, duration: duration)
        }
    }

    /// Starts or ends a preset for a request from the watch, through the same path
    /// as remote overrides. Only while Allow Presets from Watch is on, and for
    /// requests confirmed in the last 30 seconds.
    func handleOverrideRequest(_ request: SmartwatchOverrideRequest, from manager: SmartwatchManager) async throws {
        let isCurrentWatch = deviceManager.smartwatchManager.map { ($0 as AnyObject) === (manager as AnyObject) } ?? false
        let preset: TemporaryPreset?
        switch request.action {
        case .activate(let presetID):
            preset = settingsManager.settings.overridePresets.first { $0.id == presetID }
            logWatchRequest(manager, type: .receive, "Preset request: start \(preset.map { "\"\($0.name)\"" } ?? presetID), confirmed at \(request.requestedAt)")
        case .cancel:
            preset = nil
            logWatchRequest(manager, type: .receive, "Preset request: end the running preset, confirmed at \(request.requestedAt)")
        }
        let refusal: String? = if !isCurrentWatch {
            "the request isn't from the current watch"
        } else if !manager.effectiveCapabilities.contains(.remoteOverride) {
            "this watch can't start presets (remoteOverride not declared or not requested)"
        } else if !UserDefaults.standard.allowWatchOverrides {
            "Allow Presets from Watch is off"
        } else {
            nil
        }
        if let refusal {
            logWatchRequest(manager, type: .error, "Preset request rejected: notAllowed (\(refusal))")
            throw SmartwatchPresetError.notAllowed
        }
        let age = Date().timeIntervalSince(request.requestedAt)
        guard SmartwatchBolusPolicy.Limits.standard.isFresh(request.requestedAt, now: Date()) else {
            logWatchRequest(manager, type: .error, String(format: "Preset request rejected: expiredRequest (confirmed %.0f s ago)", age))
            throw SmartwatchPresetError.expiredRequest
        }
        do {
            switch request.action {
            case .activate:
                guard let preset else {
                    logWatchRequest(manager, type: .error, "Preset request rejected: unknownPreset")
                    throw SmartwatchPresetError.unknownPreset
                }
                try await startOverride(preset.name)
                logWatchRequest(manager, type: .delegateResponse, "Preset \"\(preset.name)\" started from the watch")
            case .cancel:
                try await cancelOverride()
                logWatchRequest(manager, type: .delegateResponse, "Preset ended from the watch")
            }
        } catch let error as SmartwatchPresetError {
            throw error
        } catch {
            logWatchRequest(manager, type: .error, "Preset request from the watch failed: \(error)")
            throw SmartwatchPresetError.failed(String(describing: error))
        }
        refresh()
    }

    // MARK: - Watch bolus

    private func currentBolusContext(latestGlucoseDate: Date?) async -> SmartwatchBolusContext {
        let recommendation = try? await loopDataManager.recommendManualBolus()
        let inputs = SmartwatchBolusContextIssuer.Inputs(
            recommendedBolus: recommendation?.amount,
            maximumBolus: settingsManager.loopSettings.maximumBolus,
            supportedBolusVolumes: deviceManager.pumpManager?.supportedBolusVolumes ?? [],
            latestGlucoseDate: latestGlucoseDate
        )
        return bolusContextIssuer.context(for: inputs, now: Date())
    }

    /// Delivers a bolus the plugin authenticated, if `SmartwatchBolusPolicy` allows it.
    /// Every request and its outcome goes to the device log.
    func handleBolusRequest(_ request: SmartwatchBolusRequest, from manager: SmartwatchManager) async throws -> Double {
        let isCurrentWatch = deviceManager.smartwatchManager.map { ($0 as AnyObject) === (manager as AnyObject) } ?? false
        logWatchRequest(manager, type: .receive, String(format: "%@ request: %.3f U, confirmed at %@, context %@", request.isForced ? "Forced bolus (recommendation not checked)" : "Bolus", request.units, String(describing: request.requestedAt), request.contextToken.uuidString))
        if bolusContextIssuer.isDelivering(request) {
            logWatchRequest(manager, type: .error, "Bolus request answered with inProgress: the same bolus is still being delivered")
            throw SmartwatchBolusError.inProgress
        }

        let policy = SmartwatchBolusPolicy(
            isAllowed: UserDefaults.standard.allowWatchBolus && isCurrentWatch && manager.effectiveCapabilities.contains(.remoteBolus),
            currentContext: bolusContextIssuer.current,
            recentDeliveries: UserDefaults.standard.watchBolusDeliveries,
            roundToSupportedVolume: { [deviceManager] units in
                deviceManager.pumpManager?.roundToSupportedBolusVolume(units: units) ?? units
            }
        )
        let units: Double
        switch policy.evaluate(request, now: Date()) {
        case .failure(let error):
            let units = { (value: Double?) in value.map { String(format: "%.2f U", $0) } ?? "none" }
            let notAllowedReason: String = if !isCurrentWatch {
                "the request isn't from the current watch; "
            } else if !manager.effectiveCapabilities.contains(.remoteBolus) {
                "this watch can't request boluses (remoteBolus not declared or not requested); "
            } else if !UserDefaults.standard.allowWatchBolus {
                "Allow Boluses from Watch is off; "
            } else {
                ""
            }
            logWatchRequest(manager, type: .error, "Bolus request rejected: \(error) (\(error == .notAllowed ? notAllowedReason : "")requested \(units(request.units)), Loop recommends \(units(bolusContextIssuer.current?.recommendedBolus ?? 0)), maximum bolus \(units(bolusContextIssuer.current?.maximumBolus)))")
            throw error
        case .success(let allowed):
            units = allowed
        }

        bolusContextIssuer.beginDelivery(of: request)
        defer { bolusContextIssuer.endDelivery() }
        logWatchRequest(manager, type: .delegate, String(format: "Delivering watch bolus of %.3f U", units))
        do {
            try await deliverBolus(units)
        } catch {
            logWatchRequest(manager, type: .error, "Watch bolus delivery failed: \(error)")
            refresh()
            throw SmartwatchBolusError.deliveryFailed(String(describing: error))
        }
        UserDefaults.standard.watchBolusDeliveries += [SmartwatchBolusPolicy.Delivery(date: Date(), units: units)]
        logWatchRequest(manager, type: .delegateResponse, String(format: "Watch bolus of %.3f U delivered", units))
        refresh()
        return units
    }

    /// The undeclared capabilities a plugin last requested, so each set is logged once.
    private var loggedUndeclaredRequest: SmartwatchCapabilities = []

    /// A plugin can't obtain a capability it doesn't declare: hosts act only on
    /// `effectiveCapabilities`. Log when it asks for more, once per distinct set.
    private func logUndeclaredRequest(_ manager: SmartwatchManager) {
        let undeclared = manager.undeclaredRequestedCapabilities
        guard undeclared != loggedUndeclaredRequest else { return }
        loggedUndeclaredRequest = undeclared
        guard !undeclared.isEmpty else { return }
        deviceManager.deviceLog.log(managerIdentifier: manager.pluginIdentifier, deviceIdentifier: nil, type: .error, message: "The watch plugin requested capabilities it doesn't declare (\(undeclared)); they are ignored", completion: nil)
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

    /// Writes an alert note to the device log and, unless `showInPluginLog` is
    /// false, hands it to the plugin so its own log shows it next to the watch traffic.
    private func logAlert(_ manager: SmartwatchManager, _ message: String, showInPluginLog: Bool = true) {
        deviceManager.deviceLog.log(managerIdentifier: manager.pluginIdentifier, deviceIdentifier: nil, type: .delegate, message: message, completion: nil)
        if showInPluginLog {
            manager.watchHostDidLog(message)
        }
    }

    /// Mutes Loop's alerts for a request from the watch, like Mute All Alerts in
    /// Settings: the duration is one Loop offers (the shortest that covers the
    /// request), and the mute shows on the phone with its Unmute button. Only
    /// while Allow Mute from Watch is on.
    func handleAlertMuteRequest(_ duration: TimeInterval, from manager: SmartwatchManager) throws -> Date {
        let isCurrentWatch = deviceManager.smartwatchManager.map { ($0 as AnyObject) === (manager as AnyObject) } ?? false
        guard isCurrentWatch, manager.effectiveCapabilities.contains(.remoteMute) else {
            logWatchRequest(manager, type: .error, "Mute request from the watch refused: this watch can't mute alerts (remoteMute not declared or not requested)")
            throw SmartwatchAlertMuteError.notAllowed
        }
        guard UserDefaults.standard.allowWatchMute else {
            logWatchRequest(manager, type: .error, "Mute request from the watch refused: Allow Mute from Watch is off")
            throw SmartwatchAlertMuteError.notAllowed
        }
        let allowed = AlertMuter.allowedDurations
        let muteDuration = allowed.first { $0 >= duration } ?? allowed[allowed.count - 1]
        alertMuter.configuration = AlertMuter.Configuration(startTime: Date(), duration: muteDuration)
        let end = alertMuter.configuration.mutingEndTime ?? Date(timeIntervalSinceNow: muteDuration)
        logWatchRequest(manager, type: .receive, String(format: "Alerts muted from the watch for %.0f min, until %@", muteDuration / 60, String(describing: end)))
        return end
    }

    /// Adds a carb entry the watch asked for, if LoopKit's `SmartwatchCarbEntryPolicy`
    /// allows it, through the same path as remote carbs (notification, upload).
    func handleCarbEntryRequest(_ request: SmartwatchCarbEntryRequest, from manager: SmartwatchManager) async throws -> Double {
        let grams = request.grams
        let isCurrentWatch = deviceManager.smartwatchManager.map { ($0 as AnyObject) === (manager as AnyObject) } ?? false
        logWatchRequest(manager, type: .receive, String(format: "Carb entry request: %.0f g, confirmed at %@", grams, String(describing: request.requestedAt)))
        let refusal: String? = if !isCurrentWatch {
            "the request isn't from the current watch"
        } else if !manager.effectiveCapabilities.contains(.remoteCarbs) {
            "this watch can't add carbs (remoteCarbs not declared or not requested)"
        } else if !UserDefaults.standard.allowWatchCarbs {
            "Allow Carbs from Watch is off"
        } else {
            nil
        }
        let previousEntry = UserDefaults.standard.lastWatchCarbEntry
        let policy = SmartwatchCarbEntryPolicy(
            isAllowed: refusal == nil,
            maximumGrams: LoopConstants.maxCarbEntryQuantity.doubleValue(for: .gram),
            lastEntry: previousEntry
        )
        if case .failure(let error) = policy.evaluate(request, now: Date()) {
            logWatchRequest(manager, type: .error, "Carb entry request rejected: \(error)\(refusal.map { " (\($0))" } ?? "")")
            throw error
        }
        // Take the slot before storing, so a resend that arrives meanwhile is
        // rate limited instead of adding the carbs a second time.
        UserDefaults.standard.lastWatchCarbEntry = Date()
        do {
            try await deliverCarbs(grams)
        } catch {
            UserDefaults.standard.lastWatchCarbEntry = previousEntry
            logWatchRequest(manager, type: .error, "Watch carb entry failed: \(error)")
            throw SmartwatchCarbEntryError.failed(String(describing: error))
        }
        logWatchRequest(manager, type: .delegateResponse, String(format: "Watch carb entry of %.0f g added", grams))
        refresh()
        return grams
    }

    private func logWatchRequest(_ manager: SmartwatchManager, type: DeviceLogEntryType, _ message: String) {
        deviceManager.deviceLog.log(managerIdentifier: manager.pluginIdentifier, deviceIdentifier: nil, type: type, message: message, completion: nil)
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
            // Device log only: override reminders, pod alerts and the like never
            // reach the watch, so they would only clutter the watch's own log.
            logAlert(smartwatchManager, "\(content.title) not sent to the watch: only glucose alerts are forwarded", showInPluginLog: false)
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
        // Queued after the plugin's own "issued" line, which also hops to the main
        // actor. Uses the same unit as the watch snapshots (HealthKit's stored one).
        let firedAt = Date()
        Task { @MainActor in
            let unit = await self.preferredGlucoseUnit()
            if let note = self.nextAlertNote(for: alert, unit: unit, now: firedAt) {
                self.logAlert(smartwatchManager, note)
            }
        }
    }

    /// When Loop will alert again for a glucose alert it just fired, and what
    /// clears it, so the device log explains the next phone alert and watch buzz.
    /// Reads GlucoseAlertManager's active settings; the alert fired just now, so a
    /// repeat is due one repeat interval from now, on the first reading from then.
    private func nextAlertNote(for alert: Alert, unit: LoopUnit, now: Date) -> String? {
        let config = deviceManager.glucoseAlertManager.activeConfiguration(at: now)
        let title = (alert.foregroundContent ?? alert.backgroundContent).title
        let rule: (above: Bool, threshold: Double, repeatInterval: TimeInterval?)
        switch alert.identifier.alertIdentifier {
        case GlucoseAlertManager.highAlertIdentifier:
            rule = (true, config.highThresholdMgDL, config.highSnoozeEnabled ? config.highRepeatInterval : nil)
        case GlucoseAlertManager.lowAlertIdentifier:
            rule = (false, config.lowThresholdMgDL, config.lowSnoozeEnabled ? config.lowRepeatInterval : nil)
        case GlucoseAlertManager.urgentLowAlertIdentifier:
            rule = (false, config.urgentLowThresholdMgDL, config.urgentLowRepeatInterval)
        case GlucoseAlertManager.predictedLowAlertIdentifier:
            return "Next alert: \(title) doesn't repeat; it fires once per predicted low."
        default:
            return nil
        }
        let margin = config.recoveryMarginMgDL
        let level = glucoseText(rule.threshold, unit: unit)
        let clearLevel = glucoseText(rule.above ? rule.threshold - margin : rule.threshold + margin, unit: unit)
        let side = rule.above ? "above" : "below"
        let recovers = rule.above ? "falls below" : "rises above"
        guard let repeatInterval = rule.repeatInterval else {
            return "Next alert: \(title) doesn't repeat (repeat is off). It fires again only after glucose \(recovers) \(clearLevel) and then goes \(side) \(level) again."
        }
        let next = now.addingTimeInterval(repeatInterval)
        return "Next alert: if glucose is still \(side) \(level), Loop repeats \(title) and forwards it to the watch at the first reading from \(timeText(next)) (every \(intervalText(repeatInterval))). It clears once glucose \(recovers) \(clearLevel)."
    }

    private func glucoseText(_ milligramsPerDeciliter: Double, unit: LoopUnit) -> String {
        let quantity = LoopQuantity(unit: .milligramsPerDeciliter, doubleValue: milligramsPerDeciliter)
        return QuantityFormatter(for: unit).string(from: quantity) ?? "\(Int(milligramsPerDeciliter)) mg/dL"
    }

    private func timeText(_ date: Date) -> String {
        let calendar = Calendar.current
        if calendar.isDateInToday(date) {
            return DateFormatter.localizedString(from: date, dateStyle: .none, timeStyle: .short)
        }
        if calendar.isDateInTomorrow(date) {
            return DateFormatter.localizedString(from: date, dateStyle: .none, timeStyle: .short) + " tomorrow"
        }
        return DateFormatter.localizedString(from: date, dateStyle: .short, timeStyle: .short)
    }

    private func intervalText(_ interval: TimeInterval) -> String {
        let minutes = Int((interval / 60).rounded())
        guard minutes >= 60 else { return "\(minutes) min" }
        return minutes % 60 == 0 ? "\(minutes / 60) h" : "\(minutes / 60) h \(minutes % 60) min"
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
