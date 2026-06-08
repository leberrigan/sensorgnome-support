#! /bin/bash -e
DESTDIR=build-temp
rm -rf $DESTDIR
mkdir $DESTDIR

DEST=$DESTDIR/opt/sensorgnome/burstfinder
install -d $DEST
install -m 644 bursts src/LICENSE $DEST
BF_VERSION=1.0
aws s3 cp s3://sensorgnome-982081078525-us-east-1-an/burstfinder/burstfinder_${BF_VERSION}_arm_linux $DEST/burstfinder
chmod 755 $DEST/burstfinder

# Boilerplate package generation
cp -r DEBIAN $DESTDIR
sed -e "/^Version/s/:.*/: $(TZ=PST8PDT date +%Y.%j)/" -i $DESTDIR/DEBIAN/control # set version: YYYY.DDD
dpkg-deb -Zxz --root-owner-group --build $DESTDIR ../packages
# dpkg-deb --contents ../packages
ls -lh ../packages
