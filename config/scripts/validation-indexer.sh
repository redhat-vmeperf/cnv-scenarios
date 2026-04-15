#!/bin/bash
#
# validation-indexer.sh - Index validation JSON reports to Elasticsearch
#
# Reads validation-*.json files from the results directory, enriches them
# with uuid and testCategory, then indexes each to the cnv-validation ES index.
#
# Usage:
#   validation-indexer.sh \
#     --uuid <kube-burner-uuid> \
#     --results-dir <path-to-results> \
#     --es-server <url> \
#     [--index <name>]
#

set -eo pipefail

UUID=""
RESULTS_DIR=""
ES_SERVER=""
INDEX="cnv-validation"
TEST_NAME_OVERRIDE=""

_cnv_script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=test-category-map.sh
source "${_cnv_script_dir}/test-category-map.sh"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --uuid)
            UUID="$2"
            shift 2
            ;;
        --results-dir)
            RESULTS_DIR="$2"
            shift 2
            ;;
        --es-server)
            ES_SERVER="$2"
            shift 2
            ;;
        --test-name)
            TEST_NAME_OVERRIDE="$2"
            shift 2
            ;;
        --index)
            INDEX="$2"
            shift 2
            ;;
        *)
            echo "validation-indexer: Unknown argument: $1" >&2
            exit 1
            ;;
    esac
done

if [[ -z "$UUID" || -z "$RESULTS_DIR" || -z "$ES_SERVER" ]]; then
    echo "validation-indexer: --uuid, --results-dir, and --es-server are required" >&2
    exit 1
fi

val_files=()
while IFS= read -r -d '' f; do
    val_files+=("$f")
done < <(find "$RESULTS_DIR" -name "validation-*.json" -type f -print0 2>/dev/null)

if [[ ${#val_files[@]} -eq 0 ]]; then
    echo "validation-indexer: No validation files found in ${RESULTS_DIR}"
    exit 0
fi

indexed=0
failed=0

for vf in "${val_files[@]}"; do
    test_name=$(jq -r '.testName // "unknown"' "$vf" 2>/dev/null)
    if [[ -n "$TEST_NAME_OVERRIDE" ]]; then
        test_name="$TEST_NAME_OVERRIDE"
    fi

    test_category="Unknown"
    for key in "${!CATEGORY_MAP[@]}"; do
        if [[ "$test_name" == *"$key"* ]]; then
            test_category="${CATEGORY_MAP[$key]}"
            break
        fi
    done

    enriched=$(jq \
        --arg uuid "$UUID" \
        --arg testName "$test_name" \
        --arg metricName "validation" \
        --arg testCategory "$test_category" \
        '. + {uuid: $uuid, testName: $testName, metricName: $metricName, testCategory: $testCategory}' \
        "$vf" 2>/dev/null)

    if [[ -z "$enriched" ]]; then
        echo "validation-indexer: WARNING: Failed to parse ${vf}" >&2
        failed=$((failed + 1))
        continue
    fi

    response=$(curl -s -o /dev/null -w "%{http_code}" \
        -X POST "${ES_SERVER}/${INDEX}/_doc" \
        -H 'Content-Type: application/json' \
        -k \
        -d "$enriched" 2>/dev/null) || true

    if [[ "$response" == "201" || "$response" == "200" ]]; then
        indexed=$((indexed + 1))
        echo "validation-indexer: Indexed ${vf##*/} to ${INDEX} (HTTP ${response})"
    else
        failed=$((failed + 1))
        echo "validation-indexer: WARNING: Failed to index ${vf##*/} (HTTP ${response})" >&2
    fi
done

echo "validation-indexer: Done. Indexed: ${indexed}, Failed: ${failed}"
