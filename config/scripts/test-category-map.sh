#!/usr/bin/env bash
#
# test-category-map.sh — shared test-name substring → dashboard category for ES.
# Source from sibling scripts only, e.g.:
#   _cnv_script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
#   # shellcheck source=test-category-map.sh
#   source "${_cnv_script_dir}/test-category-map.sh"
#
# Keys must stay aligned with scenario names in run-workloads.sh TEST_REGISTRY.

# shellcheck disable=SC2034
declare -A CATEGORY_MAP=(
    ["cpu-limits"]="Resource Limits"
    ["memory-limits"]="Resource Limits"
    ["disk-limits"]="Resource Limits"
    ["disk-hotplug"]="Hot-plug"
    ["nic-hotplug"]="Hot-plug"
    ["high-memory"]="Performance"
    ["large-disk"]="Performance"
    ["minimal-resources"]="Performance"
    ["per-host-density"]="Scale"
    ["virt-capacity-benchmark"]="Scale"
)
