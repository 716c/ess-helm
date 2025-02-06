# Copyright 2024 New Vector Ltd
#
# SPDX-License-Identifier: AGPL-3.0-only OR LicenseRef-Element-Commercial

import pytest

from . import values_files_to_test
from .utils import iterate_component_workload_parts

specific_toleration = {
    "key": "component",
    "operator": "Equals",
    "value": "pytest",
    "effect": "NoSchedule",
}

global_toleration = {
    "key": "global",
    "operator": "Equals",
    "value": "pytest",
    "effect": "NoSchedule",
}


@pytest.mark.parametrize("values_file", values_files_to_test)
@pytest.mark.asyncio_cooperative
async def test_no_tolerations_by_default(templates):
    for template in templates:
        if template["kind"] in ["Deployment", "StatefulSet", "Job"]:
            id = f"{template['kind']}/{template['metadata']['name']}"

            assert "tolerations" not in template["spec"]["template"]["spec"], (
                f"Tolerations unexpectedly present for {id}"
            )


@pytest.mark.parametrize("values_file", values_files_to_test)
@pytest.mark.asyncio_cooperative
async def test_all_components_and_sub_components_render_tolerations(component, values, make_templates):
    iterate_component_workload_parts(
        component, values, lambda workload, values: workload.setdefault("tolerations", []).append(specific_toleration)
    )

    for template in await make_templates(values):
        if template["kind"] in ["Deployment", "StatefulSet", "Job"]:
            id = f"{template['kind']}/{template['metadata']['name']}"

            pod_spec = template["spec"]["template"]["spec"]
            assert "tolerations" in pod_spec, f"No tolerations for {id}"
            assert len(pod_spec["tolerations"]) == 1, f"Wrong number of tolerations for {id}"
            assert pod_spec["tolerations"][0] == specific_toleration, f"Toleration isn't as expected for {id}"


@pytest.mark.parametrize("values_file", values_files_to_test)
@pytest.mark.asyncio_cooperative
async def test_global_tolerations_render(values, make_templates):
    values.setdefault("tolerations", []).append(global_toleration)

    for template in await make_templates(values):
        if template["kind"] in ["Deployment", "StatefulSet", "Job"]:
            id = f"{template['kind']}/{template['metadata']['name']}"

            pod_spec = template["spec"]["template"]["spec"]
            assert "tolerations" in pod_spec, f"No tolerations for {id}"
            assert len(pod_spec["tolerations"]) == 1, f"Wrong number of tolerations for {id}"
            assert pod_spec["tolerations"][0] == global_toleration, f"Toleration isn't as expected for {id}"


@pytest.mark.parametrize("values_file", values_files_to_test)
@pytest.mark.asyncio_cooperative
async def test_merges_global_and_specific_tolerations(component, values, make_templates):
    iterate_component_workload_parts(
        component, values, lambda workload, values: workload.setdefault("tolerations", []).append(specific_toleration)
    )

    # Add twice for uniqueness check. There's no 'overwriting' as if it isn't the same toleration, it gets kept
    values.setdefault("tolerations", []).append(global_toleration)
    values.get("tolerations").append(global_toleration)

    for template in await make_templates(values):
        if template["kind"] in ["Deployment", "StatefulSet", "Job"]:
            id = f"{template['kind']}/{template['metadata']['name']}"

            pod_spec = template["spec"]["template"]["spec"]
            assert "tolerations" in pod_spec, f"No tolerations for {id}"
            assert len(pod_spec["tolerations"]) == 2, f"Wrong number of tolerations for {id}"
            assert pod_spec["tolerations"] == [
                specific_toleration,
                global_toleration,
            ], f"Tolerations aren't as expected for {id}"
