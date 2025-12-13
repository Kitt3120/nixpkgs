{
  lib,
  stdenv,
  testers,
  rustPlatform,
  fetchFromGitHub,
  opendeck,

  # OpenDeck specific dependencies
  deno,
  git,
  wrapGAppsHook3,
  systemd,
  libayatana-appindicator,
  glib-networking,

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
  # Version and source information
  version = "2.7.1";
  srcHash = "sha256-NZ+gHtaqWngBzs3/sD8JYPYwPpgol6LJUCSCSHx7jCc=";

  # Enigo dependency information
  enigoRev = "4cb8833144e6e5e679b91ae7fd53507f9abf751d";
  enigoHash = "sha256-zcxgs30L5dQiq/tJNUla6rwZvS2FGOc0O7tTDKifLPo=";

  # FOD output hashes
  frontendHash = "sha256-dPs5Nut4tDzQeWRSBMtsP8umil9W4ek7r0C2Fs6G+Ck=";
  pluginDenoDepsHash = "sha256-/u3sx6HtTDiTKzY9lJMSLXKjQ9yCFf0TzTjQj8rg61g=";

  # Additional output hashes of cargo dependencies that need to be specified
  cargoOutputHashes = {
    "fix-path-env-0.0.0" = "sha256-UygkxJZoiJlsgp8PLf1zaSVsJZx1GGdQyTXqaFv3oGk=";
  };

  # Main OpenDeck source. Used for building the frontend, plugins, and main opendeck derivation
  src = fetchFromGitHub {
    owner = "nekename";
    repo = "opendeck";
    rev = "v${version}";
    hash = srcHash;
  };

  # Enigo is a dependency needed for building the plugins
  # We have to fetch it here as it is a git dependency in the plugins' Cargo.toml
  # We will patch the plugins to use a path dependency instead
  enigoSrc = fetchFromGitHub {
    owner = "enigo-rs";
    repo = "enigo";
    rev = enigoRev;
    hash = enigoHash;
  };

  # Enigo does not provide a Cargo.lock file, so we inject our vendored one here
  enigoSrcWithCargoLock = stdenv.mkDerivation {
    pname = "enigo-source-with-cargo-lock";
    version = "0.6.1-unstable-2024-11-14";
    src = enigoSrc;

    dontBuild = true;

    # - Copies entire source to output
    # - Additionally copies our vendored Cargo.lock file to the output
    installPhase = ''
      runHook preInstall

      mkdir -p $out
      cp -r * $out/
      cp ${./enigo-Cargo.lock} $out/Cargo.lock

      runHook postInstall
    '';
  };

  # The frontend derivation
  # We're building this as a Fixed Output Derivation since it requires network access
  frontend = stdenv.mkDerivation {
    pname = "opendeck-frontend";
    inherit version src;

    # Makes this a Fixed Output Derivation for network access
    outputHashMode = "recursive";
    outputHash = frontendHash;

    nativeBuildInputs = [ deno ];

    # - Sets the DENO_DIR to a temporary location to avoid polluting the Nix store
    # - Builds the frontend using deno
    buildPhase = ''
      runHook preBuild

      export DENO_DIR="$TMPDIR/deno"
      deno install
      deno task build

      runHook postBuild
    '';

    # - Copies the built frontend from the build/ directory to the output
    installPhase = ''
      runHook preInstall

      cp -r build/ $out

      runHook postInstall
    '';
  };

  # We're building the plugins later.
  # However, the plugins' build.ts files have deno dependencies.
  # To avoid also having to build the plugins as FODs, we build only the deno dependencies here as a FOD.
  # These will then be used when building the plugins.
  pluginDenoDeps = stdenv.mkDerivation {
    pname = "opendeck-plugin-deno-deps";
    inherit version src;

    # Makes this a Fixed Output Derivation for network access
    outputHashMode = "recursive";
    outputHash = pluginDenoDepsHash;

    nativeBuildInputs = [ deno ];

    # - Sets the DENO_DIR to the output
    # - Caches the deno dependencies for each plugin's build.ts
    buildPhase = ''
      runHook preBuild

      export DENO_DIR="$out"
      for plugin in plugins/*; do
        if [ -d "$plugin" ] && [ -f "$plugin/build.ts" ]; then
          deno cache --allow-scripts "$plugin/build.ts"
        fi
      done

      runHook postBuild
    '';
  };

  # We can now build the plugins.
  # This builds against our vendored starterpack-Cargo.lock to ensure reproducible builds.
  # This uses the cached Deno dependencies from the previous derivation.
  # This also uses our patched enigo source with Cargo.lock.
  # To make this work, we patch each plugin's Cargo.toml to use a path dependency for enigo.
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

    # Copy our vendored starterpack-Cargo.lock to the source root for cargoSetupPostPatchHook validation
    # This must happen before patchPhase because cargoSetupPostPatchHook validates it
    postUnpack = ''
      cp ${./starterpack-Cargo.lock} $sourceRoot/Cargo.lock
    '';

    # Patch plugin to use local enigo instead of git dependency
    postPatch = ''
      # Replace git dependency with path dependency in plugin's Cargo.toml
      for plugin in plugins/*/Cargo.toml; do
        if [ -f "$plugin" ]; then
          sed -i 's|git = "https://github.com/enigo-rs/enigo.git", rev = "[^"]*",|path = "${enigoSrcWithCargoLock}",|g' "$plugin"
        fi
      done
    '';

    # - Sets DENO_DIR to the cached deno dependencies from previous derivation
    # - Builds each plugin using its build.ts script
    buildPhase = ''
      runHook preBuild

      export DENO_DIR="${pluginDenoDeps}"
      export HOME="$TMPDIR"
      export CARGO_HOME="$TMPDIR/cargo"

      mkdir -p target/plugins
      for plugin in plugins/*; do
        if [ -d "$plugin" ]; then
          plugin_name=$(basename "$plugin")
          plugin_out="$PWD/target/plugins/$plugin_name"
          
          cd "$plugin"
          deno run --allow-all build.ts "$plugin_out" "${stdenv.hostPlatform.rust.rustcTarget}"
          cd "$OLDPWD"
        fi
      done

      runHook postBuild
    '';

    # - Copies all built plugins from target/plugins/ to the output
    installPhase = ''
      runHook preInstall

      mkdir -p $out
      cp -r target/plugins/* $out/

      runHook postInstall
    '';
  };
in

# Build the actual OpenDeck package.
# This builds against our vendored Cargo.lock to ensure reproducible builds.
# This uses the pre-built frontend and plugins.
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
    outputHashes = cargoOutputHashes;
  };

  # Copy our vendored Cargo.lock to the source root for cargoSetupPostPatchHook validation
  # This must happen before patchPhase because cargoSetupPostPatchHook validates it
  postUnpack = ''
    cp ${./Cargo.lock} $sourceRoot/Cargo.lock
  '';

  # - Disable frontend and plugin building since we pre-built them
  # - Remove devUrl to fix frontend-backend connection
  # - Patch libappindicator to use correct library path
  postPatch = ''
    # Frontend
    substituteInPlace src-tauri/tauri.conf.json \
      --replace-fail '"beforeBuildCommand": "deno task build",' '"beforeBuildCommand": "",' \
      --replace-fail '"beforeDevCommand": "deno task dev",' '"beforeDevCommand": "",'  

    # Plugins
    substituteInPlace src-tauri/build.rs \
      --replace-fail 'for entry in fs::read_dir("../plugins")?.flatten()' 'for entry in std::iter::empty::<std::fs::DirEntry>()'

    # devUrl removal
    substituteInPlace src-tauri/tauri.conf.json \
      --replace-fail $',\n\t\t"devUrl": "http://localhost:5173"' ""

    # libappindicator path fix
    substituteInPlace $cargoDepsCopy/libappindicator-sys-*/src/lib.rs \
      --replace-fail 'libayatana-appindicator3.so.1' '${libayatana-appindicator}/lib/libayatana-appindicator3.so.1'
  '';

  # - Copy pre-built frontend into build/ directory for Tauri to bundle
  # - Copy pre-built plugins into src-tauri/target/plugins for Tauri to validate
  preConfigure = ''
    # Copy pre-built frontend
    cp -r ${frontend} build/

    # Copy pre-built plugins for build-time bundling
    # Tauri needs these during build to validate the resources configuration
    mkdir -p src-tauri/target/plugins
    cp -r ${plugins}/* src-tauri/target/plugins/
    chmod -R +w src-tauri/target/plugins
  '';

  # - Install plugins to the hardcoded path the app expects
  # - The app tries to access $out/usr/lib/opendeck/plugins for builtin plugins
  # - Set APPDIR environment variable for OpenDeck to find its resources
  # - Set GIO_EXTRA_MODULES for glib-networking (required for HTTPS in WebKitGTK)
  preFixup = ''
    mkdir -p $out/usr/lib/opendeck/plugins
    cp -r ${plugins}/* $out/usr/lib/opendeck/plugins/

    gappsWrapperArgs+=(
      --set APPDIR "$out"
      --prefix GIO_EXTRA_MODULES : "${glib-networking}/lib/gio/modules"
    )
  '';

  # - Install udev rules that come with OpenDeck
  # - Install icon and create desktop file for desktop integration
  postInstall = ''
        install -Dm644 src-tauri/bundle/40-streamdeck.rules -t $out/lib/udev/rules.d/
        
        # Install icon
        install -Dm644 src-tauri/icons/icon.png $out/share/pixmaps/opendeck.png
        
        # Create desktop file
        mkdir -p $out/share/applications
        cat > $out/share/applications/opendeck.desktop << EOF
    [Desktop Entry]
    Name=OpenDeck
    Comment=Control your Stream Deck on Linux
    Exec=opendeck
    Icon=opendeck
    Type=Application
    Categories=Utility;
    EOF
  '';

  passthru = {
    tests.version = testers.testVersion {
      package = opendeck;
    };
    inherit
      enigoSrcWithCargoLock
      frontend
      pluginDenoDeps
      plugins
      ;
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
}
