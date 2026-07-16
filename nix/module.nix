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
      description = "Absolute path to the NixOS flake checked by the GUI and background service.";
    };

    cpuQuota = lib.mkOption {
      type = lib.types.strMatching "[1-9][0-9]*%";
      default = "25%";
      description = "CPU quota used by limited terminal checks and the background service.";
    };

    tray.enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Start the Qt tray application for graphical desktop sessions.";
    };

    service = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = true;
        description = "Run periodic update checks as a low-priority system service.";
      };

      user = lib.mkOption {
        type = lib.types.str;
        default = "root";
        description = "User account used by the background checker service.";
      };

      onBootSec = lib.mkOption {
        type = lib.types.str;
        default = "10m";
        description = "Delay after boot before the first background check.";
      };

      interval = lib.mkOption {
        type = lib.types.str;
        default = "6h";
        description = "Interval between background update checks.";
      };

      randomizedDelaySec = lib.mkOption {
        type = lib.types.str;
        default = "30m";
        description = "Maximum random delay added to timer activations.";
      };
    };

    package = lib.mkOption {
      type = lib.types.package;
      default = import ./package.nix {
        inherit pkgs;
        defaultCpuQuota = cfg.cpuQuota;
        defaultRepository = cfg.repository;
      };
      description = "Packaged Qt application and native checker backend.";
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
        description = "Check the NixOS flake for available updates";
        documentation = [ "https://github.com/Onred/nixos-update-checker" ];
        after = [
          "network-online.target"
          "nix-daemon.socket"
        ];
        wants = [ "network-online.target" ];

        environment = {
          HOME = "/var/lib/nixos-update-checker";
        };

        script = ''
          exec ${cfg.package}/bin/check-nixos-updates \
            --service \
            --report ${reportPath} \
            ${lib.escapeShellArg cfg.repository}
        '';

        serviceConfig = {
          Type = "oneshot";
          User = cfg.service.user;
          StateDirectory = "nixos-update-checker";
          StateDirectoryMode = "0755";
          UMask = "0022";
          CPUQuota = cfg.cpuQuota;
          CPUWeight = 1;
          IOWeight = 1;
          Nice = 19;
          IOSchedulingClass = "idle";
          IOSchedulingPriority = 7;
          OOMScoreAdjust = 500;
          TimeoutStartSec = "infinity";
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
        description = "Periodically check the NixOS flake for updates";
        wantedBy = [ "timers.target" ];
        timerConfig = {
          OnBootSec = cfg.service.onBootSec;
          OnUnitActiveSec = cfg.service.interval;
          RandomizedDelaySec = cfg.service.randomizedDelaySec;
          Unit = "nixos-update-checker.service";
        };
      };
    };
  };
}
