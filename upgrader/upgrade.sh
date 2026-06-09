#! /bin/bash -e
# Upgrade the SG software using apt. Expects a list of packages as arguments. If passed a
# -s flag will also upgrade system packages.

if [[ "$#" == 0 ]]; then
    echo "Usage: $0 <package1> <package2> ..."
    echo "or     $0 -s  # upgrade all packages"
    exit 1
fi

date
set -x

if [[ "$1" == -s ]]; then
    CMD="apt-get -y -o Dpkg::Options::="--force-confold" --autoremove upgrade"
else
    CMD="apt-get -y -o Dpkg::Options::="--force-confold" --autoremove install $@"
fi

# need to use systemd-run so it runs outside of the sg-control service cgroup, which may get
# restarted as part of the upgrade and we don't want to be affected by that
#TERM=dumb systemd-run --scope --collect --pipe --description="sg-upgrade" $CMD
TERM=dumb systemd-run --wait --pipe --collect --description="sg-upgrade" \
    -E DEBIAN_FRONTEND=noninteractive $CMD
echo "_END_"
echo "Scheduling sg-control restart in 4 seconds..."
# Schedule the restart outside our cgroup so upgrade.sh can exit cleanly first.
# upgrade.sh is in sg-control's systemd cgroup; a synchronous restart would kill this
# script before it exits, causing machine.js to never see exit code 0.
systemd-run --no-block --collect --description="sg-post-upgrade-restart" \
    /bin/bash -c 'sleep 4; systemctl daemon-reload; systemctl restart sg-control.service'
