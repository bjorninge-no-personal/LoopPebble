//
//  SmartwatchManagerHost.swift
//  Loop
//
//  Copyright © 2026 LoopKit Authors. All rights reserved.
//

import Foundation
import LoopAlgorithm
import LoopKit

/// Sends Loop's state to the watch plugin in Settings → Devices.
///
/// A new glucose reading is sent as soon as the glucose store saves it, before
/// the loop runs; the snapshot is sent again when the loop's output changes.
/// Unchanged snapshots are not resent.
///
/// For plugins that declare `.bolus`, it also issues the bolus context and
/// decides on bolus requests with `SmartwatchBolusPolicy`. Watch boluses stay off
/// unless the build sets `WATCH_BOLUS_ENABLED` and the user allows them.
@MainActor
final class SmartwatchManagerHost {
    private unowned let deviceManager: DeviceDataManager
    private unowned let loopDataManager: LoopDataManager
    private unowned let settingsManager: SettingsManager
    private let glucoseStore: GlucoseStore
    private let deliverBolus: (Double) async throws -> Void

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
        deliverBolus: @escaping (Double) async throws -> Void
    ) {
        self.deviceManager = deviceManager
        self.loopDataManager = loopDataManager
        self.settingsManager = settingsManager
        self.glucoseStore = glucoseStore
        self.deliverBolus = deliverBolus

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
        let capabilities = type(of: smartwatchManager).capabilities

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

    private func makeSnapshot(capabilities: SmartwatchCapabilities) async throws -> SmartwatchStatusSnapshot {
        let historyStart = Date().addingTimeInterval(-SmartwatchStatusSnapshot.historyInterval)
        let samples = try await glucoseStore.getGlucoseSamples(start: historyStart)

        let readings = samples.map(SmartwatchGlucoseReading.init)
        var snapshot = SmartwatchStatusSnapshot(
            displayUnit: deviceManager.displayGlucosePreference.unit == .millimolesPerLiter ? .millimolesPerLiter : .milligramsPerDeciliter,
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
        if capabilities.contains(.bolus) {
            snapshot.bolusContext = await currentBolusContext(latestGlucoseDate: samples.last?.startDate)
        }
        return snapshot
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
        logBolus(manager, type: .receive, String(format: "Bolus request: %.3f U, confirmed at %@, context %@", request.units, String(describing: request.requestedAt), request.contextToken.uuidString))

        let policy = SmartwatchBolusPolicy(
            isAllowed: FeatureFlags.watchBolusEnabled && UserDefaults.standard.allowWatchBolus && isCurrentWatch && type(of: manager).capabilities.contains(.bolus),
            currentContext: bolusContext,
            recentDeliveries: UserDefaults.standard.watchBolusDeliveries,
            roundToSupportedVolume: { [deviceManager] units in
                deviceManager.pumpManager?.roundToSupportedBolusVolume(units: units) ?? units
            }
        )
        let units: Double
        switch policy.evaluate(request, now: Date()) {
        case .failure(let error):
            logBolus(manager, type: .error, "Bolus request rejected: \(error)")
            throw error
        case .success(let allowed):
            units = allowed
        }

        // Spend the context so the same request cannot deliver twice.
        bolusContext = nil
        bolusContextBasis = nil
        logBolus(manager, type: .delegate, String(format: "Delivering watch bolus of %.3f U", units))
        do {
            try await deliverBolus(units)
        } catch {
            logBolus(manager, type: .error, "Watch bolus delivery failed: \(error)")
            refresh()
            throw SmartwatchBolusError.deliveryFailed(String(describing: error))
        }
        UserDefaults.standard.watchBolusDeliveries += [SmartwatchBolusPolicy.Delivery(date: Date(), units: units)]
        logBolus(manager, type: .delegateResponse, String(format: "Watch bolus of %.3f U delivered", units))
        refresh()
        return units
    }

    private func logBolus(_ manager: SmartwatchManager, type: DeviceLogEntryType, _ message: String) {
        deviceManager.deviceLog.log(managerIdentifier: manager.pluginIdentifier, deviceIdentifier: nil, type: type, message: message, completion: nil)
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
