import sys
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts"))
from check_29_plan import validate  # noqa: E402


def plan(resources, server="0.40", ip_block="0.028", total="0.428"):
    return {
        "resource_changes": [
            {"address": name, "change": {"actions": actions, "before": {"delete_ip_blocks": True}}}
            for name, actions in resources.items()
        ],
        "output_changes": {
            "quoted_server_usd_per_hour": {"after": server},
            "quoted_public_ipv4_29_usd_per_hour": {"after": ip_block},
            "quoted_total_usd_per_hour": {"after": total},
            "quoted_public_ip_skus": {
                "after": [{
                    "product_code": "range-29",
                    "sku": "W0I2-DIVY-ZJVP",
                    "location": "GLOBAL",
                    "pricing_model": "HOURLY",
                    "price_unit": "HOUR",
                    "rate": ip_block,
                }],
            },
        },
    }


class PlanSafetyTests(unittest.TestCase):
    old_server = "pnap_server.esxi[0]"
    new_block = "pnap_ip_block.lab_public_ipv4[0]"

    def test_retire_only_server(self):
        validate(plan({self.old_server: ["delete"]}), "retire")

    def test_retire_rejects_other_deletions(self):
        with self.assertRaises(ValueError):
            validate(plan({self.old_server: ["delete"], "pnap_ip_block.other": ["delete"]}), "retire")

    def test_retire_requires_old_ip_cleanup(self):
        p = plan({self.old_server: ["delete"]})
        p["resource_changes"][0]["change"]["before"]["delete_ip_blocks"] = False
        with self.assertRaises(ValueError):
            validate(p, "retire")

    def test_create_within_budget(self):
        validate(plan({self.old_server: ["create"], self.new_block: ["create"]}), "create")

    def test_create_rejects_unexpected_replacement(self):
        with self.assertRaises(ValueError):
            validate(plan({self.old_server: ["delete", "create"], self.new_block: ["create"]}), "create")

    def test_create_rejects_over_budget(self):
        with self.assertRaises(ValueError):
            validate(plan({self.old_server: ["create"], self.new_block: ["create"]}, total="0.501"), "create")

    def test_create_rejects_bad_unit_math(self):
        with self.assertRaises(ValueError):
            validate(plan({self.old_server: ["create"], self.new_block: ["create"]}, total="0.400"), "create")

    def test_create_rejects_missing_live_quote(self):
        p = plan({self.old_server: ["create"], self.new_block: ["create"]})
        del p["output_changes"]["quoted_public_ipv4_29_usd_per_hour"]
        with self.assertRaises(ValueError):
            validate(p, "create")

    def test_create_rejects_wrong_ip_sku(self):
        p = plan({self.old_server: ["create"], self.new_block: ["create"]})
        p["output_changes"]["quoted_public_ip_skus"]["after"][0]["sku"] = "UNAPPROVED"
        with self.assertRaises(ValueError):
            validate(p, "create")

    def test_create_rejects_missing_sku_catalog(self):
        p = plan({self.old_server: ["create"], self.new_block: ["create"]})
        p["output_changes"]["quoted_public_ip_skus"]["after"] = []
        with self.assertRaises(ValueError):
            validate(p, "create")

    def test_create_rejects_range_price_counted_eight_times(self):
        p = plan({self.old_server: ["create"], self.new_block: ["create"]}, total="0.624")
        with self.assertRaises(ValueError):
            validate(p, "create")

    def test_quote_allows_preview_of_old_host_change_without_applying(self):
        validate(plan({self.old_server: ["update"], self.new_block: ["create"]}), "quote")

    def test_quote_rejects_over_budget_before_retirement(self):
        with self.assertRaises(ValueError):
            validate(plan({self.old_server: ["update"]}, total="0.501"), "quote")


if __name__ == "__main__":
    unittest.main()
