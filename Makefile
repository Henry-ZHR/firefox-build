.ONESHELL:
.SHELLFLAGS += -e


VERSION != cat version.txt

# From mozilla-central/python/mozboot/mozboot/android.py
export JAVA_HOME := $(MOZBUILD_STATE_PATH)/jdk/jdk-17.0.8+7

export APKSIGNER := $(ANDROID_SDK_ROOT)/build-tools/34.0.0/apksigner sign \
					   --ks ~/keystore.jks \
					   --ks-key-alias key


app-fenix-arm64-v8a-nightly-signed.apk: stages/sign-apk
	mv -f firefox-android/fenix/app/build/outputs/apk/fenix/nightly/app-fenix-arm64-v8a-nightly-signed.apk .
	touch $@

mozilla-central: version.txt
	pushd mozilla-central
	git reset --hard HEAD
	git fetch --all
	git checkout FIREFOX_NIGHTLY_$(VERSION)_END
	git apply --verbose ../fix-font.patch
	cp -f ../mozconfig .mozconfig
	popd
	touch $@

firefox-android: version.txt
	pushd firefox-android
	git reset --hard HEAD
	git fetch --all
	git checkout fenix-v$(VERSION).0b1
	pushd fenix
	cp -f ../../local.properties local.properties
	popd
	popd
	touch $@

stages/build-gv: mozilla-central
	pushd mozilla-central
	./mach build
	popd
	mkdir -p $(@D)
	touch $@

stages/build-apk: stages/build-gv firefox-android
	pushd firefox-android/fenix
	./gradlew --no-daemon clean app:assembleNightly
	popd
	mkdir -p $(@D)
	touch $@

stages/sign-apk: stages/build-apk
	pushd firefox-android/fenix/app/build/outputs/apk/fenix/nightly
	$(APKSIGNER) --out app-fenix-arm64-v8a-nightly-signed.apk app-fenix-arm64-v8a-nightly-unsigned.apk
	popd
	mkdir -p $(@D)
	touch $@
