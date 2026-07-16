{
  pkgs,
  defaultCpuQuota ? "25%",
  defaultRepository ? "/etc/nixos",
  revision ? "unknown",
}:

let
  version = "1.0.0";
  output = builtins.placeholder "out";
in
pkgs.python3Packages.buildPythonApplication {
  pname = "nixos-update-checker";
  inherit version;
  pyproject = true;

  src = pkgs.lib.cleanSourceWith {
    src = ../.;
    filter =
      path: _type:
      builtins.all (name: baseNameOf path != name) [
        ".direnv"
        ".git"
        ".mypy_cache"
        ".pytest_cache"
        ".ruff_cache"
        ".venv"
        "__pycache__"
        "result"
      ];
  };

  build-system = [ pkgs.python3Packages.setuptools ];
  dependencies = [ pkgs.python3Packages.pyside6 ];
  buildInputs = [ pkgs.qt6.qtbase ];

  nativeBuildInputs = [ pkgs.qt6.wrapQtAppsHook ];
  nativeCheckInputs = [ pkgs.python3Packages.pytest ];

  makeWrapperArgs = [
    "--set"
    "NIXOS_UPDATE_CHECKER_VERSION"
    version
    "--set"
    "NIXOS_UPDATE_CHECKER_REVISION"
    revision
    "--set"
    "NIXOS_UPDATE_CHECKER_BACKEND"
    "${output}/bin/check-nixos-updates"
    "--set"
    "NIXOS_UPDATE_CHECKER_NIX"
    "${pkgs.nix}/bin/nix"
    "--set"
    "NIXOS_UPDATE_CHECKER_MANIFEST"
    "${output}/share/nixos-update-checker/manifest.nix"
    "--set"
    "NIXOS_UPDATE_CHECKER_SYSTEMD_RUN"
    "${pkgs.systemd}/bin/systemd-run"
    "--set"
    "NIXOS_UPDATE_CHECKER_IONICE"
    "${pkgs.util-linux}/bin/ionice"
    "--set"
    "NIXOS_UPDATE_CHECKER_NICE"
    "${pkgs.coreutils}/bin/nice"
    "--set"
    "NIXOS_UPDATE_CHECKER_PKEXEC"
    "${pkgs.polkit}/bin/pkexec"
    "--set"
    "NIXOS_UPDATE_CHECKER_INSTALL"
    "${pkgs.coreutils}/bin/install"
    "--set"
    "NIXOS_UPDATE_CHECKER_REBUILD"
    "${pkgs.nixos-rebuild}/bin/nixos-rebuild"
    "--set"
    "NIXOS_UPDATE_CHECKER_GC"
    "${pkgs.nix}/bin/nix-collect-garbage"
    "--set"
    "NIXOS_UPDATE_CHECKER_ICON"
    "${output}/share/icons/hicolor/scalable/apps/nixos-update-checker.svg"
    "--set"
    "NIXOS_UPDATE_CHECKER_REPOSITORY"
    defaultRepository
    "--set"
    "NIXOS_UPDATE_CHECKER_REPORT"
    "/var/lib/nixos-update-checker/report.json"
    "--set"
    "NIXOS_UPDATE_CHECKER_DEFAULT_CPU_QUOTA"
    defaultCpuQuota
  ];

  postInstall = ''
    mkdir -p "$out/share/applications" "$out/share/icons/hicolor/scalable/apps"
    mkdir -p "$out/share/nixos-update-checker"

    install -m644 "$src/assets/nixos-update-checker.svg" \
      "$out/share/icons/hicolor/scalable/apps/nixos-update-checker.svg"
    install -m644 "$src/assets/nixos-update-checker.desktop" \
      "$out/share/applications/nixos-update-checker.desktop"
    install -m644 "$src/assets/nixos-update-checker-autostart.desktop" \
      "$out/share/nixos-update-checker/autostart.desktop"
    install -m644 "$src/nix/manifest.nix" \
      "$out/share/nixos-update-checker/manifest.nix"

  '';

  doInstallCheck = true;
  installCheckPhase = ''
    runHook preInstallCheck
    pytest -p no:cacheprovider "$src/tests"
    "$out/bin/nixos-update-checker" --version | grep -F "nixos-update-checker 1.0.0"
    QT_QPA_PLATFORM=offscreen "$out/bin/nixos-update-checker" \
      --self-test --no-tray --report /nonexistent /etc/nixos
    "$out/bin/check-nixos-updates" --version | grep -F "check-nixos-updates 1.0.0"
    ${pkgs.lib.optionalString (revision != "unknown") ''
      env -u PYTHONPATH "$out/bin/check-nixos-updates" --version | grep -F ${pkgs.lib.escapeShellArg revision}
    ''}
    "$out/bin/check-nixos-updates" --help >/dev/null
    runHook postInstallCheck
  '';

  meta = {
    description = "PySide6 NixOS flake update checker with tray integration";
    homepage = "https://github.com/Onred/nixos-update-checker";
    mainProgram = "nixos-update-checker";
    platforms = pkgs.lib.platforms.linux;
  };
}
