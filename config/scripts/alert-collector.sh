#!/bin/bash
#
# alert-collector.sh - Capture Prometheus alerts during a test window
#
# Queries Prometheus /api/v1/alerts, filters alerts active during the given
# time window, produces structured JSON, and optionally indexes to ES.
#
# Usage:
#   alert-collector.sh \
#     --uuid <uuid> \
#     --test-name <name> \
#     --start-time <ISO8601> \
#     --end-time <ISO8601> \
#     --prom-url <url> \
#     --prom-token <token> \
#     [--es-server <url>] \
#     [--metadata-index <name>] \
#     [--results-dir <path>]
#

set -eo pipefail

UUID=""
TEST_NAME=""
START_TIME=""
END_TIME=""
PROM_URL=""
PROM_TOKEN=""
ES_SERVER=""
METADATA_INDEX="cnv-alerts"
RESULTS_DIR=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --uuid)            UUID="$2";            shift 2 ;;
        --test-name)       TEST_NAME="$2";        shift 2 ;;
        --start-time)      START_TIME="$2";       shift 2 ;;
        --end-time)        END_TIME="$2";        shift 2 ;;
        --prom-url)        PROM_URL="$2";        shift 2 ;;
        --prom-token)      PROM_TOKEN="$2";      shift 2 ;;
        --es-server)       ES_SERVER="$2";       shift 2 ;;
        --metadata-index)  METADATA_INDEX="$2";  shift 2 ;;
        --results-dir)     RESULTS_DIR="$2";     shift 2 ;;
        *)
            echo "alert-collector: Unknown argument: $1" >&2
            exit 1
            ;;
    esac
done

for cmd in curl jq; do
    if ! command -v "$cmd" &>/dev/null; then
        echo "alert-collector: Requires $cmd" >&2
        exit 1
    fi
done

if [[ -z "$UUID" || -z "$TEST_NAME" || -z "$START_TIME" || -z "$END_TIME" || -z "$PROM_URL" || -z "$PROM_TOKEN" ]]; then
    echo "alert-collector: --uuid, --test-name, --start-time, --end-time, --prom-url, --prom-token are required" >&2
    exit 1
fi

parse_iso_epoch() {
    local iso="$1"
    if [[ -z "$iso" ]]; then
        echo "0"
        return
    fi
    local epoch
    epoch=$(date -d "$iso" +%s 2>/dev/null) || epoch=$(date -j -f "%Y-%m-%dT%H:%M:%S" "${iso%%+*}" +%s 2>/dev/null) || echo "0"
    echo "${epoch:-0}"
}

start_epoch=$(parse_iso_epoch "$START_TIME")
end_epoch=$(parse_iso_epoch "$END_TIME")

prom_response=""
http_code=""
prom_result=$(curl -s -w "\n%{http_code}" \
    -H "Authorization: Bearer ${PROM_TOKEN}" \
    -k \
    "${PROM_URL}/api/v1/alerts" 2>/dev/null) || true

if [[ -z "$prom_result" ]]; then
    echo "alert-collector: WARNING: Prometheus unreachable or request failed" >&2
    exit 0
fi

http_code=$(echo "$prom_result" | tail -n1)
prom_response=$(echo "$prom_result" | sed '$d')

if [[ "$http_code" != "200" && "$http_code" != "000" ]]; then
    echo "alert-collector: WARNING: Prometheus returned HTTP ${http_code} (unreachable or token invalid)" >&2
    exit 0
fi

if [[ -z "$prom_response" ]]; then
    echo "alert-collector: WARNING: Empty response from Prometheus" >&2
    exit 0
fi

status=$(echo "$prom_response" | jq -r '.status // "error"')
if [[ "$status" != "success" ]]; then
    echo "alert-collector: WARNING: Prometheus API returned status=$status" >&2
    exit 0
fi

raw_alerts=$(echo "$prom_response" | jq -c '.data.alerts // []')
if [[ -z "$raw_alerts" || "$raw_alerts" == "null" ]]; then
    raw_alerts="[]"
fi

filtered="[]"
while read -r alert; do
    [[ -z "$alert" ]] && continue
    active_at=$(echo "$alert" | jq -r '.activeAt // ""')
    if [[ -z "$active_at" ]]; then
        continue
    fi
    epoch=$(parse_iso_epoch "$active_at")
    if [[ "$epoch" -ge "$start_epoch" && "$epoch" -le "$end_epoch" ]]; then
        filtered=$(echo "$filtered" "$alert" | jq -s '
            (.[0] | if type == "array" then . else [] end) +
            [.[1] | {
                alertname: (.labels.alertname // "unknown"),
                severity: (.labels.severity // "unknown"),
                state: .state,
                labels: .labels,
                activeAt: .activeAt,
                value: (.value // "")
            }]
        ')
    fi
done < <(echo "$raw_alerts" | jq -c '.[]')

total_firing=$(echo "$filtered" | jq '[.[] | select(.state == "firing")] | length')
total_pending=$(echo "$filtered" | jq '[.[] | select(.state == "pending")] | length')
critical=$(echo "$filtered" | jq -r '[.[] | select(.severity == "critical") | .alertname] | unique | .[]')
warning=$(echo "$filtered" | jq -r '[.[] | select(.severity == "warning") | .alertname] | unique | .[]')
info=$(echo "$filtered" | jq -r '[.[] | select(.severity == "info" or .severity == "unknown") | .alertname] | unique | .[]')

critical_json=$(echo "$critical" | jq -R -s 'split("\n") | map(select(length > 0))')
warning_json=$(echo "$warning" | jq -R -s 'split("\n") | map(select(length > 0))')
info_json=$(echo "$info" | jq -R -s 'split("\n") | map(select(length > 0))')

output_json=$(jq -n \
    --arg uuid "$UUID" \
    --arg testName "$TEST_NAME" \
    --arg timestamp "$(date -Iseconds)" \
    --arg startTime "$START_TIME" \
    --arg endTime "$END_TIME" \
    --argjson totalFiring "$total_firing" \
    --argjson totalPending "$total_pending" \
    --argjson critical "$critical_json" \
    --argjson warning "$warning_json" \
    --argjson info "$info_json" \
    --argjson alerts "$filtered" \
    '{
        uuid: $uuid,
        testName: $testName,
        metricName: "alerts",
        timestamp: $timestamp,
        startTime: $startTime,
        endTime: $endTime,
        alertsSummary: {
            totalFiring: $totalFiring,
            totalPending: $totalPending,
            critical: $critical,
            warning: $warning,
            info: $info
        },
        alerts: $alerts
    }')

if [[ -n "$RESULTS_DIR" ]]; then
    mkdir -p "$RESULTS_DIR"
    echo "$output_json" > "${RESULTS_DIR}/alerts.json"
    echo "alert-collector: Saved to ${RESULTS_DIR}/alerts.json"
fi

if [[ -n "$ES_SERVER" ]]; then
    response=$(curl -s -o /dev/null -w "%{http_code}" \
        -X POST "${ES_SERVER}/${METADATA_INDEX}/_doc" \
        -H 'Content-Type: application/json' \
        -k \
        -d "$output_json" 2>/dev/null) || true

    if [[ "$response" == "201" || "$response" == "200" ]]; then
        echo "alert-collector: Indexed to ${METADATA_INDEX} (HTTP ${response})"
    else
        echo "alert-collector: WARNING: Failed to index to ${METADATA_INDEX} (HTTP ${response})" >&2
    fi
fi

echo "alert-collector: Done."
