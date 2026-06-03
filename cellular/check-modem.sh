#! /bin/bash
# Configure and baby-sit cellular modem using mmcli (ModemManager)
# Expects to be run periodically, e.g. on a timer, but not too frequently, e.g. every 5 minutes
# at the shortest. If it does something it loops a few times to check the outcome and nudge
# things forward. Passing -r does only one pass and is used when the UI reconfighures the
# modem to avoid having multiple instances of this script running at the same time.
# If the configuration looks correct check-modem.sh will exit without doing anything.
# Not implemented: If -p is passed, it will actually ping 1.1.1.1 to check connectivity and reset the modem if
# it doesn't work. This is used by the uploading apps when they find that they don't have
# connectivity.

[[ "$1" == "-r" ]] && reconfigure=1  # reconfiguring

# Prevent concurrent runs (timer may fire while a previous instance is still connecting)
exec 9>/var/lock/check-modem.lock
flock -n 9 || exit 0

# Log this execution to a file
exec 6>&1
exec > >(tee /tmp/check-modem-new.log) 2>&1
date
function finish {
    exec 1>&6
    trap - EXIT
    mv /tmp/check-modem-new.log /tmp/check-modem.log
    rm -f /run/check-modem/busy
    systemctl start ModemManager 2>/dev/null || true  # no-op if already running; restores MM if we stopped it
    exit ${1:-1}
}
trap finish EXIT

# Signal to sg-control that check-modem is running so it defers mmcli calls
mkdir -p /run/check-modem
touch /run/check-modem/busy

# Log file recording every IMSI the SIM applet has presented; read by sg-control for the web UI
IMSI_LOG=/var/lib/sensorgnome/imsi-log
mkdir -p /var/lib/sensorgnome

# Load information from cellular config
if [[ -f /etc/sensorgnome/cellular.json ]]; then
    config=$(cat /etc/sensorgnome/cellular.json)
else
    echo '{"apn":"changeme","ip-type":"ipv4v6","allow-roaming":"yes","bad-imsi-prefixes":["23450"]}' >/etc/sensorgnome/cellular.json
    config=""
fi
apn=$(jq -r .apn <<<$config)
iptype=$(jq -r '.["ip-type"]' <<<$config)
roaming=$(jq -r '.["allow-roaming"]' <<<$config)
[[ -z $iptype ]] && iptype=ipv4v6

# Load operator preference (/etc/modem-operator.conf, OPERATOR=30210 or OPERATOR=auto)
operator_pref=auto
if [[ -f /etc/modem-operator.conf ]]; then
    source /etc/modem-operator.conf
    operator_pref="${OPERATOR:-auto}"
fi

# we could iterate through all modems, but for now we only do the last (see last() in jq expr)
eval $(mmcli -L -J | jq -j '.["modem-list"] | last | "modem=\(@sh)"')
if [[ "$modem" == null ]]; then
    echo "No modem found"
    exit 0
elif [[ -z "$modem" ]] && [[ $(mmcli -L 2>&1) == *find?the?ModemManager?process* ]]; then
    echo "ModemManager locked-up, restarting"
    systemctl restart ModemManager
    finish 1
fi

declare -a operators=()

# function to gather the modem state from ModemManager
function get_state {
    info=$(mmcli -J -m $m)
    if [[ -z "$info" ]]; then
        # oops, MM lost the modem??
        sleep 10
        info=$(mmcli -J -m $m)
        if [[ -z "$info" ]]; then
            echo "Lost modem, exiting"
            finish 1
        fi
    fi
    bearer=$(jq -r '.modem.generic.bearers[0]' <<<$info)  # bearers[0] is the latest, phew...
    state=$(jq -r .modem.generic.state <<<$info)
    oper=$(jq -r '.modem."3gpp"."operator-code" + " " + .modem."3gpp"."operator-name"' <<<$info)
    echo "Modem ${modem##*/} state: $state, APN: $apn $iptype, Operator: $oper"
    if [[ "$state" != "connected" ]]; then
        reason=$(jq -r '.modem.generic["state-failed-reason"]' <<<$info)
        more=$(jq -c '.modem["3gpp"]' <<<$info)
        #echo More: $more
        if [[ "$reason" == "--" ]]; then
            reason=$(jq -r '.["network-rejection-access-technology"] + " " + .["network-rejection-error"]' <<<$more)
        fi
        if [[ "$oper" == *-- ]]; then
            oper=$(jq -r '."operator-code" + " " + ."operator-name"' <<<$more)
        fi
        if [[ "$oper" == "-- --" ]]; then
            oper=$(jq -r '.["network-rejection-operator-id"] + " " + .["network-rejection-operator-name"]' <<<$more)
        fi
        msg=""
        [[ "$reason" != --* ]] && msg="$reason"
        [[ "$oper" != *-- ]] && msg="$msg / $oper"
        [[ -n "$msg" ]] && echo "Failure reason: $msg"
    fi
}

