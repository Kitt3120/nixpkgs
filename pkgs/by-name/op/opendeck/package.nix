{
  lib,
  stdenv,
  testers,
  rustPlatform,
  fetchFromGitHub,
  cacert,
  opendeck,

  # OpenDeck specific dependencies
  systemd,
  libayatana-appindicator,

  # Tauri dependencies
  pkg-config,
  gobject-introspection,
  cargo,
  cargo-tauri,
  deno,
  wrapGAppsHook3,
  at-spi2-atk,
  atkmm,
  cairo,
  gdk-pixbuf,
  glib,
  gtk3,
  harfbuzz,
  librsvg,
  libsoup_3,
  pango,
  webkitgtk_4_1,
  openssl,

  # Plugin dependencies
  libxkbcommon,
  wayland,
  xorg,
  autoPatchelfHook,
}:

let
  version = "2.7.0";

  src = fetchFromGitHub {
    owner = "nekename";
    repo = "opendeck";
    rev = "v${version}";
    hash = "sha256-j6xoSx0citqQzglkOHzW788RzOpdSPCh5QRVR9JaZO0=";
  };

  meta = {
    description = "Linux software for the Elgato Stream Deck with support for original Stream Deck plugins";
    license = lib.licenses.mit;
    platforms = lib.platforms.linux;
    homepage = "https://github.com/nekename/opendeck";
    downloadPage = "https://github.com/nekename/opendeck/releases/tag/v${version}";
    changelog = "https://github.com/nekename/opendeck/releases/tag/v${version}";
    maintainers = with lib.maintainers; [ Kitt3120 ];
  };

  # We have to build the frontend separately, and hand it to the backend rust build
  frontend = stdenv.mkDerivation {
    pname = "opendeck-frontend";
    inherit version src;

    nativeBuildInputs = [ deno ];

    # Make this a Fixed Output Derivation since we need to allow network access for Deno to download dependencies
    outputHashMode = "recursive";
    outputHash = "sha256-dgoU99PDIceaBpwt96/JUICHHKUZ73O0ubtx8i+l4w0=";

    # Deno will handle downloading dependencies. That's why we enable network access here.
    buildPhase = ''
      runHook preBuild

      export DENO_DIR="$TMPDIR/deno"
      deno install --allow-scripts
      deno task build

      runHook postBuild
    '';

    # Copy the built frontend to the pkg output, so we can use it in the backend build
    installPhase = ''
      runHook preInstall
      cp -r build/ $out
      runHook postInstall
    '';

    meta = meta // {
      description = "Web UI for OpenDeck. This is used for building the full OpenDeck application. Installing this as a standalone package is not recommended. Install opendeck instead.";
    };
  };

  # We have to build the built-in plugins separately, and hand them to the backend rust build
  # This is a two-stage process:
  # - First we prepare deno dependencies in a FOD
  # - Then we build the actual plugins with those dependencies cached
  # This is the first stage: preparing deno dependencies
  pluginDenoDeps = stdenv.mkDerivation {
    pname = "opendeck-plugin-deno-deps";
    inherit version src;

    nativeBuildInputs = [ deno ];

    outputHashMode = "recursive";
    outputHash = "sha256-8ZkHsNSnQ+n0dWUV1pakUsR1Ke8MyzzWlc0VBetDwo8=";

    buildPhase = ''
      runHook preBuild

      export DENO_DIR="$out"

      # Cache deno dependencies for each plugin's build.ts
      # We run deno cache on the build scripts to download their dependencies
      for plugin in plugins/*; do
        if [ -d "$plugin" ] && [ -f "$plugin/build.ts" ]; then
          echo "Caching Deno dependencies for $(basename "$plugin")"
          deno cache --allow-scripts "$plugin/build.ts"
        fi
      done

      runHook postBuild
    '';

    # DENO_DIR is already set to $out, so we don't have to copy anything
    installPhase = ''
      runHook preInstall
      runHook postInstall
    '';

    meta = meta // {
      description = "Cached Deno dependencies for building OpenDeck plugins. This is used for building the full OpenDeck application. Installing this as a standalone package is not recommended. Install opendeck instead.";
    };
  };

  # This is the second stage: building the actual plugins with cached deno dependencies
  plugins = stdenv.mkDerivation {
    pname = "opendeck-plugins";
    inherit version src;

    nativeBuildInputs = [
      deno
      cargo
      rustPlatform.cargoSetupHook
      autoPatchelfHook
    ];

    buildInputs = [
      libxkbcommon
      wayland
      xorg.libX11
      xorg.libXrandr
      xorg.libXi
      stdenv.cc.cc.lib
    ];

    # Copy the Cargo.lock from the plugin
    postUnpack = ''
      cp "$sourceRoot/plugins/com.amansprojects.starterpack.sdPlugin/Cargo.lock" "$sourceRoot/"
    '';

    cargoDeps = rustPlatform.importCargoLock {
      lockFile = ./starterpack-Cargo.lock;
    };

    buildPhase = ''
      runHook preBuild

      export DENO_DIR="${pluginDenoDeps}"
      export HOME="$TMPDIR"
      export CARGO_HOME="$TMPDIR/cargo"

      mkdir -p target/plugins

      # Build each plugin (currently just starterpack)
      for plugin in plugins/*; do
        if [ -d "$plugin" ]; then
          plugin_name=$(basename "$plugin")
          plugin_out="$PWD/target/plugins/$plugin_name"
          
          echo "Building plugin: $plugin_name"
          cd "$plugin"
          deno run --allow-all build.ts "$plugin_out" "${stdenv.hostPlatform.rust.rustcTarget}"
          cd "$OLDPWD"
        fi
      done

      runHook postBuild
    '';

    # Copy built plugins to $out to be used in the backend build
    installPhase = ''
      runHook preInstall

      mkdir -p $out
      cp -r target/plugins/* $out/

      runHook postInstall
    '';

    meta = meta // {
      description = "Built-in plugins for OpenDeck. This is used for building the full OpenDeck application. Installing this as a standalone package is not recommended. Install opendeck instead.";
    };
  };
in

# Build the actual OpenDeck package, using the pre-built frontend and plugins
rustPlatform.buildRustPackage {
  pname = "opendeck";
  inherit version src;

  nativeBuildInputs = [
    # OpenDeck specific
    deno
    wrapGAppsHook3

    # Tauri dependencies: https://wiki.nixos.org/wiki/Tauri
    pkg-config
    gobject-introspection
    cargo
    cargo-tauri
  ];

  buildInputs = [
    # OpenDeck specific
    systemd
    libayatana-appindicator

    # Tauri dependencies: https://wiki.nixos.org/wiki/Tauri
    at-spi2-atk
    atkmm
    cairo
    gdk-pixbuf
    glib
    gtk3
    harfbuzz
    librsvg
    libsoup_3
    pango
    webkitgtk_4_1
    openssl
  ];

  # The Rust code is in the src-tauri subdirectory
  buildAndTestSubdir = "src-tauri";

  cargoLock = {
    lockFile = ./Cargo.lock;
    outputHashes = {
      # We have to specify fix-path-env explicitly since it is a GitHub dependency
      "fix-path-env-0.0.0" = "sha256-UygkxJZoiJlsgp8PLf1zaSVsJZx1GGdQyTXqaFv3oGk=";
    };
  };

  # We have to copy Cargo.lock to the root for buildRustPackage so it can find it
  postUnpack = ''
    cp "$sourceRoot/src-tauri/Cargo.lock" "$sourceRoot/"
  '';

  # - Copies the pre-built frontend into the expected location
  # - Copies the pre-built plugins into the expected location
  # - Patches tauri.conf.json
  # - Patches the build.rs to not build plugins since we pre-built them
  # - Copies the pre-built plugins into the expected location
  # - Patch libappindicator to use the correct library path
  postPatch = ''
    # Copy pre-built frontend
    cp -r ${frontend} build/

    # Copy pre-built plugins
    mkdir -p src-tauri/target/plugins
    cp -r ${plugins}/* src-tauri/target/plugins/
    chmod -R +w src-tauri/target/plugins

    # Remove beforeBuildCommand/beforeDevCommand because we already built the frontend
    substituteInPlace src-tauri/tauri.conf.json \
      --replace-fail '"beforeBuildCommand": "deno task build",' '"beforeBuildCommand": "",' \
      --replace-fail '"beforeDevCommand": "deno task dev",' '"beforeDevCommand": "",' \

    # Replace the devUrl with an empty string.
    # Don't ask me why but this fixes the frontend not connecting to the backend.
    substituteInPlace src-tauri/tauri.conf.json \
      --replace-fail $',\n\t\t"devUrl": "http://localhost:5173"' ""

    # Disable plugin building in build.rs since we pre-built them
    substituteInPlace src-tauri/build.rs \
      --replace-fail 'for entry in fs::read_dir("../plugins")?.flatten()' 'for entry in std::iter::empty::<std::fs::DirEntry>()'

    # Patch libappindicator to use the correct library path
    substituteInPlace $cargoDepsCopy/libappindicator-sys-*/src/lib.rs \
      --replace-fail 'libayatana-appindicator3.so.1' '${libayatana-appindicator}/lib/libayatana-appindicator3.so.1'
  '';

  # - Install udev rules for Stream Deck devices
  # - Install built-in plugins
  postInstall = ''
    # Install udev rules for Stream Deck devices
    install -Dm644 src-tauri/bundle/40-streamdeck.rules -t $out/lib/udev/rules.d/

    # Install built-in plugins
    mkdir -p $out/share
    cp -r src-tauri/target/plugins $out/share/
  '';

  # Set APPDIR so Tauri can find resources
  preFixup = ''
    gappsWrapperArgs+=(
      --set APPDIR "$out"
    )
  '';

  passthru = {
    tests.version = testers.testVersion {
      package = opendeck;
    };
    inherit frontend pluginDenoDeps plugins;
  };

  inherit meta;
}
