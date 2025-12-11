{
  lib,
  stdenv,
  testers,
  rustPlatform,
  fetchFromGitHub,
  cacert,
  opendeck,

  # OpenDeck specific dependencies
  deno,
  git,
  wrapGAppsHook3,
  systemd,
  libayatana-appindicator,

  # Tauri dependencies
  pkg-config,
  gobject-introspection,
  cargo,
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
  version = "2.7.1";

  src = fetchFromGitHub {
    owner = "nekename";
    repo = "opendeck";
    rev = "v${version}";
    hash = "sha256-NZ+gHtaqWngBzs3/sD8JYPYwPpgol6LJUCSCSHx7jCc=";
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

  # Enigo library source - needed for plugins
  enigoSrc = fetchFromGitHub {
    owner = "enigo-rs";
    repo = "enigo";
    rev = "4cb8833144e6e5e679b91ae7fd53507f9abf751d";
    hash = "sha256-zcxgs30L5dQiq/tJNUla6rwZvS2FGOc0O7tTDKifLPo=";
  };

  # Prepare enigo source with Cargo.lock for path dependency
  enigo = stdenv.mkDerivation {
    pname = "enigo-source";
    version = "0.6.1-unstable-2024-11-14";
    src = enigoSrc;

    dontBuild = true;

    installPhase = ''
      runHook preInstall
      mkdir -p $out
      cp -r * $out/
      cp ${./enigo-Cargo.lock} $out/Cargo.lock
      runHook postInstall
    '';
  }; # Frontend - FOD with network access
  frontend = stdenv.mkDerivation {
    pname = "opendeck-frontend";
    inherit version src;

    nativeBuildInputs = [ deno ];

    buildPhase = ''
      runHook preBuild

      export DENO_DIR="$TMPDIR/deno"
      deno install
      deno task build

      runHook postBuild
    '';

    installPhase = ''
      runHook preInstall
      cp -r build/ $out
      runHook postInstall
    '';

    # Make this a Fixed Output Derivation for network access
    outputHashMode = "recursive";
    outputHash = "sha256-Oxsvy2EXd67MbFcAcvxljOSW1BDJNu1+dbeH9w2OADc=";

    meta = meta // {
      description = "Web UI for OpenDeck. This is used for building the full OpenDeck application. Installing this as a standalone package is not recommended. Install opendeck instead.";
    };
  };

  # Deno dependencies for plugins - FOD for downloading only
  pluginDenoDeps = stdenv.mkDerivation {
    pname = "opendeck-plugin-deno-deps";
    inherit version src;

    nativeBuildInputs = [ deno ];

    buildPhase = ''
      runHook preBuild

      export DENO_DIR="$out"

      # Cache deno dependencies for each plugin's build.ts
      for plugin in plugins/*; do
        if [ -d "$plugin" ] && [ -f "$plugin/build.ts" ]; then
          echo "Caching Deno dependencies for $(basename "$plugin")"
          deno cache --allow-scripts "$plugin/build.ts"
        fi
      done

      runHook postBuild
    '';

    installPhase = ''
      runHook preInstall
      # DENO_DIR already points to $out
      runHook postInstall
    '';

    # Make this a Fixed Output Derivation for network access
    outputHashMode = "recursive";
    outputHash = "sha256-SBLWdkfNMyNyh5yFYrpaOtluaSL6PbIGEo/0PvgKwes=";

    meta = meta // {
      description = "Cached Deno dependencies for building OpenDeck plugins. This is used for building the full OpenDeck application. Installing this as a standalone package is not recommended. Install opendeck instead.";
    };
  };

  # Plugins - regular build with vendored Cargo dependencies
  plugins = stdenv.mkDerivation {
    pname = "opendeck-plugins";
    inherit version src;

    cargoDeps = rustPlatform.importCargoLock {
      lockFile = ./starterpack-Cargo.lock;
    };

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

    # Patch plugin to use local enigo instead of git dependency
    postPatch = ''
      # Copy the Cargo.lock to the root for cargo vendoring
      cp ${./starterpack-Cargo.lock} Cargo.lock

      # Replace git dependency with path dependency in plugin's Cargo.toml
      for plugin in plugins/*/Cargo.toml; do
        if [ -f "$plugin" ]; then
          sed -i 's|git = "https://github.com/enigo-rs/enigo.git", rev = "[^"]*",|path = "${enigo}",|g' "$plugin"
        fi
      done
    '';

    buildPhase = ''
      runHook preBuild

      export DENO_DIR="${pluginDenoDeps}"
      export HOME="$TMPDIR"
      export CARGO_HOME="$TMPDIR/cargo"

      mkdir -p target/plugins

      # Build each plugin
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

# Build the actual OpenDeck package
rustPlatform.buildRustPackage {
  pname = "opendeck";
  inherit version src;

  nativeBuildInputs = [
    deno
    wrapGAppsHook3
    pkg-config
    gobject-introspection
    cargo
  ];

  buildInputs = [
    systemd
    libayatana-appindicator
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
      "fix-path-env-0.0.0" = "sha256-UygkxJZoiJlsgp8PLf1zaSVsJZx1GGdQyTXqaFv3oGk=";
    };
  };

  postPatch = ''
    # Copy Cargo.lock to root for cargo vendoring
    cp ${./Cargo.lock} Cargo.lock

    # Disable the frontend building in tauri.conf.json since we pre-built it
    substituteInPlace src-tauri/tauri.conf.json \
      --replace-fail '"beforeBuildCommand": "deno task build",' '"beforeBuildCommand": "",' \
      --replace-fail '"beforeDevCommand": "deno task dev",' '"beforeDevCommand": "",'

    # Disable plugin building in build.rs since we pre-built them
    substituteInPlace src-tauri/build.rs \
      --replace-fail 'for entry in fs::read_dir("../plugins")?.flatten()' 'for entry in std::iter::empty::<std::fs::DirEntry>()'

    # Remove the devUrl to fix frontend-backend connection
    substituteInPlace src-tauri/tauri.conf.json \
      --replace-fail $',\n\t\t"devUrl": "http://localhost:5173"' ""

    # Patch libappindicator to use the correct library path
    substituteInPlace $cargoDepsCopy/libappindicator-sys-*/src/lib.rs \
      --replace-fail 'libayatana-appindicator3.so.1' '${libayatana-appindicator}/lib/libayatana-appindicator3.so.1'

    # Copy pre-built frontend
    cp -r ${frontend} build/

    # Copy pre-built plugins
    mkdir -p src-tauri/target/plugins
    cp -r ${plugins}/* src-tauri/target/plugins/
    chmod -R +w src-tauri/target/plugins

    # Fix udev rules for Stream Deck Mini (Discord Edition)
    echo 'SUBSYSTEM=="usb", ATTRS{idVendor}=="0fd9", ATTRS{idProduct}=="00b3", MODE="0660", TAG+="uaccess"' >> src-tauri/bundle/40-streamdeck.rules
    echo 'KERNEL=="hidraw*", SUBSYSTEM=="hidraw", ATTRS{idVendor}=="0fd9", ATTRS{idProduct}=="00b3", MODE="0660", TAG+="uaccess"' >> src-tauri/bundle/40-streamdeck.rules
  '';

  postInstall = ''
    # Install udev rules for Stream Deck devices
    install -Dm644 src-tauri/bundle/40-streamdeck.rules -t $out/lib/udev/rules.d/

    # Install built-in plugins
    mkdir -p $out/share
    cp -r src-tauri/target/plugins $out/share/
  '';

  preFixup = ''
    gappsWrapperArgs+=(
      --set APPDIR "$out"
    )
  '';

  passthru = {
    tests.version = testers.testVersion {
      package = opendeck;
    };
    inherit
      enigo
      frontend
      pluginDenoDeps
      plugins
      ;
  };

  inherit meta;
}
