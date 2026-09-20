#!/usr/bin/env python3
"""Tests for admin_instances: pure resolve_scale_key + the moved mock-k8s
primitives. The transport (fetch_mock_status/mock_k8s_request) is thin I/O over
loopback HTTPS and is exercised end-to-end in the scheduler tests by monkeypatch;
here we pin the pure resolution logic that both callers depend on."""
import unittest

import admin_instances as inst


class TestResolveScaleKey(unittest.TestCase):
    def test_found_returns_ns_name_current(self):
        mock = {"maps": [
            {"map": "DeepDesert_1", "key": "default/world-deepdesert-1", "desired": 2},
            {"map": "SH_Arrakeen", "key": "default/world-sh-arrakeen", "desired": 0},
        ]}
        self.assertEqual(inst.resolve_scale_key(mock, "DeepDesert_1"),
                         ("default", "world-deepdesert-1", 2))

    def test_desired_missing_defaults_zero(self):
        mock = {"maps": [{"map": "SH_HarkoVillage", "key": "default/world-harko"}]}
        self.assertEqual(inst.resolve_scale_key(mock, "SH_HarkoVillage"),
                         ("default", "world-harko", 0))

    def test_map_absent_returns_none(self):
        mock = {"maps": [{"map": "DeepDesert_1", "key": "default/x", "desired": 1}]}
        self.assertIsNone(inst.resolve_scale_key(mock, "SH_Arrakeen"))

    def test_missing_or_empty_key_returns_none(self):
        self.assertIsNone(inst.resolve_scale_key({"maps": [{"map": "DeepDesert_1", "desired": 1}]}, "DeepDesert_1"))
        self.assertIsNone(inst.resolve_scale_key({"maps": [{"map": "DeepDesert_1", "key": "", "desired": 1}]}, "DeepDesert_1"))


class TestKnownMapName(unittest.TestCase):
    """The hub maps an operator most wants to start by hand are exactly the ones
    with no ServerSetScale yet, because nobody has travelled there. mock-k8s can
    materialise one on a by-name GET; the panel just needs the canonical name,
    which /status now carries as knownMaps."""

    STATUS = {
        "maps": [{"map": "Survival_1", "key": "default/w-survival-1", "desired": 1}],
        "knownMaps": [
            {"map": "Survival_1", "name": "w-survival-1", "partitionId": 1},
            {"map": "SH_Arrakeen", "name": "w-sh-arrakeen", "partitionId": 3},
        ],
    }

    def test_finds_a_map_that_has_no_scale_record_yet(self):
        self.assertEqual(inst.known_map_name(self.STATUS, "SH_Arrakeen"), "w-sh-arrakeen")

    def test_unknown_map_returns_none(self):
        self.assertIsNone(inst.known_map_name(self.STATUS, "SH_FallenLight"))

    def test_absent_known_maps_returns_none(self):
        # An older mock-k8s binary predates the field; the panel must degrade to
        # the previous behaviour rather than raise mid-request.
        self.assertIsNone(inst.known_map_name({"maps": []}, "SH_Arrakeen"))
        self.assertIsNone(inst.known_map_name(None, "SH_Arrakeen"))

    def test_entry_without_a_name_is_ignored(self):
        self.assertIsNone(inst.known_map_name({"knownMaps": [{"map": "SH_Arrakeen"}]}, "SH_Arrakeen"))

    def test_no_maps_returns_none(self):
        self.assertIsNone(inst.resolve_scale_key({}, "DeepDesert_1"))
        self.assertIsNone(inst.resolve_scale_key({"maps": []}, "DeepDesert_1"))

    def test_non_dict_returns_none(self):
        self.assertIsNone(inst.resolve_scale_key(None, "DeepDesert_1"))
        self.assertIsNone(inst.resolve_scale_key("nope", "DeepDesert_1"))

    def test_key_without_slash(self):
        # Faithful to admin-http's original str(key).partition("/"): a slash-less
        # key puts the whole string in the namespace slot, name "". Pathological
        # (mock-k8s keys are always "ns/name") — documented, not relied on.
        mock = {"maps": [{"map": "DeepDesert_1", "key": "world-noslash", "desired": 1}]}
        self.assertEqual(inst.resolve_scale_key(mock, "DeepDesert_1"), ("world-noslash", "", 1))


class TestConstants(unittest.TestCase):
    def test_scalable_maps_and_max(self):
        self.assertEqual(inst.SCALABLE_MAPS, ("DeepDesert_1", "SH_Arrakeen", "SH_HarkoVillage"))
        self.assertEqual(inst.SCALE_REPLICAS_MAX, 4)


if __name__ == "__main__":
    unittest.main()
