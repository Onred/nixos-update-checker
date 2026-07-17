{
  revision ? "unknown",
}:

{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.programs.nixos-update-checker;
  reportPath = "/var/lib/nixos-update-checker/report.json";
in
{
  options.programs.nixos-update-checker = {
    enable = lib.mkEnableOption "the NixOS flake update checker";

    repository = lib.mkOption {
      type = lib.types.strMatching "/.*";
      default = "/etc/nixos";
      example = "/home/alice/nixos-config";
      description = "Absolute path to the NixOS flake checked by the application.";
    };

    cpuQuota = lib.mkOption {
      type = lib.types.strMatching "[1-9][0-9]*%";
      default = "100%";
      description = ''
        Aggregate CPU quota for background builds. The default permits one CPU's
        total throughput while spreading work over several cores.
      '';
    };

    tray.enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Start the graphical application in desktop sessions.";
    };

    service = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Build and compare the candidate system periodically.";
      };

      onBootSec = lib.mkOption {
        type = lib.types.str;
        default = "20m";
        description = "Delay after boot before the first background build.";
      };

      interval = lib.mkOption {
        type = lib.types.str;
        default = "24h";
        description = "Interval between background builds.";
      };

      randomizedDelaySec = lib.mkOption {
        type = lib.types.str;
        default = "1h";
        description = "Maximum random delay added to timer activations.";
      };
    };

    package = lib.mkOption {
      type = lib.types.package;
      default = import ./package.nix {
        inherit pkgs revision;
        defaultRepository = cfg.repository;
      };
      description = "Packaged Qt application and checker backend.";
    };
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = [ cfg.package ];

    environment.etc = lib.mkIf cfg.tray.enable {
      "xdg/autostart/nixos-update-checker.desktop".source =
        "${cfg.package}/share/nixos-update-checker/autostart.desktop";
    };

    systemd.services = lib.mkIf cfg.service.enable {
      nixos-update-checker = {
        description = "Build a candidate NixOS system and report available updates";
        documentation = [ "https://github.com/Onred/nixos-update-checker" ];
        after = [ "network-online.target" ];
        wants = [ "network-online.target" ];

        environment = {
          HOME = "/var/lib/nixos-update-checker";
          NIX_REMOTE = "local";
        };

        script = ''
          exec ${cfg.package}/bin/check-nixos-updates \
            --background \
            --report ${reportPath} \
            ${lib.escapeShellArg cfg.repository}
        '';

        serviceConfig = {
          Type = "oneshot";
          User = "root";
          StateDirectory = "nixos-update-checker";
          StateDirectoryMode = "0755";
          UMask = "0022";

          # Short periods distribute the quota smoothly instead of creating
          # long one-core bursts. Nix's adaptive job/core counts are additional
          # concurrency controls, not the thermal limit itself.
          CPUQuota = cfg.cpuQuota;
          CPUQuotaPeriodSec = "10ms";
          CPUWeight = 1;
          IOWeight = 1;
          Nice = 19;
          IOSchedulingClass = "idle";
          IOSchedulingPriority = 7;
          OOMScoreAdjust = 500;
          TimeoutStartSec = "infinity";

          # A direct local store is intentional: daemon builders would escape
          # this service's cgroup and therefore its CPU quota.
          ReadWritePaths = [
            "/nix/store"
            "/nix/var/nix"
            "/nix/var/log/nix"
          ];

          PrivateTmp = true;
          ProtectSystem = "strict";
          ProtectHome = "read-only";
          NoNewPrivileges = true;
          LockPersonality = true;
          RestrictSUIDSGID = true;
        };
      };
    };

    systemd.timers = lib.mkIf cfg.service.enable {
      nixos-update-checker = {
        description = "Periodically build a candidate NixOS system";
        wantedBy = [ "timers.target" ];
        timerConfig = {
          OnBootSec = cfg.service.onBootSec;
          OnUnitActiveSec = cfg.service.interval;
          RandomizedDelaySec = cfg.service.randomizedDelaySec;
          Persistent = true;
          Unit = "nixos-update-checker.service";
        };
      };
    };
  };
}
