#!/bin/bash

is_uint_in_range() {
    local value="$1"
    local minimum="$2"
    local maximum="$3"
    [[ "${value}" =~ ^[0-9]+$ ]] &&
        ((10#${value} >= minimum && 10#${value} <= maximum))
}

is_ipv4_prefix() {
    local prefix="$1"
    local first second third extra
    IFS=. read -r first second third extra <<<"${prefix}"

    [[ -z "${extra:-}" ]] &&
        is_uint_in_range "${first:-x}" 0 255 &&
        is_uint_in_range "${second:-x}" 0 255 &&
        is_uint_in_range "${third:-x}" 0 255
}

validate_config() {
    local udn_name="$1"
    local vm_count="$2"
    local ip_offset="$3"
    local subnet_prefix="$4"
    local validate_ssh="$5"
    local ssh_sample_percent="$6"
    local max_ssh_retries="$7"
    local ssh_retry_delay_seconds="$8"

    if [[ ! "${udn_name}" =~ ^[a-z0-9]([-a-z0-9]*[a-z0-9])?$ ]] ||
        ((${#udn_name} > 63)); then
        echo "ERROR: udnName must be a valid DNS label"
        return 2
    fi
    if ! is_uint_in_range "${vm_count}" 1 253; then
        echo "ERROR: vmCount must be between 1 and 253"
        return 2
    fi
    if ! is_uint_in_range "${ip_offset}" 1 254; then
        echo "ERROR: ipOffset must be between 1 and 254"
        return 2
    fi
    if ((10#${vm_count} + 10#${ip_offset} > 255)); then
        echo "ERROR: vmCount + ipOffset must not exceed 255"
        return 2
    fi
    if ! is_ipv4_prefix "${subnet_prefix}"; then
        echo "ERROR: subnetPrefix must contain three valid IPv4 octets"
        return 2
    fi
    if [[ "${validate_ssh}" != "true" && "${validate_ssh}" != "false" ]]; then
        echo "ERROR: validateSSH must be true or false"
        return 2
    fi
    if ! is_uint_in_range "${ssh_sample_percent}" 0 100; then
        echo "ERROR: sshSamplePercent must be between 0 and 100"
        return 2
    fi
    if ! is_uint_in_range "${max_ssh_retries}" 1 120; then
        echo "ERROR: maxSshRetries must be between 1 and 120"
        return 2
    fi
    if ! is_uint_in_range "${ssh_retry_delay_seconds}" 0 300; then
        echo "ERROR: sshRetryDelaySeconds must be between 0 and 300"
        return 2
    fi
}