function get_scan {
    scan=$(mmcli -J -m $m --timeout=120 --3gpp-scan)
    if [[ "$scan" == *operator-code* ]]; then
        filter='.modem."3gpp"."scan-networks" | map(select(.availability == "available")) |'
        filter="$filter "' map(."operator-code") | unique | join(" ")'
        operators=($(jq -j "$filter" <<<$scan))
        echo "Found ${#operators[@]} available operators: ${operators[*]}"
    else
        echo "Found no available operators"
    fi
}

# handle APN auto-detection for some SIM cards
iccid=""
if [[ -n "$modem" ]]; then
    sim=$(mmcli -J -m $modem | jq -r .modem.generic.sim)
    iccid=$(mmcli -m $modem -i $sim -K | grep 'iccid' | sed -e 's/.*: *//')
    if [[ -z "$apn" ]]; then
        # Twilio / sixfab "super SIM"
        if [[ $iccid == 8988307* ]] || [[ $iccid == 8988323* ]]; then
            echo "Twilio super SIM detected, using APN=super"
            apn=super
            iptype=ipv4v6
            roaming=yes
            echo '{"apn":"super","ip-type":"ipv4v6","allow-roaming":"yes","bad-imsi-prefixes":["23450"]}' >/etc/sensorgnome/cellular.json
        fi
    fi
fi

# Determine which IMSI prefixes should trigger RF cycling to pick a different SIM profile.
# Explicit config (bad-imsi-prefixes in cellular.json) takes priority.
# Falls back to a per-SIM-type default: Sixfab multi-IMSI SIMs default to no prefixes —
# operators deploying in regions where specific profiles fail should set this in cellular.json.
# Example: '{"bad-imsi-prefixes":["23450"]}' skips Jersey Telecom profiles (use in Canada).
bad_imsi_prefixes=()
if jq -e '.["bad-imsi-prefixes"]' <<<$config &>/dev/null; then
    mapfile -t bad_imsi_prefixes < <(jq -r '.["bad-imsi-prefixes"][]' <<<$config 2>/dev/null)
fi

# Ensure SIM Toolkit is enabled so the SIM applet can switch profiles on RF cycling.
# IMSI check runs every boot (/run marker); STK check is one-time (/etc marker).
stk_marker=/etc/sensorgnome/stk_enabled
imsi_marker=/run/check-modem/imsi_ok

