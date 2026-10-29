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

    private let log = DiagnosticLog(category: "SmartwatchManagerHost")

    private var lastSentSnapshot: SmartwatchStatusSnapshot?
    /// The bolus context last sent, and what it was computed from.
    private var bolusContext: SmartwatchBolusContext?
    private var bolusContextBasis: BolusContextBasis?
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
        deliverCarbs: @escaping (Double) async throws -> Void
    ) {
        self.deviceManager = deviceManager
        self.loopDataManager = loopDataManager
        self.settingsManager = settingsManager
        self.glucoseStore = glucoseStore
        self.healthStore = healthStore
        self.deliverBolus = deliverBolus
        self.alertMuter = alertMuter
        self.deliverCarbs = deliverCarbs

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

    // MARK: - Watch bolus

    /// What a bolus context is computed from; a new token is issued when it changes.
    private struct BolusContextBasis: Equatable {
        let recommendedBolus: Double?
        let maximumBolus: Double?
        let supportedBolusVolumes: [Double]
        let latestGlucoseDate: Date?
    }

    private func currentBolusContext(latestGlucoseDate: Date?) async -> SmartwatchBolusContext {
        let recommendation = try? await loopDataManager.recommendManualBolus()
        let basis = BolusContextBasis(
            recommendedBolus: recommendation.flatMap { $0.amount > 0 ? $0.amount : nil },
            maximumBolus: settingsManager.loopSettings.maximumBolus,
            supportedBolusVolumes: deviceManager.pumpManager?.supportedBolusVolumes ?? [],
            latestGlucoseDate: latestGlucoseDate
        )
        if let bolusContext, basis == bolusContextBasis {
            return bolusContext
        }
        let context = SmartwatchBolusContext(
            token: UUID(),
            issuedAt: Date(),
            recommendedBolus: basis.recommendedBolus,
            maximumBolus: basis.maximumBolus,
            supportedBolusVolumes: basis.supportedBolusVolumes
        )
        bolusContext = context
        bolusContextBasis = basis
        return context
    }

    /// Delivers a bolus the plugin authenticated, if `SmartwatchBolusPolicy` allows it.
    /// Every request and its outcome goes to the device log.
    func handleBolusRequest(_ request: SmartwatchBolusRequest, from manager: SmartwatchManager) async throws -> Double {
        let isCurrentWatch = deviceManager.smartwatchManager.map { ($0 as AnyObject) === (manager as AnyObject) } ?? false
        logWatchRequest(manager, type: .receive, String(format: "%@ request: %.3f U, confirmed at %@, context %@", request.isForced ? "Forced bolus (recommendation not checked)" : "Bolus", request.units, String(describing: request.requestedAt), request.contextToken.uuidString))

        let policy = SmartwatchBolusPolicy(
            isAllowed: UserDefaults.standard.allowWatchBolus && isCurrentWatch && manager.effectiveCapabilities.contains(.remoteBolus),
            currentContext: bolusContext,
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
            logWatchRequest(manager, type: .error, "Bolus request rejected: \(error) (\(error == .notAllowed ? notAllowedReason : "")requested \(units(request.units)), Loop recommends \(units(bolusContext?.recommendedBolus ?? 0)), maximum bolus \(units(bolusContext?.maximumBolus)))")
            throw error
        case .success(let allowed):
            units = allowed
        }

        // Spend the context so the same request cannot deliver twice.
        bolusContext = nil
        bolusContextBasis = nil
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

    /// Minimum time between carb entries from the watch.
    static let minimumWatchCarbInterval: TimeInterval = 15 * 60

    /// Adds a carb entry the watch asked for, through the same path as remote
    /// carbs (notification, upload). Only while Allow Carbs from Watch is on, and
    /// at most one every 15 minutes.
    func handleCarbEntryRequest(_ grams: Double, from manager: SmartwatchManager) async throws -> Double {
        let isCurrentWatch = deviceManager.smartwatchManager.map { ($0 as AnyObject) === (manager as AnyObject) } ?? false
        logWatchRequest(manager, type: .receive, String(format: "Carb entry request: %.0f g", grams))
        let refusal: String? = if !isCurrentWatch {
            "the request isn't from the current watch"
        } else if !manager.effectiveCapabilities.contains(.remoteCarbs) {
            "this watch can't add carbs (remoteCarbs not declared or not requested)"
        } else if !UserDefaults.standard.allowWatchCarbs {
            "Allow Carbs from Watch is off"
        } else {
            nil
        }
        if let refusal {
            logWatchRequest(manager, type: .error, "Carb entry request rejected: notAllowed (\(refusal))")
            throw SmartwatchCarbEntryError.notAllowed
        }
        if let last = UserDefaults.standard.lastWatchCarbEntry, Date().timeIntervalSince(last) < Self.minimumWatchCarbInterval {
            logWatchRequest(manager, type: .error, String(format: "Carb entry request rejected: rateLimited (last one %.0f min ago, minimum %.0f min)", Date().timeIntervalSince(last) / 60, Self.minimumWatchCarbInterval / 60))
            throw SmartwatchCarbEntryError.rateLimited
        }
        guard grams.isFinite, grams > 0 else {
            logWatchRequest(manager, type: .error, "Carb entry request rejected: invalid amount")
            throw SmartwatchCarbEntryError.failed("invalid amount")
        }
        do {
            try await deliverCarbs(grams)
        } catch {
            logWatchRequest(manager, type: .error, "Watch carb entry failed: \(error)")
            throw SmartwatchCarbEntryError.failed(String(describing: error))
        }
        UserDefaults.standard.lastWatchCarbEntry = Date()
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
