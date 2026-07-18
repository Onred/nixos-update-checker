{ pkgs }:

pkgs.stdenv.mkDerivation {
  pname = "nixos-update-checker";
  version = "4.1.0";

  src = pkgs.lib.cleanSourceWith {
    src = ../.;
    filter =
      path: _type:
      !builtins.elem (baseNameOf path) [
        ".direnv"
        ".git"
        "result"
      ];
  };

  nativeBuildInputs = [
    pkgs.makeWrapper
    pkgs.pkg-config
    pkgs.qt6.wrapQtAppsHook
  ];
  buildInputs = [ pkgs.qt6.qtbase ];
  dontWrapQtApps = true;

  buildPhase = ''
    runHook preBuild
    $CXX -std=c++20 -O2 -Wall -Wextra -Wpedantic \
      $(pkg-config --cflags Qt6Widgets) \
      src/main.cpp -o nixos-update-checker \
      $(pkg-config --libs Qt6Widgets)
    runHook postBuild
  '';

  installPhase = ''
    runHook preInstall
    install -Dm755 nixos-update-checker "$out/bin/nixos-update-checker"
    install -Dm755 src/checker.sh "$out/bin/nixos-update-checker-service"
    install -Dm755 src/apply.sh "$out/bin/nixos-update-checker-apply"
    install -Dm644 nix/discovery.nix \
      "$out/share/nixos-update-checker/discovery.nix"
    install -Dm644 assets/nixos-update-checker.desktop \
      "$out/share/applications/nixos-update-checker.desktop"
    install -Dm644 assets/nixos-update-checker-autostart.desktop \
      "$out/share/nixos-update-checker/autostart.desktop"

    wrapProgram "$out/bin/nixos-update-checker-service" \
      --set NIXOS_UPDATE_CHECKER_DISCOVERY \
        "$out/share/nixos-update-checker/discovery.nix" \
      --prefix PATH : ${
        pkgs.lib.makeBinPath [
          pkgs.coreutils
          pkgs.jq
          pkgs.nix
          pkgs.util-linux
        ]
      }

    wrapProgram "$out/bin/nixos-update-checker-apply" \
      --prefix PATH : ${
        pkgs.lib.makeBinPath [
          pkgs.coreutils
          pkgs.jq
          pkgs.nix
          pkgs.nixos-rebuild
          pkgs.util-linux
        ]
      }

    runHook postInstall
  '';

  postFixup = ''
    qtWrapperArgs+=(
      --set NIXOS_UPDATE_CHECKER_SYSTEMCTL "${pkgs.systemd}/bin/systemctl"
      --set NIXOS_UPDATE_CHECKER_JOURNALCTL "${pkgs.systemd}/bin/journalctl"
      --set NIXOS_UPDATE_CHECKER_REPORT "/var/lib/nixos-update-checker/report.json"
      --set NIXOS_UPDATE_CHECKER_STATUS "/var/lib/nixos-update-checker/status.json"
      --set NIXOS_UPDATE_CHECKER_SERVICE "nixos-update-checker.service"
      --set NIXOS_UPDATE_CHECKER_BACKGROUND_SERVICE \
        "nixos-update-checker-background.service"
      --set NIXOS_UPDATE_CHECKER_BUILD_SERVICE \
        "nixos-update-checker-build.service"
      --set NIXOS_UPDATE_CHECKER_APPLY_SERVICE "nixos-update-checker-apply.service"
      --set NIXOS_UPDATE_CHECKER_BOOT_SERVICE "nixos-update-checker-boot.service"
    )
    wrapQtApp "$out/bin/nixos-update-checker"
  '';

  doInstallCheck = true;
  nativeInstallCheckInputs = [
    pkgs.jq
    pkgs.shellcheck
  ];
  installCheckPhase = ''
    runHook preInstallCheck
    patchShebangs src/checker.sh scripts/live-regression-test.sh \
      tests/checker-fixtures.sh tests/fixtures/bin/nix
    shellcheck src/checker.sh src/apply.sh \
      scripts/live-regression-test.sh tests/checker-fixtures.sh tests/fixtures/bin/nix
    tests/checker-fixtures.sh ./src/checker.sh
    QT_QPA_PLATFORM=offscreen "$out/bin/nixos-update-checker" --version
    "$out/bin/nixos-update-checker-service" --help
    "$out/bin/nixos-update-checker-apply" --help
    runHook postInstallCheck
  '';

  meta = {
    description = "No-build NixOS update previews with opt-in verification and a Qt viewer";
    homepage = "https://github.com/Onred/nixos-update-checker";
    mainProgram = "nixos-update-checker";
    platforms = pkgs.lib.platforms.linux;
  };
}
