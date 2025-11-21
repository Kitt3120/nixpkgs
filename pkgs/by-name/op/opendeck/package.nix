{
  lib,
  stdenv,
  testers,
  rustPlatform,
  fetchFromGitHub,
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

  # We have to build the frontend separately and hand it to the backend rust build
  frontend = stdenv.mkDerivation {
    pname = "opendeck-frontend";
    inherit version src;

    nativeBuildInputs = [ deno ];

    # Make this a Fixed Output Derivation since we need to allow network access for Deno to download dependencies
    outputHashMode = "recursive";
    outputHash = "sha256-p0jO7TiEWz8ntQljZsTyfX1/a7xZDogBptYxvqWbhtU=";

    # We have to copy deno.lock to the build directory for deno to work correctly
    postPatch = ''
      cp ./deno.lock deno.lock
    '';

    # Deno will handle downloading and caching dependencies
    buildPhase = ''
      runHook preBuild

      export DENO_DIR="$TMPDIR/deno"
      deno install --allow-scripts
      deno task build

      runHook postBuild
    '';

    # Copy the built frontend to the pkg output
    installPhase = ''
      runHook preInstall
      cp -r build/ $out
      runHook postInstall
    '';

    meta = meta // {
      # I don't know if this description will be shown on the website, so I added a disclaimer not to install this as a standalone package
      description = "Web UI for OpenDeck. This is used for building the full OpenDeck application. Installing this as a standalone package is not recommended.";
    };
  };
in

# Build the actual OpenDeck package, using the pre-built frontend
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
    # Copy Cargo.lock to root for buildRustPackage
    cp "$sourceRoot/src-tauri/Cargo.lock" "$sourceRoot/"
  '';

  # - Copies the built frontend into the expected location and fixes tauri.conf.json
  # - Disables plugin building since it requires network access
  # - Patch libappindicator to use the correct library path
  postPatch = ''
    # Copy pre-built frontend /devUrl
    cp -r ${frontend} build/

    # Remove beforeBuildCommand/beforeDevCommand because we already built the frontend
    substituteInPlace src-tauri/tauri.conf.json \
      --replace-fail '"beforeBuildCommand": "deno task build",' '"beforeBuildCommand": "",' \
      --replace-fail '"beforeDevCommand": "deno task dev",' '"beforeDevCommand": "",' \

    # Replace the devUrl with an empty string.
    # Don't ask me why but this fixes the frontend not connecting to the backend.
    substituteInPlace src-tauri/tauri.conf.json \
      --replace-fail $',\n\t\t"devUrl": "http://localhost:5173"' ""

    # Disable plugin building in build.rs since it requires network access
    # Replace the plugin building code with a no-op
    substituteInPlace src-tauri/build.rs \
      --replace-fail 'for entry in fs::read_dir("../plugins")?.flatten()' 'for entry in std::iter::empty::<std::fs::DirEntry>()'

    # Patch libappindicator to use the correct library path
    substituteInPlace $cargoDepsCopy/libappindicator-sys-*/src/lib.rs \
      --replace-fail 'libayatana-appindicator3.so.1' '${libayatana-appindicator}/lib/libayatana-appindicator3.so.1'
  '';

  # We create an empty plugins directory to satisfy the build process
  preBuild = ''
    # Create empty plugins directory
    mkdir -p src-tauri/target/plugins
  '';

  # We add support for the Stream Deck Mini (Discord Edition)
  # We install the provided udev rules for Stream Deck devices
  # TODO: Upstream Stream Deck Mini (Discord Edition) support
  postInstall = ''
    # Install udev rules for Stream Deck devices
    install -Dm644 src-tauri/bundle/40-streamdeck.rules -t $out/lib/udev/rules.d/

    # Add Stream Deck Mini (Discord Edition) support
    # Add vendor=0fd9 product=00b3
    echo 'SUBSYSTEM=="usb", ATTRS{idVendor}=="0fd9", ATTRS{idProduct}=="00b3", MODE="0666", TAG+="uaccess"' >> $out/lib/udev/rules.d/40-streamdeck.rules
    echo 'KERNEL=="hidraw*", SUBSYSTEM=="hidraw", ATTRS{idVendor}=="0fd9", ATTRS{idProduct}=="003", MODE="0666", TAG+="uaccess"' >> $out/lib/udev/rules.d/40-streamdeck.rules
  '';

  passthru = {
    tests.version = testers.testVersion {
      package = opendeck;
    };
    inherit frontend;
  };

  inherit meta;
}
