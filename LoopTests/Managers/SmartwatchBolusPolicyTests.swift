//
//  SmartwatchBolusPolicyTests.swift
//  LoopTests
//
//  Copyright © 2026 LoopKit Authors. All rights reserved.
//

import XCTest
import LoopKit
@testable import Loop

final class SmartwatchBolusPolicyTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let token = UUID()

    private func context(recommended: Double? = 2.0, maximum: Double? = 5.0, issuedAgo: TimeInterval = 60) -> SmartwatchBolusContext {
        SmartwatchBolusContext(token: token, issuedAt: now.addingTimeInterval(-issuedAgo), recommendedBolus: recommended, maximumBolus: maximum, supportedBolusVolumes: [])
    }

    /// Rounds down to 0.05 U, like a typical pump.
    private func policy(
        allowed: Bool = true,
        context: SmartwatchBolusContext? = nil,
        deliveries: [SmartwatchBolusPolicy.Delivery] = []
    ) -> SmartwatchBolusPolicy {
        SmartwatchBolusPolicy(
            isAllowed: allowed,
            currentContext: context ?? self.context(),
            recentDeliveries: deliveries,
            roundToSupportedVolume: { ($0 / 0.05).rounded(.down) * 0.05 }
        )
    }

    private func request(_ units: Double, token: UUID? = nil, confirmedAgo: TimeInterval = 5) -> SmartwatchBolusRequest {
        SmartwatchBolusRequest(units: units, contextToken: token ?? self.token, requestedAt: now.addingTimeInterval(-confirmedAgo))
    }

    func testDeliversARoundedBolusWithinTheRecommendation() throws {
        let units = try policy().evaluate(request(1.53), now: now).get()
        XCTAssertEqual(units, 1.5, accuracy: 0.0001)
    }

    func testAllowsExactlyTheRecommendation() {
        XCTAssertEqual(try? policy().evaluate(request(2.0), now: now).get(), 2.0)
    }

    func testOffUnlessAllowed() {
        XCTAssertEqual(policy(allowed: false).evaluate(request(1), now: now), .failure(.notAllowed))
    }

    func testRejectsInvalidAmounts() {
        XCTAssertEqual(policy().evaluate(request(0), now: now), .failure(.invalidAmount))
        XCTAssertEqual(policy().evaluate(request(-1), now: now), .failure(.invalidAmount))
        XCTAssertEqual(policy().evaluate(request(.nan), now: now), .failure(.invalidAmount))
        XCTAssertEqual(policy().evaluate(request(0.04), now: now), .failure(.invalidAmount), "Rounds to 0 U")
    }

    func testRejectsOldAndFutureRequests() {
        XCTAssertEqual(policy().evaluate(request(1, confirmedAgo: 31), now: now), .failure(.expiredRequest))
        XCTAssertEqual(policy().evaluate(request(1, confirmedAgo: -6), now: now), .failure(.expiredRequest))
        XCTAssertNotNil(try? policy().evaluate(request(1, confirmedAgo: 30), now: now).get())
    }

    func testRejectsAStaleOrMissingContext() {
        XCTAssertEqual(policy().evaluate(request(1, token: UUID()), now: now), .failure(.staleContext))
        XCTAssertEqual(policy(context: context(issuedAgo: 16 * 60)).evaluate(request(1), now: now), .failure(.staleContext))
        let noContext = SmartwatchBolusPolicy(isAllowed: true, currentContext: nil, recentDeliveries: [], roundToSupportedVolume: { $0 })
        XCTAssertEqual(noContext.evaluate(request(1), now: now), .failure(.staleContext))
    }

    func testRejectsMoreThanTheMaximumBolus() {
        let policy = policy(context: context(recommended: 8, maximum: 5))
        XCTAssertEqual(policy.evaluate(request(5.5), now: now), .failure(.exceedsMaximumBolus))
        let noMaximum = self.policy(context: context(maximum: nil))
        XCTAssertEqual(noMaximum.evaluate(request(1), now: now), .failure(.exceedsMaximumBolus))
    }

    func testRejectsMoreThanTheRecommendation() {
        XCTAssertEqual(policy().evaluate(request(2.1), now: now), .failure(.exceedsRecommendation))
        let noRecommendation = policy(context: context(recommended: nil))
        XCTAssertEqual(noRecommendation.evaluate(request(0.5), now: now), .failure(.exceedsRecommendation))
    }

    func testRateLimitsWatchBoluses() {
        let recent = [SmartwatchBolusPolicy.Delivery(date: now.addingTimeInterval(-10 * 60), units: 1)]
        XCTAssertEqual(policy(deliveries: recent).evaluate(request(1), now: now), .failure(.rateLimited))
        let older = [SmartwatchBolusPolicy.Delivery(date: now.addingTimeInterval(-16 * 60), units: 1)]
        XCTAssertNotNil(try? policy(deliveries: older).evaluate(request(1), now: now).get())
    }

    func testLimitsTheDailyTotal() {
        // Daily limit is 2 × the 5 U maximum bolus = 10 U.
        let earlier = [
            SmartwatchBolusPolicy.Delivery(date: now.addingTimeInterval(-20 * 60 * 60), units: 5),
            SmartwatchBolusPolicy.Delivery(date: now.addingTimeInterval(-2 * 60 * 60), units: 4),
        ]
        XCTAssertEqual(policy(deliveries: earlier).evaluate(request(1.5), now: now), .failure(.dailyLimitReached))
        XCTAssertNotNil(try? policy(deliveries: earlier).evaluate(request(1), now: now).get())
        let yesterday = [SmartwatchBolusPolicy.Delivery(date: now.addingTimeInterval(-25 * 60 * 60), units: 9)]
        XCTAssertNotNil(try? policy(deliveries: yesterday).evaluate(request(2), now: now).get())
    }
}
