# Toolchain for the Android APK (the automa-android branch's android/build-apk.sh):
# Node from the game's .nvmrc, JDK 17, the Android SDK packages build-apk.sh asks
# for, and zip. android-build.sh runs it with the build clone mounted at /work;
# the image holds no game code and no key.
#
# android-build.sh rebuilds this image only when this file changes (it labels the
# image with the file's hash), so the ~3 GB SDK download happens once, not on
# every base-image refresh.
FROM node:24-bookworm

RUN apt-get update \
    && apt-get install -y --no-install-recommends openjdk-17-jdk-headless zip unzip \
    && rm -rf /var/lib/apt/lists/*

ENV ANDROID_HOME=/opt/android-sdk
ARG CMDLINE_TOOLS=13114758
ARG CMDLINE_TOOLS_SHA256=7ec965280a073311c339e571cd5de778b9975026cfcbe79f2b1cdcb1e15317ee
RUN curl -fsSL -o /tmp/cmdline-tools.zip "https://dl.google.com/android/repository/commandlinetools-linux-${CMDLINE_TOOLS}_latest.zip" \
    && echo "$CMDLINE_TOOLS_SHA256  /tmp/cmdline-tools.zip" | sha256sum -c - \
    && mkdir -p "$ANDROID_HOME/cmdline-tools" \
    && unzip -q /tmp/cmdline-tools.zip -d "$ANDROID_HOME/cmdline-tools" \
    && mv "$ANDROID_HOME/cmdline-tools/cmdline-tools" "$ANDROID_HOME/cmdline-tools/latest" \
    && rm /tmp/cmdline-tools.zip

# The same packages build-apk.sh installs when they are missing; keep in step with it.
RUN yes | "$ANDROID_HOME/cmdline-tools/latest/bin/sdkmanager" --licenses > /dev/null \
    && "$ANDROID_HOME/cmdline-tools/latest/bin/sdkmanager" --install \
        "platforms;android-35" "build-tools;35.0.0" "ndk;27.2.12479018" "cmake;3.22.1" > /dev/null \
    && chmod -R a+rX "$ANDROID_HOME"

ENV PATH="$ANDROID_HOME/build-tools/35.0.0:$PATH"
# The container runs as the host user, who has no home in here: everything that
# would land in ~ goes to the /cache bind mount instead.
ENV HOME=/cache/home \
    GRADLE_USER_HOME=/cache/gradle \
    ANDROID_USER_HOME=/cache/android \
    npm_config_cache=/cache/npm \
    NODEJS_MOBILE_CACHE=/cache/nodejs-mobile \
    JAVA_TOOL_OPTIONS=-Duser.home=/cache/home
WORKDIR /work
