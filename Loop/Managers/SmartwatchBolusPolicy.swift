//
//  SmartwatchBolusPolicy.swift
//  Loop
//
//  Copyright © 2026 LoopKit Authors. All rights reserved.
//

import Foundation
import LoopKit

/// Decides whether a bolus requested from a watch plugin may be delivered.
///
/// The plugin authenticates the request; this policy is Loop's own check and
/// does not trust the plugin's numbers. It rejects requests that are not
/// explicitly allowed, are old or made against an older state, exceed the
/// maximum bolus or the current recommendation, or come too often. A forced
/// request skips only the recommendation check.
struct SmartwatchBolusPolicy {
    /// A request older than this, measured from when the user confirmed it on the watch, is rejected.
    static let maximumRequestAge: TimeInterval = 30
    /// Allowed clock skew for requests dated in the future.
    static let maximumClockSkew: TimeInterval = 5
    /// A context older than this is rejected even if its token matches.
    static let maximumContextAge: TimeInterval = 15 * 60
    /// Minimum time between watch boluses.
    static let minimumInterval: TimeInterval = 15 * 60
    /// Watch boluses in a rolling 24 hours may total at most this many maximum boluses.
    static let dailyLimitInMaximumBoluses: Double = 2
    /// Tolerance for comparing rounded volumes.
    private static let tolerance = 0.0001

    struct Delivery: Equatable {
        let date: Date
        let units: Double
    }

    /// Watch boluses are off unless the user turned them on and the plugin offers them.
    var isAllowed: Bool
    /// The context Loop last sent to the watch.
    var currentContext: SmartwatchBolusContext?
    /// Watch boluses delivered recently, for the rate limits.
    var recentDeliveries: [Delivery]
    /// Rounds to a volume the pump supports.
    var roundToSupportedVolume: (Double) -> Double

    /// The units to deliver, rounded to a supported volume, or why not.
    func evaluate(_ request: SmartwatchBolusRequest, now: Date) -> Result<Double, SmartwatchBolusError> {
        guard isAllowed else {
            return .failure(.notAllowed)
        }
        guard request.units.isFinite, request.units > 0 else {
            return .failure(.invalidAmount)
        }
        let age = now.timeIntervalSince(request.requestedAt)
        guard age <= Self.maximumRequestAge, age >= -Self.maximumClockSkew else {
            return .failure(.expiredRequest)
        }
        guard let context = currentContext,
              context.token == request.contextToken,
              now.timeIntervalSince(context.issuedAt) <= Self.maximumContextAge
        else {
            return .failure(.staleContext)
        }

        let units = roundToSupportedVolume(request.units)
        guard units > 0 else {
            return .failure(.invalidAmount)
        }
        guard let maximumBolus = context.maximumBolus, units <= maximumBolus + Self.tolerance else {
            return .failure(.exceedsMaximumBolus)
        }
        // The watch may bolus up to the recommendation Loop showed it, rounded the
        // same way; never more, and nothing when Loop recommends no bolus. A
        // forced request skips this check only.
        if !request.isForced {
            guard let recommended = context.recommendedBolus,
                  units <= roundToSupportedVolume(recommended) + Self.tolerance
            else {
                return .failure(.exceedsRecommendation)
            }
        }

        if let last = recentDeliveries.map(\.date).max(), now.timeIntervalSince(last) < Self.minimumInterval {
            return .failure(.rateLimited)
        }
        let dayStart = now.addingTimeInterval(-24 * 60 * 60)
        let deliveredToday = recentDeliveries.filter { $0.date > dayStart }.reduce(0) { $0 + $1.units }
        guard deliveredToday + units <= maximumBolus * Self.dailyLimitInMaximumBoluses + Self.tolerance else {
            return .failure(.dailyLimitReached)
        }
        return .success(units)
    }
}

extension UserDefaults {
    /// Whether boluses requested from a watch plugin may be delivered. Off by default.
    static let allowWatchBolusKey = "com.loopkit.Loop.allowWatchBolus"
    private static let watchBolusDeliveriesKey = "com.loopkit.Loop.watchBolusDeliveries"

    var allowWatchBolus: Bool {
        get { bool(forKey: Self.allowWatchBolusKey) }
        set { set(newValue, forKey: Self.allowWatchBolusKey) }
    }

    /// Whether a watch plugin with `.remoteCarbs` may add carb entries. Off by default.
    static let allowWatchCarbsKey = "com.loopkit.Loop.allowWatchCarbs"
    private static let lastWatchCarbEntryKey = "com.loopkit.Loop.lastWatchCarbEntry"

    var allowWatchCarbs: Bool {
        get { bool(forKey: Self.allowWatchCarbsKey) }
        set { set(newValue, forKey: Self.allowWatchCarbsKey) }
    }

    /// When the last carb entry from the watch was added, for its rate limit.
    var lastWatchCarbEntry: Date? {
        get { object(forKey: Self.lastWatchCarbEntryKey) as? Date }
        set { set(newValue, forKey: Self.lastWatchCarbEntryKey) }
    }

    /// Whether a watch plugin with `.remoteMute` may mute Loop's alerts. Off by default.
    static let allowWatchMuteKey = "com.loopkit.Loop.allowWatchMute"

    var allowWatchMute: Bool {
        get { bool(forKey: Self.allowWatchMuteKey) }
        set { set(newValue, forKey: Self.allowWatchMuteKey) }
    }

    /// Whether a watch plugin with `.remoteOverride` may start and end override presets. Off by default.
    static let allowWatchOverridesKey = "com.loopkit.Loop.allowWatchOverrides"

    var allowWatchOverrides: Bool {
        get { bool(forKey: Self.allowWatchOverridesKey) }
        set { set(newValue, forKey: Self.allowWatchOverridesKey) }
    }

    /// Turns off every Watch Permissions toggle. Called when the watch plugin is
    /// removed or replaced, so a new plugin never inherits what the user granted
    /// another one. The rate-limit history is kept.
    func resetWatchPermissions() {
        allowWatchBolus = false
        allowWatchCarbs = false
        allowWatchMute = false
        allowWatchOverrides = false
    }

    /// Watch boluses delivered in the last 24 hours, kept across launches for the rate limits.
    var watchBolusDeliveries: [SmartwatchBolusPolicy.Delivery] {
        get {
            (array(forKey: Self.watchBolusDeliveriesKey) as? [[String: Any]] ?? []).compactMap { entry in
                guard let date = entry["date"] as? Date, let units = entry["units"] as? Double else {
                    return nil
                }
                return SmartwatchBolusPolicy.Delivery(date: date, units: units)
            }
        }
        set {
            let dayStart = Date().addingTimeInterval(-24 * 60 * 60)
            set(newValue.filter { $0.date > dayStart }.map { ["date": $0.date, "units": $0.units] }, forKey: Self.watchBolusDeliveriesKey)
        }
    }
}
