import XCTest
@testable import QuotaAlerts

final class QuotaAlertsTests: XCTestCase {
    private func window(_ provider: String, _ label: String, _ remaining: Double, reset: Double? = 1_000, unlimited: Bool = false) -> QuotaWindowSample {
        QuotaWindowSample(provider: provider, label: label, remainingPercent: remaining, resetsAt: reset, unlimited: unlimited)
    }

    func testWarnsWhenRemainingDropsToAQuarter() {
        let plan = QuotaAlerts.plan(windows: [window("chatgpt", "5 часов", 20)], memory: [:], now: 500)
        XCTAssertEqual(plan.notice, QuotaNotice(title: "Осталось меньше четверти лимита", body: "ChatGPT · 5 часов: осталось 20%"))
        XCTAssertEqual(plan.memory.values.first, 25)
    }

    func testDoesNotRepeatTheSameThreshold() {
        let first = QuotaAlerts.plan(windows: [window("cursor", "Другие", 18)], memory: [:], now: 500)
        let second = QuotaAlerts.plan(windows: [window("cursor", "Другие", 16)], memory: first.memory, now: 600)
        XCTAssertNil(second.notice)
        XCTAssertEqual(second.memory.values.first, 25)
    }

    func testWarnsAgainWhenRemainingReachesTenPercent() {
        let warned = QuotaAlerts.plan(windows: [window("chatgpt", "Неделя", 22)], memory: [:], now: 500)
        let plan = QuotaAlerts.plan(windows: [window("chatgpt", "Неделя", 9.4)], memory: warned.memory, now: 600)
        XCTAssertEqual(plan.notice?.title, "Лимит почти исчерпан")
        XCTAssertEqual(plan.notice?.body, "ChatGPT · Неделя: осталось 9%")
        XCTAssertEqual(plan.memory.values.first, 10)
    }

    func testSaysTheLimitIsSpentAtZero() {
        let plan = QuotaAlerts.plan(windows: [window("cursor", "Cursor", 0.2)], memory: [:], now: 500)
        XCTAssertEqual(plan.notice?.body, "Cursor · Cursor: лимит исчерпан")
    }

    func testArmsAgainAfterTheBalanceRecovers() {
        let low = QuotaAlerts.plan(windows: [window("chatgpt", "5 часов", 8)], memory: [:], now: 500)
        let recovered = QuotaAlerts.plan(windows: [window("chatgpt", "5 часов", 40)], memory: low.memory, now: 600)
        XCTAssertNil(recovered.notice)
        XCTAssertTrue(recovered.memory.isEmpty)
        let again = QuotaAlerts.plan(windows: [window("chatgpt", "5 часов", 24)], memory: recovered.memory, now: 700)
        XCTAssertEqual(again.notice?.body, "ChatGPT · 5 часов: осталось 24%")
    }

    func testNewResetWindowAlertsOnItsOwn() {
        let low = QuotaAlerts.plan(windows: [window("cursor", "Cursor", 4, reset: 1_000)], memory: [:], now: 500)
        let plan = QuotaAlerts.plan(windows: [window("cursor", "Cursor", 4, reset: 2_000)], memory: low.memory, now: 1_500)
        XCTAssertEqual(plan.notice?.body, "Cursor · Cursor: осталось 4%")
    }

    func testSkipsUnlimitedAndNonFiniteWindows() {
        let windows = [
            window("cursor", "План", 0, unlimited: true),
            window("chatgpt", "5 часов", .nan),
        ]
        let plan = QuotaAlerts.plan(windows: windows, memory: ["stale": 10], now: 500)
        XCTAssertNil(plan.notice)
        XCTAssertEqual(plan.memory, ["stale": 10])
    }

    func testKeepsQuietAtTheBoundaryAboveTwentyFive() {
        let plan = QuotaAlerts.plan(windows: [window("chatgpt", "5 часов", 25.1)], memory: [:], now: 500)
        XCTAssertNil(plan.notice)
    }

    func testCombinesOnlyTheWindowsThatNewlyCrossed() {
        let memory = QuotaAlerts.plan(windows: [window("cursor", "Другие", 12, reset: 1_000)], memory: [:], now: 500).memory
        let plan = QuotaAlerts.plan(windows: [
            window("cursor", "Другие", 11, reset: 1_000),
            window("chatgpt", "5 часов", 7, reset: 2_000),
        ], memory: memory, now: 600)
        XCTAssertEqual(plan.notice?.title, "Лимит почти исчерпан")
        XCTAssertEqual(plan.notice?.body, "ChatGPT · 5 часов: осталось 7%")
    }

    func testForecastsMinutesFromAClearBurnRate() {
        // 20% burned in 10 minutes → 80% left lasts 40 minutes.
        XCTAssertEqual(QuotaForecast.minutesRemaining(from: 100, at: 0, to: 80, at: 600), 40)
        XCTAssertEqual(QuotaForecast.phrase(40), "хватит ~40 мин")
        XCTAssertEqual(QuotaForecast.phrase(125), "хватит ~2 ч 5 мин")
        XCTAssertEqual(QuotaForecast.phrase(120), "хватит ~2 ч")
    }

    func testForecastStaysQuietOnResetNoiseOrEmptyWindow() {
        XCTAssertNil(QuotaForecast.minutesRemaining(from: 10, at: 0, to: 90, at: 600))
        XCTAssertNil(QuotaForecast.minutesRemaining(from: 50, at: 0, to: 49.8, at: 600))
        XCTAssertNil(QuotaForecast.minutesRemaining(from: 8, at: 0, to: 0, at: 600))
        XCTAssertNil(QuotaForecast.minutesRemaining(from: 90, at: 0, to: 80, at: 30))
    }

    func testDropsAnnouncementsWhoseResetIsLongGone() {
        let key = ["chatgpt", "5 часов", "1000"].joined(separator: "\u{1e}")
        let plan = QuotaAlerts.plan(windows: [], memory: [key: 10], now: 1000 + 86400 * 3)
        XCTAssertTrue(plan.memory.isEmpty)
    }
}
