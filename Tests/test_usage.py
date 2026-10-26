import importlib.util
from pathlib import Path
import unittest

SCRIPT = Path(__file__).resolve().parents[1] / "scripts/fetch_usage.py"
spec = importlib.util.spec_from_file_location("usage", SCRIPT)
usage = importlib.util.module_from_spec(spec)
spec.loader.exec_module(usage)


class UsageTests(unittest.TestCase):
    def test_codex_uses_correct_bucket_and_converts_to_remaining(self):
        data = {"rateLimitsByLimitId": {"codex": {"primary": {"usedPercent": 13, "windowDurationMins": 300, "resetsAt": 2000000000}, "secondary": {"usedPercent": 18, "windowDurationMins": 10080}}}, "rateLimits": {"primary": {"usedPercent": 90}}}
        result = usage.codex_snapshot(data)
        self.assertEqual([w["remainingPercent"] for w in result["windows"]], [87, 82])
        self.assertEqual(result["windows"][0]["resetsAt"], 2000000000)

    def test_missing_quota_is_not_displayed_as_unused(self):
        with self.assertRaises(ValueError):
            usage.codex_snapshot({"rateLimits": {"primary": {"usedPercent": None}}})
        with self.assertRaises(ValueError):
            usage.cursor_snapshot({"individualUsage": {"plan": {"used": 0}}})

    def test_cursor_ratio_and_fractional_percent(self):
        result = usage.cursor_snapshot({"individualUsage": {"plan": {"used": 423, "limit": 1000}}})
        self.assertAlmostEqual(result["windows"][0]["remainingPercent"], 57.7)
        result = usage.cursor_snapshot({"individualUsage": {"plan": {"autoPercentUsed": 0.36}}})
        self.assertEqual(result["windows"][0]["label"], "Cursor")
        self.assertAlmostEqual(result["windows"][0]["remainingPercent"], 99.64)
        self.assertAlmostEqual(result["windows"][0]["usedPercent"], 0.36)

    def test_cursor_matches_dashboard_pools_not_dollar_ratio(self):
        data = {"membershipType": "pro", "isUnlimited": False, "billingCycleEnd": "2026-11-11T18:39:35.000Z",
                "individualUsage": {"plan": {"used": 2000, "limit": 2000, "totalPercentUsed": 7.8, "autoPercentUsed": 2.82, "apiPercentUsed": 100},
                                    "onDemand": {"enabled": True, "used": 350, "limit": 5000}}}
        result = usage.cursor_snapshot(data)
        self.assertEqual([w["label"] for w in result["windows"]], ["Cursor", "Другие"])
        self.assertAlmostEqual(result["windows"][0]["usedPercent"], 2.82)
        self.assertAlmostEqual(result["windows"][1]["usedPercent"], 100)
        self.assertAlmostEqual(result["windows"][1]["remainingPercent"], 0)
        self.assertEqual(result["plan"], "Pro")
        self.assertEqual(result["notes"], ["Сверх плана: $3.50 / $50"])
        self.assertTrue(all(w["resetsAt"] == 1794422375 for w in result["windows"]))

    def test_cursor_unlimited_and_hidden_on_demand(self):
        result = usage.cursor_snapshot({"isUnlimited": True, "individualUsage": {"plan": {"used": 5, "limit": 100}, "onDemand": {"enabled": False, "used": 0}}})
        self.assertEqual(result["windows"][0]["remainingPercent"], 100.0)
        self.assertEqual(result["windows"][0]["detail"], "Без лимита")
        self.assertEqual(result["notes"], [])

    def test_codex_plan_and_flags(self):
        data = {"rateLimits": {"primary": {"usedPercent": 33, "windowDurationMins": 300}, "planType": "plus",
                               "credits": {"hasCredits": True, "unlimited": False, "balance": "12"}, "rateLimitReachedType": "primary"}}
        result = usage.codex_snapshot(data)
        self.assertEqual(result["plan"], "Plus")
        self.assertEqual(result["notes"], ["Кредиты: 12", "Лимит исчерпан"])
        self.assertEqual(usage.codex_snapshot({"rateLimits": {"primary": {"usedPercent": 1}}})["notes"], [])

    def test_overage_never_returns_negative_remaining(self):
        self.assertEqual(usage.remaining(180), 0)
        self.assertIsNone(usage.remaining(float("nan")))
        self.assertIsNone(usage.remaining(True))

    def test_error_output_does_not_include_credentials(self):
        def fail():
            raise ValueError("PRIVATE_TOKEN")
        result = usage.fetch("cursor", fail)
        self.assertNotIn("PRIVATE_TOKEN", str(result))
        self.assertEqual(result["windows"], [])


if __name__ == "__main__":
    unittest.main()
