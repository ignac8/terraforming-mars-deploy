# Android app (offline)

A standalone Android APK of Terraforming Mars: the game server, its database,
the web client and a Node.js runtime, all inside one app. Nothing talks to
the network, so it plays on a plane. Games are single-device: every seat in a
game is played from this phone (or the game is set up solo / against MarsBot).

## How it works

```
APK
├── lib/<abi>/libnode.so          nodejs-mobile v18.20.4 (a Node.js built for Android)
├── lib/<abi>/libnative-lib.so    JNI glue: NodeRuntime.startNode() → node::Start()
└── assets/nodejs-project.zip     unzipped into the app's files dir on first launch:
    ├── main.js                   launcher: polyfills, env, chdir, require('./server.js')
    ├── server.js                 the game server, esbuild-bundled into one file
    ├── build/                    client bundle (main.js, vendors.js, chunks/) + styles.css
    ├── assets/                   images, fonts, index.html
    └── db/files/                 the LocalFilesystem database (created at runtime, kept across updates)
```

- `MainActivity` picks a free port, unpacks the project out of the APK (only
  when the app version changed; `db/` is left alone), starts Node on its own
  thread and shows a full-screen `WebView` on `http://127.0.0.1:<port>/` once
  the server answers. The last page is remembered, so reopening the app lands
  back in the game. Back navigates the WebView; links off the server open in
  the system browser.
- The server runs exactly the code of the game checkout, configured through
  the environment the launcher sets: `HOST=127.0.0.1`, `LOCAL_FS_DB` (the
  JSON-files database), `NODE_ENV=production`. No game-repo changes are
  needed for the app.
- nodejs-mobile only ships Node 18, so `main.js` polyfills the ES2023
  array methods (`toSorted` and friends) the server uses, and `build-apk.sh`
  bundles the server with esbuild because Node 18 cannot `require()` the
  ESM-only packages (`uuid`, `html-escaper`, `ansi-escape-sequences`) the
  server depends on. The native database drivers (`pg`, `better-sqlite3`)
  are replaced by empty stubs; the app never uses them.

## Building

Prerequisites:

- Node from the game checkout's `.nvmrc` (`nvm use`), `curl`, `unzip`.
- JDK 17 or newer (`keytool` comes with it).
- An Android SDK at `ANDROID_HOME` with `cmdline-tools/latest`; the script
  installs `platforms;android-35`, `build-tools;35.0.0`, `ndk;27.2.12479018`
  and `cmake;3.22.1` through `sdkmanager` when they are missing (about 3 GB).
- The game checkout next to this repo (`../terraforming-mars`, the same
  layout `update.sh` uses), or `MAIN_CHECKOUT=/path/to/checkout`.

```bash
export ANDROID_HOME=~/android-sdk
android/build-apk.sh                  # npm ci + npm run build in the checkout, then the APK
SKIP_GAME_BUILD=1 android/build-apk.sh   # reuse the checkout's existing build/
ANDROID_ABIS=arm64-v8a,x86_64 android/build-apk.sh   # add an emulator ABI (about 65 MB more)
```

The APK lands in `android/out/` as `terraforming-mars-<date>-<game sha>.apk`
(and a copy named `terraforming-mars.apk`). The first build downloads
Gradle, the Android Gradle plugin and the nodejs-mobile zip (57 MB, cached
in `android/.cache/`).

`android/smoke-test.sh` boots the assembled project (`android/build/nodejs-project`)
with the `node` on PATH, fetches the client bundle, creates a game, plays
its first move, restarts the server and finds the game again behind the
same player id. Run it under Node 18 (`nvm use 18`) to exercise the runtime
major the app embeds; CI does the same after every build.

### GitHub Actions

`.github/workflows/android-apk.yml` builds the same thing on GitHub. Run it
from the Actions tab (the `game_ref` input picks the game branch, default
`automa`); it uploads the APK as a workflow artifact and, for manual runs,
publishes it on the rolling `android-latest` release, so the phone can
download `terraforming-mars.apk` from that release page directly. It also
runs on pushes to `main` that touch `android/`.

### Signing

Android installs an update only over an app signed with the same key. The
build signs with `android/keystore/release.jks` (gitignored) and generates
that keystore on the first run; keep it, or pass your own through
`ANDROID_KEYSTORE`, `ANDROID_KEYSTORE_PASSWORD`, `ANDROID_KEY_ALIAS` and
`ANDROID_KEY_PASSWORD`. For CI, store the same keystore in the repository
secrets `ANDROID_KEYSTORE_BASE64` (`base64 -w0 release.jks`),
`ANDROID_KEYSTORE_PASSWORD`, `ANDROID_KEY_ALIAS` and `ANDROID_KEY_PASSWORD`;
without them every CI build signs with a fresh throwaway key and the phone
needs an uninstall before it takes the next one (saved games go with it).

## Installing and playing

1. Copy the APK to the phone (or open the release link in its browser) and
   open it; allow installs from that source when Android asks.
2. Start the app; the first launch takes a few seconds longer while it
   unpacks the project. Create a game as usual.
3. The client is laid out for a 1260px desktop viewport and is scaled to the
   screen; pinch to zoom. A tablet, or a phone in landscape, is the
   comfortable size.

Saved games live in the app's private storage
(`/data/data/it.zerko.terraformingmars/files/nodejs-project/db/files/`) and
survive app updates; uninstalling the app deletes them. The server's log is
in logcat: `adb logcat -s TerraformingMars`.

## Known limits

- **Node 18.** nodejs-mobile's newest release is v18.20.4 (October 2024).
  Anything in the server that needs a newer runtime shows up as a crash in
  logcat at start; add the missing shim to `nodejs-project/main.js`.
- **4 KB page size only.** The prebuilt `libnode.so` is aligned for 4 KB
  memory pages. Devices whose kernel runs with 16 KB pages (a setting some
  Android 15+ devices ship with) refuse to load it; there the fix is a
  nodejs-mobile rebuild with 16 KB alignment, which this repo does not do.
- **One runtime per process.** Node cannot be restarted inside a process,
  so the app keeps one server for its lifetime. Android may kill the app in
  the background; the next launch starts a fresh server and reopens the
  last page. Every action is saved to disk before it is acknowledged, so
  nothing is lost.
- **Desktop-sized UI.** The app does not restyle the client for phones.
