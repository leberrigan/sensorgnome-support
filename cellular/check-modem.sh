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

# Log this execution to a file
exec 6>&1
exec > >(tee /tmp/check-modem-new.log) 2>&1
date
function finish {
    exec 1>&6
    trap - EXIT
    mv /tmp/check-modem-new.log /tmp/check-modem.log
    exit ${1:-1}
}
trap finish EXIT

# Load information from cellular config
if [[ -f /etc/sensorgnome/cellular.json ]]; then
    config=$(cat /etc/sensorgnome/cellular.json)
else
    echo '{"apn":"changeme","ip-type":"ipv4v6","allow-roaming":"yes"}' >/etc/sensorgnome/cellular.json
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
if [[ -n "$modem" ]] && [[ -z "$apn" ]]; then
    # Pre-configured APNs...
    sim=$(mmcli -J -m $modem | jq -r .modem.generic.sim)
    iccid=$(mmcli -m $modem -i $sim -K | grep 'iccid' | sed -e 's/.*: *//')
    # Twilio / sixfab "super SIM"
    if [[ $iccid == 8988307* ]] || [[ $iccid == 8988323* ]]; then
        echo "Twilio super SIM detected, using APN=super"
        apn=super
        iptype=ipv4v6
        roaming=yes
        echo '{"apn":"super","ip-type":"ipv4v6","allow-roaming":"yes"}' >/etc/sensorgnome/cellular.json
    fi    
fi

imsi_ok=0
imsi_cycles=0
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

    # Check IMSI for multi-IMSI SIMs; cycle RF if Jersey Telecom IMSI (23450x) is active
    if [[ $imsi_ok -eq 0 ]] && [[ "$state" != disabled ]] && [[ "$state" != unknown ]]; then
        imsi=$(mmcli -m $m --command="AT+CIMI" 2>/dev/null | grep -oE '[0-9]{10,}' | head -1)
        if [[ "$imsi" == 23450* ]]; then
            imsi_cycles=$((imsi_cycles + 1))
            if [[ $imsi_cycles -le 3 ]]; then
                echo "Jersey Telecom IMSI ($imsi) detected, cycling RF ($imsi_cycles/3)"
                mmcli -m $m --command="AT+CFUN=0"
                sleep 5
                mmcli -m $m --command="AT+CFUN=1"
                sleep 10
                continue
            else
                echo "Jersey Telecom IMSI persists after $imsi_cycles RF cycles, proceeding anyway"
            fi
        else
            [[ -n "$imsi" ]] && echo "IMSI: $imsi"
        fi
        imsi_ok=1
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
