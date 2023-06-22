#!/bin/bash

set -e

if [ $# -ne 1 ]; then
echo "Usage: ${0} <version>"
exit 1
fi


pushd mozilla-central

git reset --hard HEAD
git fetch --all
git checkout FIREFOX_NIGHTLY_${1}_END
git apply --verbose ../fix-font.patch

cat >.mozconfig ../mozconfig - <<END
ac_add_options --target=x86_64
ac_add_options --with-ccache=sccache
ac_add_options --enable-profile-generate=cross
END
./mach build
adb install obj-x86_64-unknown-linux-android/gradle/build/mobile/android/test_runner/outputs/apk/withGeckoBinaries/debug/test_runner-withGeckoBinaries-debug.apk
adb shell appops set org.mozilla.geckoview.test_runner NO_ISOLATED_STORAGE allow
pgo_profile_dir=$(mktemp -d)
(
  source ../venv/bin/activate
  python ../generate-pgo-profile.py ${pgo_profile_dir}
)
adb uninstall org.mozilla.geckoview.test_runner
adb kill-server

cat >.mozconfig ../mozconfig - <<END
ac_add_options --target=aarch64
ac_add_options --enable-lto=cross
ac_add_options --enable-profile-use=cross
ac_add_options --with-pgo-profile-path=${pgo_profile_dir@Q}/merged.profdata
ac_add_options --with-pgo-jarlog=${pgo_profile_dir@Q}/jarlog
END
./mach clobber
./mach build

popd


pushd firefox-android
git reset --hard HEAD
git fetch --all
git checkout fenix-v${1}.0b1
pushd fenix
cp -f ../../local.properties local.properties
JAVA_HOME="$MOZBUILD_STATE_PATH/jdk/jdk-17.0.7+7" ./gradlew clean app:assembleNightly
./gradlew --stop
pushd app/build/outputs/apk/fenix/nightly
$ANDROID_SDK_ROOT/build-tools/34.0.0/apksigner sign \
  --ks ~/keystore.jks \
  --ks-key-alias key \
  --out app-fenix-arm64-v8a-nightly-signed.apk \
  app-fenix-arm64-v8a-nightly-unsigned.apk
popd
popd
popd

cp -f firefox-android/fenix/app/build/outputs/apk/fenix/nightly/app-fenix-arm64-v8a-nightly-signed.apk .
