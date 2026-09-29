#!/bin/bash

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=validate-config.sh
source "${SCRIPT_DIR}/validate-config.sh"

MAX_RETRIES=130
MAX_SHORT_WAITS=12
SHORT_WAIT=5
LONG_WAIT=30

log_validation_start() {
    local function_name="$1"
    echo "VALIDATION_START|function=${function_name}|timestamp=$(date -Iseconds)"
}

log_validation_checkpoint() {
    local name="$1"
    local status="$2"
    local message="${3:-}"
    echo "VALIDATION_CHECK|name=${name}|status=${status}|message=${message}"
}

log_validation_end() {
    local status="$1"
    local duration="$2"
    echo "VALIDATION_END|status=${status}|duration=${duration}"
}

make_validation() {
    local phase="$1"
    local status="$2"
    local message="$3"
    local details="${4:-{}}"

    jq -cn \
        --arg phase "${phase}" \
        --arg status "${status}" \
        --arg message "${message}" \
        --argjson details "${details}" \
        '{phase: $phase, status: $status, message: $message, details: $details}'
}

save_validation_report() {
    local test_name="$1"
    local status="$2"
    local namespace="$3"
    local params_json="$4"
    local validations_json="$5"
    local results_dir="$6"
    local exit_code=0

    if [[ "${status}" == "FAILED" ]]; then
        exit_code=1
    fi
    mkdir -p "${results_dir}"

    jq -n \
        --arg testName "${test_name}" \
        --arg function "check_${test_name//-/_}" \
        --arg timestamp "$(date -Iseconds)" \
        --arg namespace "${namespace}" \
        --argjson parameters "${params_json}" \
        --arg overallStatus "${status}" \
        --argjson exitCode "${exit_code}" \
        --argjson validations "${validations_json}" \
        '{
            testName: $testName,
            function: $function,
            timestamp: $timestamp,
            namespace: $namespace,
            parameters: $parameters,
            overallStatus: $overallStatus,
            exitCode: $exitCode,
            validations: $validations
        }' >"${results_dir}/validation-${test_name}.json"

    echo "Validation report saved to: ${results_dir}/validation-${test_name}.json"
}

