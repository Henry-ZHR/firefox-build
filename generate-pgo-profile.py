"""
Generate the PGO profile data

Modified from mozilla-central/testing/mozharness/scripts/android_emulator_pgo.py
"""

import glob
import json
import os
import posixpath
import subprocess
import sys
import time

from marionette_driver.marionette import Marionette
from mozdevice import ADBDeviceFactory, ADBTimeoutError
from mozhttpd import MozHttpd
from mozprofile import Preferences
from six import string_types

PAGES = [
    "js-input/webkit/PerformanceTests/Speedometer/index.html",
    "blueprint/sample.html",
    "blueprint/forms.html",
    "blueprint/grid.html",
    "blueprint/elements.html",
    "js-input/3d-thingy.html",
    "js-input/crypto-otp.html",
    "js-input/sunspider/3d-cube.html",
    "js-input/sunspider/3d-morph.html",
    "js-input/sunspider/3d-raytrace.html",
    "js-input/sunspider/access-binary-trees.html",
    "js-input/sunspider/access-fannkuch.html",
    "js-input/sunspider/access-nbody.html",
    "js-input/sunspider/access-nsieve.html",
    "js-input/sunspider/bitops-3bit-bits-in-byte.html",
    "js-input/sunspider/bitops-bits-in-byte.html",
    "js-input/sunspider/bitops-bitwise-and.html",
    "js-input/sunspider/bitops-nsieve-bits.html",
    "js-input/sunspider/controlflow-recursive.html",
    "js-input/sunspider/crypto-aes.html",
    "js-input/sunspider/crypto-md5.html",
    "js-input/sunspider/crypto-sha1.html",
    "js-input/sunspider/date-format-tofte.html",
    "js-input/sunspider/date-format-xparb.html",
    "js-input/sunspider/math-cordic.html",
    "js-input/sunspider/math-partial-sums.html",
    "js-input/sunspider/math-spectral-norm.html",
    "js-input/sunspider/regexp-dna.html",
    "js-input/sunspider/string-base64.html",
    "js-input/sunspider/string-fasta.html",
    "js-input/sunspider/string-tagcloud.html",
    "js-input/sunspider/string-unpack-code.html",
    "js-input/sunspider/string-validate-input.html",
]