if [[ ! -f "$stk_marker" ]] || [[ ! -f "$imsi_marker" ]]; then
    atcom_bin=$(command -v atcom 2>/dev/null)
    [[ -z "$atcom_bin" ]] && atcom_bin=$(find /usr /opt -name atcom -type f 2>/dev/null | head -1)
    if [[ -z "$atcom_bin" ]]; then
        echo "atcom not found, skipping STK/IMSI check"
    else
        systemctl stop ModemManager
        sleep 2

        if [[ ! -f "$stk_marker" ]]; then
            stk_resp=$("$atcom_bin" AT+QSTK? 2>&1)
            echo "AT+QSTK? response: $stk_resp"
            stk_val=$(echo "$stk_resp" | grep -oE '\+QSTK: [0-9]' | grep -oE '[0-9]$')
            if [[ "$stk_val" == "0" ]]; then
                echo "Enabling SIM Toolkit"
                "$atcom_bin" "AT+QSTK=1,0,300"
                sleep 1
            else
                echo "SIM Toolkit already enabled (val=$stk_val)"
            fi
            touch "$stk_marker"
        fi

        if [[ ${#bad_imsi_prefixes[@]} -gt 0 ]]; then
            echo "Bad IMSI prefixes: ${bad_imsi_prefixes[*]}"
            for attempt in $(seq 1 10); do
                imsi=$("$atcom_bin" AT+CIMI 2>&1 | grep -oE '[0-9]{14,15}')
                echo "IMSI attempt $attempt: ${imsi:-none}"
                [[ -n "$imsi" ]] && printf '%s\t%s\n' "$(date -u +%s)" "$imsi" >> "$IMSI_LOG"
                bad_match=""
                for prefix in "${bad_imsi_prefixes[@]}"; do
                    [[ "$imsi" == "${prefix}"* ]] && bad_match="$prefix" && break
                done
                if [[ -n "$imsi" ]] && [[ -z "$bad_match" ]]; then
                    echo "Good IMSI: $imsi"
                    touch "$imsi_marker"
                    break
                fi
                echo "IMSI ${imsi:-none} matches bad prefix ${bad_match:-none}, cycling RF (AT+CFUN=0/1)"
                "$atcom_bin" "AT+CFUN=0"
                sleep 5
                "$atcom_bin" "AT+CFUN=1"
                sleep 20
            done
            [[ ! -f "$imsi_marker" ]] && echo "WARNING: failed to get acceptable IMSI after 10 attempts"
        else
            echo "No bad-imsi-prefixes configured, logging current IMSI"
            imsi=$("$atcom_bin" AT+CIMI 2>&1 | grep -oE '[0-9]{14,15}')
            echo "Current IMSI: ${imsi:-unknown}"
            [[ -n "$imsi" ]] && printf '%s\t%s\n' "$(date -u +%s)" "$imsi" >> "$IMSI_LOG"
            touch "$imsi_marker"
        fi

        systemctl start ModemManager
        sleep 15
        eval $(mmcli -L -J | jq -j '.["modem-list"] | last | "modem=\(@sh)"')
    fi
fi

count=0 # iteration count, if > 0 we're reconnecting
while [[ -n "$modem" ]]; do
    m=$(basename $modem)
    count=$((count+1))
    if (( $count > 1 )); then
        [[ -n "$reconfigure" ]] && exit 0  # don't loop if we're reconfiguring
        if (( $count > 5 )); then
            mmcli -m $m --timeout=120 --3gpp-scan
            # the following commands are Quectel specific and report network scan results
            # with rsrp / rsrq values, however, only partial results are returned if sg-control
            # tries to scan at the same time
            # if [[ $(mmcli -J -m $m | jq -r .modem.generic.plugin) == quectel ]]; then
            #     mmcli -m a --command='AT+QOPSCFG="displayrssi,1"'
            #     mmcli -m a --command='AT+QCFG="nwscanmode",0'
            #     mmcli -m a --timeout=120 --command='AT+QOPS'
            # fi
            exit 1  # we'll come back in a few minutes...
        fi
        eval $(mmcli -L -J | jq -j '.["modem-list"] | last | "modem=\(@sh)"')
        m=$(basename $modem)
    fi

    get_state
    if [[ "$state" == connected ]] && [[ "$bearer" != null ]]; then
        # Got a bearer, ensure we actually have connectivity and can pass data

        # Check that we have the correct APN
        binfo=$(mmcli -J -m $m -b $bearer)
        cur_apn=$(jq -r .bearer.properties.apn <<<$binfo)
        if [[ "$cur_apn" != "$apn" ]]; then
            echo "Configured APN is $apn, disconnecting bearer"
            mmcli -m $m --simple-disconnect
            sleep 2
            continue
        fi

        # Check that we have a default route
        defrt=$(ip route show default)
        iface=$(jq -r .bearer.status.interface <<<$binfo)
        if [[ "$iface" == ttyUSB* ]]; then
            net=$(jq -r '.modem.generic.ports | last | sub(" .*"; "")' <<<$info)
            echo "Interface $iface -> $net"
            iface=$net
        fi
        if ! grep -e "$iface" <<<$defrt; then
            if (( $count == 1 )); then
                echo "No default route via $iface, resetting modem"
                mmcli -m $m --reset
                sleep 30
            else
                echo "No default route via $iface, waiting..."
                sleep 2
            fi
            continue
        fi
        
        # If we're *the* default route, check that we have traffic in the past 90 minutes
        vnstat=$(vnstat -i $iface --json f 18)
        rx=$(jq -c '.interfaces[0].traffic.fiveminute | map(.rx) | add' <<<$vnstat) || \
            echo "Error getting RX bytes from vnstat: $vnstat"
        echo "RX bytes in last 90 minutes: $rx"
        dr=$(ip route get 1.1.1.1)
        if [[ "$dr" = *${iface}* ]]; then
            echo "Default route uses $iface"
            if (( $rx < 10240 )); then
                echo "No traffic in last 90 minutes, pinging 1.1.1.1"
                if ping -n -c 20 -I $iface 1.1.1.1 | grep -q ' 0 received'; then
                    echo "Resetting modem"
                    mmcli -m $m --reset
                    finish 1
                else
                    echo "Ping OK"
                fi
            fi
        else
            dr=$(echo $dr | sed -e 's/.*dev \([^ ]*\).*/\1/')
            echo "System default route is via $dr, not $iface (OK)"
        fi

        # Ensure we're getting signal info
        if [[ $(mmcli -m $m) != *20?seconds* ]]; then
            mmcli -m $m --signal-setup=20
        fi

        #echo "Modem $m is OK"
        finish 0
    fi

    # Not connected or the bearer doesn't work. In either case, we need to (re-)connect

    # if there is a bearer then disconnect it
    if [[ "$bearer" != null ]]; then
        #echo Disconnecting existing bearer
        mmcli -m $m --simple-disconnect
        sleep 2
    fi

    # check that ModemManager is using the QMI interface
    drivers=$(jq -r '.modem.generic.drivers' <<<$info)
    priport=$(jq -r '.modem.generic["primary-port"]' <<<$info)
    if [[ "$drivers" = *qmi_wwan* ]] && [[ "$priport" != cdc-wdm* ]]; then
        echo "Modem supports QMI but using $priport: resetting modem"
        mmcli -m $m --reset
        sleep 30
        continue
    fi

    # ensure modem is enabled
    if [[ "$state" == disabled ]]; then
        echo "Enabling modem"
        mmcli -m $m -e
        sleep 2
    fi

    #
    if [[ $count == 1 ]]; then
        mmcli -m $m --3gpp-set-initial-eps-bearer-settings="apn=$apn,ip-type=$iptype,allow-roaming=$roaming"
        mmcli -m $m --signal-setup=0
        sleep 1
    fi

    # Make a connection attempt
    date
    if [[ $count -gt 1 ]] && [[ $state != connected ]] && [[ $state != registered ]]; then
        if [[ "$operator_pref" != "auto" ]]; then
            echo "#$count: Registering with configured operator $operator_pref"
            mmcli -m $m --timeout=120 --3gpp-register-in-operator=$operator_pref
            continue
        fi
        if [[ ${#operators[*]} == 0 ]]; then
            echo "#$count: Performing a scan"
            get_scan
        fi
        if [[ ${#operators[*]} -gt 0 ]]; then
            ix=$(( $RANDOM % ${#operators[*]} ))
            oper="${operators[$ix]}"
            echo "#$count: Registering with operator $oper"
            mmcli -m $m --timeout=120 --3gpp-register-in-operator=$oper
            continue
        fi
    fi
    echo "#$count: Connecting modem $m, apn=$apn ip-type=$iptype allow-roaming=$roaming"
    err=$(mmcli -m $m --timeout=120 --simple-connect="apn=$apn,ip-type=$iptype,allow-roaming=$roaming" 2>&1)
    if [[ "$err" == *InProgress* ]]; then
        echo "  connection attempt already in progress??"
        finish 1
    fi

done
