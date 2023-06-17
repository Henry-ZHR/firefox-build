#!/bin/bash

set -e

if [ $# -ne 1 ]; then
echo "Usage: ${0} <version>"
exit 1
fi

pushd mozilla-central
git fetch --all
git checkout FIREFOX_NIGHTLY_${1}_END
cp -f ../mozconfig .mozconfig
git apply --verbose ../fix-font.patch
./mach build
popd

pushd firefox-android
git fetch --all
git checkout fenix-v${1}.0b1
pushd fenix
cp -f ../../local.properties local.properties
JAVA_HOME="$MOZBUILD_STATE_PATH/jdk/jdk-17.0.7+7" ./gradlew clean app:assembleNightly
pushd app/build/outputs/apk/fenix/nightly
$ANDROID_SDK_ROOT/build-tools/34.0.0/apksigner sign \
  --ks ~/keystore.jks \
  --ks-key-alias key \
  --out app-fenix-arm64-v8a-nightly-signed.apk \
  app-fenix-arm64-v8a-nightly-unsigned.apk
popd
popd
popd

pushd mozilla-central
git reset --hard HEAD
popd