remote_command_password_from_pod() {
    local namespace="$1"
    local validator_pod="$2"
    local password="$3"
    local remote_user="$4"
    local guest_ip="$5"
    local command="$6"
    local output

    output=$(oc exec -n "${namespace}" "${validator_pod}" -- \
        env VM_SSH_PASSWORD="${password}" VM_SSH_USER="${remote_user}" \
        VM_SSH_HOST="${guest_ip}" VM_SSH_COMMAND="${command}" \
        sh -c '
            askpass_file=$(mktemp)
            trap '\''rm -f "${askpass_file}"'\'' EXIT
            printf '\''#!/bin/sh\nprintf "%%s\\n" "$VM_SSH_PASSWORD"\n'\'' > "${askpass_file}"
            chmod 700 "${askpass_file}"
            DISPLAY=:0 SSH_ASKPASS="${askpass_file}" SSH_ASKPASS_REQUIRE=force \
                setsid -w ssh \
                -o StrictHostKeyChecking=no \
                -o UserKnownHostsFile=/dev/null \
                -o PreferredAuthentications=password \
                -o PubkeyAuthentication=no \
                -o NumberOfPasswordPrompts=1 \
                -o ConnectTimeout=10 \
                -o LogLevel=ERROR \
                "${VM_SSH_USER}@${VM_SSH_HOST}" "${VM_SSH_COMMAND}"
        ' 2>&1)
    local ret=$?
    printf '%s\n' "${output}"
    return "${ret}"
}

check_requested_ip_udn() {
    local label_key="$1"
    local label_value="$2"
    local namespace="$3"
    local vm_password="$4"
    local vm_user="$5"
    local results_dir="$6"
    shift 6

    local -A cfg
    local arg
    for arg in "$@"; do
        [[ "${arg}" == *"="* ]] && cfg["${arg%%=*}"]="${arg#*=}"
    done

    local udn_name="${cfg[udnName]:-scale-test-udn}"
    local vm_count="${cfg[vmCount]:-10}"
    local ip_offset="${cfg[ipOffset]:-2}"
    local subnet_prefix="${cfg[subnetPrefix]:-172.16.0}"
    local validate_ssh="${cfg[validateSSH]:-true}"
    local ssh_sample_percent="${cfg[sshSamplePercent]:-25}"
    local max_ssh_retries="${cfg[maxSshRetries]:-10}"
    local ssh_retry_delay_seconds="${cfg[sshRetryDelaySeconds]:-5}"
    local ssh_validator_image="${cfg[sshValidatorImage]:-image-registry.openshift-image-registry.svc:5000/openshift/network-tools:latest}"

    validate_config "${udn_name}" "${vm_count}" "${ip_offset}" \
        "${subnet_prefix}" "${validate_ssh}" "${ssh_sample_percent}" \
        "${max_ssh_retries}" "${ssh_retry_delay_seconds}" || return $?

    log_validation_start "check_requested_ip_udn"
    local start_time=${SECONDS}
    local overall_status="PASSED"
    local -a validations=()
    local params_json
    params_json=$(jq -cn \
        --arg namespace "${namespace}" \
        --arg labelKey "${label_key}" \
        --arg labelValue "${label_value}" \
        --arg udnName "${udn_name}" \
        --argjson vmCount "${vm_count}" \
        --argjson ipOffset "${ip_offset}" \
        --arg subnetPrefix "${subnet_prefix}" \
        --arg validateSSH "${validate_ssh}" \
        --argjson sshSamplePercent "${ssh_sample_percent}" \
        --argjson maxSshRetries "${max_ssh_retries}" \
        --argjson sshRetryDelaySeconds "${ssh_retry_delay_seconds}" \
        --arg sshValidatorImage "${ssh_validator_image}" \
        '{namespace: $namespace, labelKey: $labelKey, labelValue: $labelValue,
          udnName: $udnName, vmCount: $vmCount, ipOffset: $ipOffset,
          subnetPrefix: $subnetPrefix, validateSSH: $validateSSH,
          sshSamplePercent: $sshSamplePercent, maxSshRetries: $maxSshRetries,
          sshRetryDelaySeconds: $sshRetryDelaySeconds,
          sshValidatorImage: $sshValidatorImage}')

    mkdir -p "${results_dir}"

    echo
    echo "Phase 1: VM Discovery"
    echo "────────────────────────────────────"
    local vms
    vms=$(oc get vm -n "${namespace}" -l "${label_key}=${label_value}" -o json 2>/dev/null || true)
    local vm_names
    vm_names=$(jq -r '.items[]?.metadata.name' <<<"${vms}" 2>/dev/null || true)
    local actual_count
    actual_count=$(jq -r '.items | length' <<<"${vms}" 2>/dev/null || echo 0)
    actual_count="${actual_count:-0}"

    echo "  Expected VMs: ${vm_count}"
    echo "  Found VMs: ${actual_count}"
    if [[ "${actual_count}" == "${vm_count}" ]]; then
        log_validation_checkpoint "vm_discovery" "PASS" "Found all ${actual_count} VMs"
        validations+=("$(make_validation "vm_discovery" "PASS" \
            "Found all ${actual_count} VMs" \
            "$(jq -cn --argjson expected "${vm_count}" --argjson actual "${actual_count}" '{expected: $expected, actual: $actual}')")")
    else
        log_validation_checkpoint "vm_discovery" "FAIL" "Expected ${vm_count}, found ${actual_count} VMs"
        validations+=("$(make_validation "vm_discovery" "FAIL" \
            "Expected ${vm_count} VMs but found ${actual_count}" \
            "$(jq -cn --argjson expected "${vm_count}" --argjson actual "${actual_count}" '{expected: $expected, actual: $actual}')")")
        overall_status="FAILED"
    fi

    echo
    echo "Phase 2: VMI IP vs Annotation Match (P0)"
    echo "────────────────────────────────────"
    local ip_match_pass=0
    local ip_match_fail=0
    local -a expected_ips=()

    if [[ "${overall_status}" != "FAILED" ]]; then
        local vm
        while IFS= read -r vm; do
            [[ -z "${vm}" ]] && continue
            local vm_json expected_ip vmi_json vmi_ip
            vm_json=$(oc get vm "${vm}" -n "${namespace}" -o json 2>/dev/null || true)
            expected_ip=$(jq -r --arg udn "${udn_name}" \
                '.spec.template.metadata.annotations["network.kubevirt.io/addresses"]
                 | fromjson? | .[$udn]
                 | if type == "array" then .[0] else . end // empty' \
                <<<"${vm_json}" 2>/dev/null || true)
            expected_ip="${expected_ip%%/*}"
            [[ -n "${expected_ip}" ]] && expected_ips+=("${expected_ip}")

            vmi_json=$(oc get vmi "${vm}" -n "${namespace}" -o json 2>/dev/null || true)
            vmi_ip=$(jq -r --arg udn "${udn_name}" \
                '([.status.interfaces[]? | select(.name == $udn) | .ipAddress][0]
                  // [.status.interfaces[]?.ipAddress][0] // empty)' \
                <<<"${vmi_json}" 2>/dev/null || true)
            vmi_ip="${vmi_ip%%/*}"

            if [[ -n "${expected_ip}" && "${expected_ip}" == "${vmi_ip}" ]]; then
                ((++ip_match_pass))
                echo "  PASS: ${vm} expected=${expected_ip} vmi=${vmi_ip}"
            else
                ((++ip_match_fail))
                echo "  FAIL: ${vm} expected=${expected_ip:-<none>} vmi=${vmi_ip:-<none>}"
            fi
        done <<<"${vm_names}"

        if ((ip_match_fail == 0 && ip_match_pass == actual_count)); then
            log_validation_checkpoint "ip_annotation_match" "PASS" "${ip_match_pass}/${actual_count} IPs match"
            validations+=("$(make_validation "ip_annotation_match" "PASS" \
                "${ip_match_pass}/${actual_count} VMI IPs match annotation" \
                "$(jq -cn --argjson pass "${ip_match_pass}" --argjson fail "${ip_match_fail}" '{pass: $pass, fail: $fail}')")")
        else
            log_validation_checkpoint "ip_annotation_match" "FAIL" "${ip_match_fail} mismatches"
            validations+=("$(make_validation "ip_annotation_match" "FAIL" \
                "${ip_match_fail}/${actual_count} VMI IPs do not match annotation" \
                "$(jq -cn --argjson pass "${ip_match_pass}" --argjson fail "${ip_match_fail}" '{pass: $pass, fail: $fail}')")")
            overall_status="FAILED"
        fi
    else
        validations+=("$(make_validation "ip_annotation_match" "SKIP" "Skipped: VM discovery failed")")
    fi

    echo
    echo "Phase 3: IPAMClaim Status"
    echo "────────────────────────────────────"
    if [[ "${overall_status}" != "FAILED" ]]; then
        local claims_json allocated_ips total_claims successful_claims
        claims_json=$(oc get ipamclaims -n "${namespace}" -o json 2>/dev/null || true)
        total_claims=$(jq -r '.items | length' <<<"${claims_json}" 2>/dev/null || echo 0)
        successful_claims=$(jq -r \
            '[.items[]? | select(any(.status.conditions[]?;
              .type == "IPsAllocated" and .status == "True"))] | length' \
            <<<"${claims_json}" 2>/dev/null || echo 0)
        allocated_ips=$(jq -r \
            '.items[]? | select(any(.status.conditions[]?;
             .type == "IPsAllocated" and .status == "True"))
             | .status.ips[]? | split("/")[0]' \
            <<<"${claims_json}" 2>/dev/null || true)
        total_claims="${total_claims:-0}"
        successful_claims="${successful_claims:-0}"

        local matched_claims=0
        local missing_claims=$((actual_count - ${#expected_ips[@]}))
        local expected_ip
        for expected_ip in "${expected_ips[@]}"; do
            if grep -Fxq -- "${expected_ip}" <<<"${allocated_ips}"; then
                ((++matched_claims))
            else
                ((++missing_claims))
            fi
        done

        echo "  Total IPAMClaims: ${total_claims}"
        echo "  Successful allocations: ${successful_claims}"
        echo "  Requested IPs in successful claims: ${matched_claims}/${actual_count}"

        local claim_details
        claim_details=$(jq -cn \
            --argjson total "${total_claims}" \
            --argjson successful "${successful_claims}" \
            --argjson matched "${matched_claims}" \
            --argjson missing "${missing_claims}" \
            '{totalClaims: $total, successfulClaims: $successful,
              matched: $matched, missing: $missing}')
        if ((missing_claims == 0 && matched_claims == actual_count)); then
            log_validation_checkpoint "ipamclaim_allocation" "PASS" "All ${matched_claims} requested IPs allocated"
            validations+=("$(make_validation "ipamclaim_allocation" "PASS" \
                "All requested IPs have IPsAllocated=True" "${claim_details}")")
        else
            log_validation_checkpoint "ipamclaim_allocation" "FAIL" "${missing_claims} requested allocations missing"
            validations+=("$(make_validation "ipamclaim_allocation" "FAIL" \
                "${missing_claims}/${actual_count} requested IPs lack IPsAllocated=True" "${claim_details}")")
            overall_status="FAILED"
        fi
    else
        validations+=("$(make_validation "ipamclaim_allocation" "SKIP" "Skipped: prior phase failed")")
    fi

    echo
    echo "Phase 4: Guest OS IP via SSH (P1)"
    echo "────────────────────────────────────"
    if [[ "${validate_ssh}" != "true" || -z "${vm_password}" || "${ssh_sample_percent}" == "0" ]]; then
        validations+=("$(make_validation "guest_ip_validation" "SKIP" "SSH validation disabled")")
    elif [[ "${overall_status}" == "FAILED" ]]; then
        validations+=("$(make_validation "guest_ip_validation" "SKIP" "Skipped: prior validation phase failed")")
    else
        local ssh_pass=0
        local ssh_fail=0
        local ssh_unreachable=0
        local sample_size=$(((actual_count * ssh_sample_percent + 99) / 100))
        local sample_vms
        sample_vms=$(head -n "${sample_size}" <<<"${vm_names}")
        local validator_pod="requested-ip-ssh-validator"
        local validator_ready=false

        echo "  Sampling ${sample_size}/${actual_count} VMs for SSH validation"
        oc delete pod "${validator_pod}" -n "${namespace}" \
            --ignore-not-found=true --wait=true >/dev/null 2>&1 || true
        if oc run "${validator_pod}" -n "${namespace}" \
            --image="${ssh_validator_image}" \
            --labels="app=requested-ip-ssh-validator" \
            --overrides='{"spec":{"automountServiceAccountToken":false,"activeDeadlineSeconds":900}}' \
            --restart=Never --command -- sleep 900 >/dev/null 2>&1 &&
            oc wait -n "${namespace}" --for=condition=Ready \
                "pod/${validator_pod}" --timeout=2m >/dev/null 2>&1; then
            validator_ready=true
            echo "  Validator ready on primary UDN"
        else
            echo "  FAIL: in-UDN SSH validator pod did not become ready"
        fi

        local vm
        while IFS= read -r vm; do
            [[ -z "${vm}" ]] && continue
            local vm_json expected_ip guest_ips="" last_ssh_error="" attempt=0
            vm_json=$(oc get vm "${vm}" -n "${namespace}" -o json 2>/dev/null || true)
            expected_ip=$(jq -r --arg udn "${udn_name}" \
                '.spec.template.metadata.annotations["network.kubevirt.io/addresses"]
                 | fromjson? | .[$udn]
                 | if type == "array" then .[0] else . end // empty' \
                <<<"${vm_json}" 2>/dev/null || true)
            expected_ip="${expected_ip%%/*}"

            if [[ "${validator_ready}" == "true" ]]; then
                while ((attempt < max_ssh_retries)); do
                    local ssh_output=""
                    if ssh_output=$(remote_command_password_from_pod \
                        "${namespace}" "${validator_pod}" "${vm_password}" \
                        "${vm_user}" "${expected_ip}" \
                        "(command -v ip >/dev/null 2>&1 && ip -4 -o addr show || busybox ip -4 -o addr show) | awk '{print \$4}' | cut -d/ -f1" 2>&1); then
                        guest_ips=$(tr -d '\r' <<<"${ssh_output}")
                        [[ -n "${guest_ips}" ]] && break
                    else
                        last_ssh_error=$(grep -v '^command terminated' <<<"${ssh_output}" | tail -1)
                    fi
                    ((++attempt))
                    ((attempt < max_ssh_retries)) && sleep "${ssh_retry_delay_seconds}"
                done
            else
                attempt="${max_ssh_retries}"
                last_ssh_error="validator pod unavailable"
            fi

            if grep -Fxq -- "${expected_ip}" <<<"${guest_ips}"; then
                ((++ssh_pass))
                echo "  PASS: ${vm} guest IPs include expected=${expected_ip}"
            elif [[ -n "${guest_ips}" ]]; then
                ((++ssh_fail))
                echo "  FAIL: ${vm} expected IP ${expected_ip} not found in guest"
            else
                ((++ssh_unreachable))
                echo "  FAIL: ${vm} SSH unreachable after ${attempt} attempts${last_ssh_error:+: ${last_ssh_error}}"
            fi
        done <<<"${sample_vms}"

        oc delete pod "${validator_pod}" -n "${namespace}" \
            --ignore-not-found=true --wait=false >/dev/null 2>&1 || true

        local ssh_details
        ssh_details=$(jq -cn \
            --argjson pass "${ssh_pass}" --argjson fail "${ssh_fail}" \
            --argjson unreachable "${ssh_unreachable}" \
            '{pass: $pass, fail: $fail, unreachable: $unreachable}')
        echo "  SSH Result: ${ssh_pass} pass, ${ssh_fail} fail, ${ssh_unreachable} unreachable"
        if ((ssh_fail > 0 || ssh_unreachable > 0)); then
            validations+=("$(make_validation "guest_ip_validation" "FAIL" \
                "$((ssh_fail + ssh_unreachable))/${sample_size} guest IP checks failed" "${ssh_details}")")
            overall_status="FAILED"
        else
            validations+=("$(make_validation "guest_ip_validation" "PASS" \
                "${ssh_pass}/${sample_size} VMs confirmed guest IP matches" "${ssh_details}")")
        fi
    fi

    local duration=$((SECONDS - start_time))
    echo
    echo "════════════════════════════════════════════════"
    echo "  check_requested_ip_udn ${overall_status} (${duration}s)"
    echo "════════════════════════════════════════════════"
    log_validation_end "${overall_status}" "${duration}"

    local validations_json
    validations_json=$(printf '%s\n' "${validations[@]}" | jq -s .)
    save_validation_report "requested-ip-udn" "${overall_status}" "${namespace}" \
        "${params_json}" "${validations_json}" "${results_dir}"

    [[ "${overall_status}" == "PASSED" ]]
}

retry_validation() {
    local validation_func="$1"
    shift
    local attempt result wait_time

    for ((attempt = 1; attempt <= MAX_RETRIES; attempt++)); do
        echo
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo "  Attempt ${attempt}/${MAX_RETRIES}: ${validation_func}"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

        if "${validation_func}" "$@"; then
            echo "  ${validation_func} completed successfully on attempt ${attempt}"
            return 0
        else
            result=$?
        fi
        if ((result == 2)); then
            echo "ERROR: permanent configuration error; validation will not be retried"
            return "${result}"
        fi
        if ((attempt == MAX_RETRIES)); then
            echo "  ${validation_func} failed after ${MAX_RETRIES} attempts"
            return 1
        fi

        if ((attempt < MAX_SHORT_WAITS)); then
            wait_time="${SHORT_WAIT}"
        else
            wait_time="${LONG_WAIT}"
        fi
        echo "  Waiting ${wait_time}s before retry"
        sleep "${wait_time}"
    done
}

main() {
    case "${1:-}" in
        check_requested_ip_udn)
            shift
            retry_validation check_requested_ip_udn "$@"
            ;;
        *)
            echo "Usage: $0 check_requested_ip_udn <label_key> <label_value> <namespace> <password> <vm_user> <results_dir> [key=value ...]"
            return 2
            ;;
    esac
}

if (($# >= 7)); then
    results_dir="$7"
    mkdir -p "${results_dir}"
    set +e
    main "$@" 2>&1 | tee "${results_dir}/validation.log"
    result=${PIPESTATUS[0]}
    exit "${result}"
fi

main "$@"
