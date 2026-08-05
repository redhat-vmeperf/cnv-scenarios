#!/bin/bash
#
# Auto-detect available network interfaces on worker nodes
# Returns the first unused physical interface that can be used for NIC hot-plug testing
#
# Uses NodeNetworkState (NNS) CRs from NMState instead of oc debug pods,
# which is 100x faster and doesn't require pod scheduling.
#

WORKER_NODES=$(oc get nodes -l node-role.kubernetes.io/worker= -o jsonpath='{.items[*].metadata.name}' 2>/dev/null)

if [ -z "$WORKER_NODES" ]; then
    echo "ERROR: No worker nodes found" >&2
    exit 1
fi

check_interface_available() {
    local node=$1
    local interface=$2

    local nns_json
    nns_json=$(oc get nns "$node" -o json 2>/dev/null) || return 1

    local iface_json
    iface_json=$(echo "$nns_json" | python3 -c "
import sys, json
data = json.load(sys.stdin)
ifaces = data.get('status', {}).get('currentState', {}).get('interfaces', [])
for i in ifaces:
    if i.get('name') == '$interface':
        json.dump(i, sys.stdout)
        sys.exit(0)
sys.exit(1)
" 2>/dev/null) || return 1

    # Check if interface has an IPv4 address (skip if it does)
    if echo "$iface_json" | python3 -c "
import sys, json
i = json.load(sys.stdin)
addrs = i.get('ipv4', {}).get('address', [])
if addrs:
    sys.exit(0)
sys.exit(1)
" 2>/dev/null; then
        return 1
    fi

    # Check if interface is part of a bridge (has controller/master)
    if echo "$iface_json" | python3 -c "
import sys, json
i = json.load(sys.stdin)
if i.get('controller') or i.get('bridge', {}).get('port'):
    sys.exit(0)
sys.exit(1)
" 2>/dev/null; then
        return 1
    fi

    return 0
}

get_physical_interfaces() {
    local node=$1
    oc get nns "$node" -o json 2>/dev/null | python3 -c "
import sys, json
data = json.load(sys.stdin)
ifaces = data.get('status', {}).get('currentState', {}).get('interfaces', [])
for i in ifaces:
    name = i.get('name', '')
    itype = i.get('type', '')
    if itype == 'ethernet' and (name.startswith('ens') or name.startswith('enp') or name.startswith('eth') or name.startswith('em')):
        print(name)
" 2>/dev/null
}

echo "Detecting available interfaces on worker nodes..." >&2

FIRST_NODE=$(echo "$WORKER_NODES" | awk '{print $1}')

# Verify NMState NNS resources are available
if ! oc get nns "$FIRST_NODE" &>/dev/null; then
    echo "ERROR: NodeNetworkState not found for $FIRST_NODE (is NMState installed?)" >&2
    exit 1
fi

echo "Checking node: $FIRST_NODE" >&2
CANDIDATE_INTERFACES=$(get_physical_interfaces "$FIRST_NODE")

if [ -z "$CANDIDATE_INTERFACES" ]; then
    echo "ERROR: No physical interfaces found on node $FIRST_NODE" >&2
    exit 1
fi

echo "Candidate interfaces: $CANDIDATE_INTERFACES" >&2

for interface in $CANDIDATE_INTERFACES; do
    echo "Checking interface: $interface" >&2

    available_on_all=true

    for node in $WORKER_NODES; do
        if ! check_interface_available "$node" "$interface"; then
            echo "  Interface $interface not available on node $node" >&2
            available_on_all=false
            break
        fi
    done

    if [ "$available_on_all" = true ]; then
        echo "Found available interface: $interface" >&2
        echo "$interface"
        exit 0
    fi
done

echo "ERROR: No available interface found across all worker nodes" >&2
echo "Available interfaces on $FIRST_NODE:" >&2
get_physical_interfaces "$FIRST_NODE" | while read -r iface; do
    echo "  - $iface" >&2
done
echo "Please specify baseInterface manually" >&2
exit 1