if __name__ == "__main__":
    if len(sys.argv) != 2:
        print(f"Usage: {sys.argv[0]} <workdir>")
        exit(1)
    workdir = sys.argv[1]

    app = "org.mozilla.geckoview.test_runner"

    IP = "127.0.0.1"
    PORT = 8888

    PATH_MAPPINGS = {
        "/js-input/webkit/PerformanceTests":
        "third_party/webkit/PerformanceTests",
    }

    topsrcdir = os.getcwd()

    path_mappings = {
        k: os.path.join(topsrcdir, v)
        for k, v in PATH_MAPPINGS.items()
    }
    httpd = MozHttpd(
        port=PORT,
        docroot=os.path.join(topsrcdir, "build", "pgo"),
        path_mappings=path_mappings,
    )
    httpd.start(block=False)

    profile_data_dir = os.path.join(topsrcdir, "testing", "profiles")
    with open(os.path.join(profile_data_dir, "profiles.json"), "r") as fh:
        base_profiles = json.load(fh)["profileserver"]

    prefpaths = [
        os.path.join(profile_data_dir, profile, "user.js")
        for profile in base_profiles
    ]

    prefs = {}
    for path in prefpaths:
        prefs.update(Preferences.read_prefs(path))

    interpolation = {
        "server": "%s:%d" % httpd.httpd.server_address,
        "OOP": "false"
    }
    for k, v in prefs.items():
        if isinstance(v, string_types):
            v = v.format(**interpolation)
        prefs[k] = Preferences.cast(v)

    outputdir = "/sdcard/pgo_profile"
    jarlog = posixpath.join(outputdir, "jarlog")
    profdata = posixpath.join(outputdir, "default_%p_random_%m.profraw")

    env = {}
    env["XPCOM_DEBUG_BREAK"] = "warn"
    env["MOZ_IN_AUTOMATION"] = "1"
    env["MOZ_JAR_LOG_FILE"] = jarlog
    env["LLVM_PROFILE_FILE"] = profdata

    os.environ["MINIDUMP_STACKWALK"] = os.path.join(
        os.environ.get("MOZBUILD_STATE_PATH"), "minidump-stackwalk")
    os.environ["MINIDUMP_SAVE_PATH"] = os.path.join(workdir,
                                                    "blobber_upload_dir")
    symbols_path = os.environ["MOZBUILD_STATE_PATH"]

    # Force test_root to be on the sdcard for android pgo
    # builds which fail for Android 4.3 when profiles are located
    # in /data/local/tmp/test_root with
    # E AndroidRuntime: FATAL EXCEPTION: Gecko
    # E AndroidRuntime: java.lang.IllegalArgumentException: \
    #    Profile directory must be writable if specified: /data/local/tmp/test_root/profile
    # This occurs when .can-write-sentinel is written to
    # the profile in
    # mobile/android/geckoview/src/main/java/org/mozilla/gecko/GeckoProfile.java.
    # This is not a problem on later versions of Android. This
    # over-ride of test_root should be removed when Android 4.3 is no
    # longer supported.
    sdcard_test_root = "/sdcard/test_root"
    adbdevice = ADBDeviceFactory(device='emulator-5554',
                                 test_root=sdcard_test_root)
    if adbdevice.test_root != sdcard_test_root:
        # If the test_root was previously set and shared
        # the initializer will not have updated the shared
        # value. Force it to match the sdcard_test_root.
        adbdevice.test_root = sdcard_test_root
    adbdevice.mkdir(outputdir, parents=True)

    try:
        # Run Fennec a first time to initialize its profile
        driver = Marionette(
            app="fennec",
            package_name=app,
            bin=
            "obj-x86_64-unknown-linux-android/gradle/build/mobile/android/test_runner/outputs/apk/withGeckoBinaries/debug/test_runner-withGeckoBinaries-debug.apk",
            prefs=prefs,
            connect_to_running_emulator=True,
            startup_timeout=1000,
            env=env,
            symbols_path=symbols_path,
        )
        driver.start_session()

        adbdevice.reverse(f"tcp:{PORT}", f"tcp:{PORT}")

        # Now generate the profile and wait for it to complete
        for page in PAGES:
            driver.navigate("http://%s:%d/%s" % (IP, PORT, page))
            timeout = 2
            if "Speedometer/index.html" in page:
                # The Speedometer test actually runs many tests internally in
                # javascript, so it needs extra time to run through them. The
                # emulator doesn't get very far through the whole suite, but
                # this extra time at least lets some of them process.
                timeout = 120  # Actually this is enough
            time.sleep(timeout)

        driver.set_context("chrome")
        driver.execute_script("""
            let cancelQuit = Components.classes["@mozilla.org/supports-PRBool;1"]
                .createInstance(Components.interfaces.nsISupportsPRBool);
            Services.obs.notifyObservers(cancelQuit, "quit-application-requested", null);
            return cancelQuit.data;
        """)
        driver.execute_script("""
            Services.startup.quit(Ci.nsIAppStartup.eAttemptQuit)
        """)

        # There is a delay between execute_script() returning and the profile data
        # actually getting written out, so poll the device until we get a profile.
        for i in range(50):
            if not adbdevice.process_exist(app):
                break
            time.sleep(2)
        else:
            raise Exception("Android App (%s) never quit" % app)

        # Pull all the profraw files and en-US.log
        adbdevice.pull(outputdir, workdir)
    except ADBTimeoutError:
        print("INFRA-ERROR: Failed with an ADBTimeoutError", file=stderr)
        exit(1)

    profraw_files = glob.glob(os.path.join(workdir, "*.profraw"))
    if not profraw_files:
        print("Could not find any profraw files", file=stderr)
        exit(1)
    merge_cmd = [
        os.path.join(os.environ["MOZBUILD_STATE_PATH"],
                     "clang/bin/llvm-profdata"),
        "merge",
        "-o",
        os.path.join(workdir, "merged.profdata"),
    ] + profraw_files
    rc = subprocess.call(merge_cmd)
    if rc != 0:
        print("INFRA-ERROR: Failed to merge profile data. Corrupt profile?",
              file=stderr)
        exit(1)

    adbdevice.rm(sdcard_test_root, recursive=True)
    adbdevice.rm(outputdir, recursive=True)

    httpd.stop()
