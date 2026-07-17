{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.programs.nixos-update-checker;
  package = import ./package.nix { inherit pkgs; };
  report = "/var/lib/nixos-update-checker/report.json";
  lock = "/var/lib/nixos-update-checker/operation.lock";
in
{
  options.programs.nixos-update-checker = {
    enable = lib.mkEnableOption "quiet daily NixOS update checks";

    repository = lib.mkOption {
      type = lib.types.strMatching "/.*";
      default = "/etc/nixos";
      example = "/home/alice/nixos";
      description = "Absolute path to the flake-based NixOS configuration.";
    };

    cpuQuota = lib.mkOption {
      type = lib.types.strMatching "[1-9][0-9]*%";
      default = "25%";
      example = "50%";
      description = ''
        Aggregate CPU quota for the checker. Values below 100% throttle
        single-threaded evaluation as well as parallel build work.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = [ package ];
    environment.etc."xdg/autostart/nixos-update-checker.desktop".source =
      "${package}/share/nixos-update-checker/autostart.desktop";

    systemd.services.nixos-update-checker = {
      description = "Build an updated NixOS candidate and publish a report";
      documentation = [ "https://github.com/Onred/nixos-update-checker" ];
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];

      environment = {
        HOME = "/var/lib/nixos-update-checker";
        NIX_REMOTE = "local";
        NIXOS_UPDATE_CHECKER_LOCK = lock;
        NIXOS_UPDATE_CHECKER_STATE = "/var/lib/nixos-update-checker/system-lock.json";
      };

      serviceConfig = {
        Type = "oneshot";
        ExecStart = lib.escapeShellArgs [
          "${package}/bin/nixos-update-checker-service"
          "--report"
          report
          cfg.repository
        ];
        User = "root";
        StateDirectory = "nixos-update-checker";
        StateDirectoryMode = "0755";
        UMask = "0022";

        CPUQuota = cfg.cpuQuota;
        CPUQuotaPeriodSec = "10ms";
        CPUWeight = 1;
        IOWeight = 1;
        Nice = 19;
        IOSchedulingClass = "idle";
        IOSchedulingPriority = 7;
        OOMScoreAdjust = 500;
        TimeoutStartSec = "infinity";

        # Local builders stay in this service's cgroup. nix-daemon builders do not.
        ReadWritePaths = [
          "/nix/store"
          "/nix/var/nix"
          "/nix/var/log/nix"
        ];
        PrivateTmp = true;
        ProtectSystem = "strict";
        ProtectHome = "read-only";
        NoNewPrivileges = true;
      };
    };

    systemd.services.nixos-update-checker-apply = {
      description = "Apply the latest reported NixOS update";
      documentation = [ "https://github.com/Onred/nixos-update-checker" ];
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];

      environment.NIXOS_UPDATE_CHECKER_LOCK = lock;

      serviceConfig = {
        Type = "oneshot";
        ExecStart = lib.escapeShellArgs [
          "${package}/bin/nixos-update-checker-apply"
          report
          cfg.repository
        ];
        User = "root";
        StateDirectory = "nixos-update-checker";
        StateDirectoryMode = "0755";
        TimeoutStartSec = "infinity";
      };
    };

    systemd.paths.nixos-update-checker = {
      description = "Refresh the NixOS update report when the system profile changes";
      wantedBy = [ "multi-user.target" ];
      pathConfig = {
        PathChanged = "/nix/var/nix/profiles/system";
        Unit = "nixos-update-checker.service";
      };
    };

    systemd.timers.nixos-update-checker = {
      description = "Run the daily NixOS update check";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = "daily";
        RandomizedDelaySec = "1h";
        Persistent = true;
      };
    };
  };
}
