.ONESHELL:
.SHELLFLAGS += -e


VERSION != cat version.txt

# From mozilla-central/python/mozboot/mozboot/android.py
export JAVA_HOME := $(MOZBUILD_STATE_PATH)/jdk/jdk-17.0.8+7

export APKSIGNER := $(ANDROID_SDK_ROOT)/build-tools/34.0.0/apksigner sign \
					   --ks ~/keystore.jks \
					   --ks-key-alias key

define BASE_MOZCONFIG
mk_add_options AUTOCLOBBER=1

ac_add_options --enable-project=mobile/android
ac_add_options --enable-linker=lld
ac_add_options --with-android-sdk=/home/zhr/Android/Sdk
ac_add_options --with-android-ndk=/home/zhr/Android/Sdk/ndk/23.2.8568313

ac_add_options --disable-debug
ac_add_options --enable-release
ac_add_options --enable-optimize
ac_add_options --enable-rust-simd
endef

define INSTRUMENTED_MOZCONFIG
$(BASE_MOZCONFIG)

ac_add_options --target=x86_64
ac_add_options --enable-profile-generate=cross
endef

define OPTIMIZED_MOZCONFIG
$(BASE_MOZCONFIG)

ac_add_options --target=aarch64
ac_add_options --enable-lto=cross
ac_add_options --enable-profile-use=cross
ac_add_options --with-pgo-profile-path=$(shell pwd=$$(pwd); echo $${pwd@Q})/pgo-profile/merged.profdata
ac_add_options --with-pgo-jarlog=$(shell pwd=$$(pwd); echo $${pwd@Q})/pgo-profile/jarlog
endef

export INSTRUMENTED_MOZCONFIG
export OPTIMIZED_MOZCONFIG


app-fenix-arm64-v8a-nightly-signed.apk: stages/sign-apk
	mv -f firefox-android/fenix/app/build/outputs/apk/fenix/nightly/app-fenix-arm64-v8a-nightly-signed.apk .
	touch $@

mozilla-central: version.txt
	pushd mozilla-central
	git reset --hard HEAD
	git fetch --all
	git checkout FIREFOX_NIGHTLY_$(VERSION)_END
	git apply --verbose ../fix-font.patch
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

stages/build-instrumented: mozilla-central
	pushd mozilla-central
	echo "$${INSTRUMENTED_MOZCONFIG}" >.mozconfig
	./mach build
	popd
	mkdir -p $(@D)
	touch $@

stages/run-profile: stages/build-instrumented
	pushd mozilla-central
	adb install obj-x86_64-unknown-linux-android/gradle/build/mobile/android/test_runner/outputs/apk/withGeckoBinaries/debug/test_runner-withGeckoBinaries-debug.apk
	adb shell appops set org.mozilla.geckoview.test_runner NO_ISOLATED_STORAGE allow
	rm -rf ../pgo-profile
	mkdir ../pgo-profile
	( source ../venv/bin/activate; python ../generate-pgo-profile.py ../pgo-profile )
	adb uninstall org.mozilla.geckoview.test_runner
	popd
	mkdir -p $(@D)
	touch $@

stages/build-optimized: stages/run-profile
	pushd mozilla-central
	echo "$${OPTIMIZED_MOZCONFIG}" >.mozconfig
	./mach build
	popd
	mkdir -p $(@D)
	touch $@

stages/build-apk: stages/build-optimized firefox-android
	pushd firefox-android/fenix
	./gradlew clean app:assembleNightly
	popd
	mkdir -p $(@D)
	touch $@

stages/sign-apk: stages/build-apk
	pushd firefox-android/fenix/app/build/outputs/apk/fenix/nightly
	$(APKSIGNER) --out app-fenix-arm64-v8a-nightly-signed.apk app-fenix-arm64-v8a-nightly-unsigned.apk
	popd
	mkdir -p $(@D)
	touch $@
