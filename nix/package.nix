{
  pkgs,
  defaultHost ? "nixos",
  defaultCpuQuota ? "25%",
}:

pkgs.writeShellApplication {
  name = "check-nixos-updates";
  runtimeInputs = with pkgs; [
    coreutils
    diffutils
    git
    gnused
    jq
    nix
    systemd
    util-linux
  ];
  text = ''
    export NIXOS_UPDATE_CHECKER_HOST=${pkgs.lib.escapeShellArg defaultHost}
    export NIXOS_UPDATE_CHECKER_DEFAULT_CPU_QUOTA=${pkgs.lib.escapeShellArg defaultCpuQuota}
    ${builtins.readFile ../src/backend.sh}
  '';
}
