# Copyright 2024 New Vector Ltd
#
# SPDX-License-Identifier: AGPL-3.0-only

import pytest

from . import values_files_to_test
from .utils import iterate_deployables_workload_parts


@pytest.mark.parametrize("values_file", values_files_to_test)
@pytest.mark.asyncio_cooperative
async def test_sets_no_topology_spread_constraint_default(templates):
    for template in templates:
        if template["kind"] in ["Deployment", "StatefulSet", "Job"]:
            id = f"{template['kind']}/{template['metadata']['name']}"

            assert "topologySpreadConstraintss" not in template["spec"]["template"]["spec"], (
                f"Pod securityContext unexpectedly present for {id}"
            )


@pytest.mark.parametrize("values_file", values_files_to_test)
@pytest.mark.asyncio_cooperative
async def test_topology_spread_constraint_has_default(
    deployables_details, values, make_templates, template_to_deployable_details
):
    def set_topology_spread_constraints(values_fragment, deployable_details):
        if deployable_details.has_topology_spread_constraints:
            values_fragment.setdefault(
                "topologySpreadConstraints",
                [
                    {
                        "maxSkew": 1,
                        "topologyKey": "kubernetes.io/hostname",
                        "whenUnsatisfiable": "DoNotSchedule",
                    }
                ],
            )

    iterate_deployables_workload_parts(deployables_details, values, set_topology_spread_constraints)

    for template in await make_templates(values):
        if template["kind"] in ["Deployment", "StatefulSet", "Job"]:
            id = f"{template['kind']}/{template['metadata']['name']}"
            if template_to_deployable_details(template).has_topology_spread_constraints:
                assert "topologySpreadConstraints" in template["spec"]["template"]["spec"], (
                    f"Pod topologySpreadConstraints unexpectedly absent for {id}"
                )

                pod_topologySpreadConstraints = template["spec"]["template"]["spec"]["topologySpreadConstraints"]
                assert pod_topologySpreadConstraints[0]["maxSkew"] == 1
                assert pod_topologySpreadConstraints[0]["topologyKey"] == "kubernetes.io/hostname"
                assert pod_topologySpreadConstraints[0]["whenUnsatisfiable"] == "DoNotSchedule"
                assert pod_topologySpreadConstraints[0]["labelSelector"]["matchLabels"] == {
                    "app.kubernetes.io/instance": template["metadata"]["labels"]["app.kubernetes.io/instance"]
                }
                if template["kind"] == "Deployment":
                    assert pod_topologySpreadConstraints[0]["matchLabelKeys"] == ["pod-template-hash"]
                else:
                    assert pod_topologySpreadConstraints[0]["matchLabelKeys"] == []
            else:
                assert "topologySpreadConstraints" not in template["spec"]["template"]["spec"], (
                    f"Pod topologySpreadConstraints unexpectedly present for {id}"
                )


@pytest.mark.parametrize("values_file", values_files_to_test)
@pytest.mark.asyncio_cooperative
async def test_can_nuke_topology_spread_constraint_defaults(
    deployables_details, values, make_templates, template_to_deployable_details
):
    def set_topology_spread_constraints(values_fragment, deployable_details):
        if deployable_details.has_topology_spread_constraints:
            values_fragment.setdefault(
                "topologySpreadConstraints",
                [
                    {
                        "maxSkew": 1,
                        "topologyKey": "kubernetes.io/hostname",
                        "whenUnsatisfiable": "DoNotSchedule",
                        "labelSelector": {
                            "matchLabels": {
                                "app.kubernetes.io/testlabel": "testvalue",
                                "app.kubernetes.io/instance": None,
                            }
                        },
                        "matchLabelKeys": ["app.kubernetes.io/testlabel"],
                    }
                ],
            )

    iterate_deployables_workload_parts(deployables_details, values, set_topology_spread_constraints)

    for template in await make_templates(values):
        if template["kind"] in ["Deployment", "StatefulSet", "Job"]:
            id = f"{template['kind']}/{template['metadata']['name']}"
            if template_to_deployable_details(template).has_topology_spread_constraints:
                assert "topologySpreadConstraints" in template["spec"]["template"]["spec"], (
                    f"Pod topologySpreadConstraints unexpectedly absent for {id}"
                )

                pod_topologySpreadConstraints = template["spec"]["template"]["spec"]["topologySpreadConstraints"]
                assert pod_topologySpreadConstraints[0]["maxSkew"] == 1
                assert pod_topologySpreadConstraints[0]["topologyKey"] == "kubernetes.io/hostname"
                assert pod_topologySpreadConstraints[0]["whenUnsatisfiable"] == "DoNotSchedule"
                assert pod_topologySpreadConstraints[0]["labelSelector"]["matchLabels"] == {
                    "app.kubernetes.io/testlabel": "testvalue"
                }
                assert pod_topologySpreadConstraints[0]["matchLabelKeys"] == ["app.kubernetes.io/testlabel"]
            else:
                assert "topologySpreadConstraints" not in template["spec"]["template"]["spec"], (
                    f"Pod topologySpreadConstraints unexpectedly present for {id}"
                )
