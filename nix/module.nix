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
  candidateLock = "/var/lib/nixos-update-checker/candidate.lock";
  lock = "/var/lib/nixos-update-checker/operation.lock";
  previewService =
    { description, constrained }:
    {
      inherit description;
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
          "--candidate-lock"
          candidateLock
          cfg.repository
        ];
        User = "root";
        StateDirectory = "nixos-update-checker";
        StateDirectoryMode = "0755";
        UMask = "0022";
        Restart = "on-failure";
        RestartSec = "10m";
        KillMode = "control-group";
        TimeoutStopSec = "30s";
        SendSIGKILL = true;
        TimeoutStartSec = "24h";
        ReadWritePaths = [
          "/nix/store"
          "/nix/var/nix"
          "/nix/var/log/nix"
        ];
        PrivateTmp = true;
        ProtectSystem = "strict";
        ProtectHome = "read-only";
        NoNewPrivileges = true;
      }
      // lib.optionalAttrs constrained {
        CPUWeight = 1;
        IOWeight = 1;
        Nice = 19;
        IOSchedulingClass = "idle";
        IOSchedulingPriority = 7;
        OOMScoreAdjust = 500;
      }
      // lib.optionalAttrs (constrained && cfg.cpuQuota != null) {
        CPUQuota = cfg.cpuQuota;
        CPUQuotaPeriodSec = "10ms";
      };
    };
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
      type = lib.types.nullOr (lib.types.strMatching "[1-9][0-9]*%");
      default = "50%";
      example = null;
      description = ''
        Aggregate CPU quota for automatic checks. Values below 100% throttle
        single-threaded preview evaluation. Set this to null to disable CPU
        quota enforcement. Manual refreshes and builds are never throttled.
      '';
    };

    extraPackages = lib.mkOption {
      type = lib.types.attrsOf lib.types.package;
      default = { };
      example = lib.literalExpression "{ inherit (pkgs) my-custom-package; }";
      description = ''
        Additional packages to include in the lightweight update preview when
        they cannot be discovered from the active NixOS configuration.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = [ package ];
    environment.etc."xdg/autostart/nixos-update-checker.desktop".source =
      "${package}/share/nixos-update-checker/autostart.desktop";

    # Previewing and explicitly building the fixed, root-owned configuration do
    # not alter the active system. Applying an update is deliberately excluded.
    security.polkit = {
      enable = true;
      extraConfig = ''
        polkit.addRule(function(action, subject) {
          if (action.id == "org.freedesktop.systemd1.manage-units" &&
              (action.lookup("unit") == "nixos-update-checker.service" ||
               action.lookup("unit") == "nixos-update-checker-build.service") &&
              action.lookup("verb") == "start" &&
              subject.active && subject.local) {
            return polkit.Result.YES;
          }
        });
      '';
    };

    systemd.services.nixos-update-checker = previewService {
      description = "Manually preview available NixOS updates";
      constrained = false;
    };

    systemd.services.nixos-update-checker-background = previewService {
      description = "Automatically preview available NixOS updates";
      constrained = true;
    };

    systemd.services.nixos-update-checker-build = {
      description = "Build and verify the reviewed NixOS update candidate";
      documentation = [ "https://github.com/Onred/nixos-update-checker" ];
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];

      environment = {
        HOME = "/var/lib/nixos-update-checker";
        NIXOS_UPDATE_CHECKER_LOCK = lock;
        NIXOS_UPDATE_CHECKER_STATE = "/var/lib/nixos-update-checker/system-lock.json";
      };

      serviceConfig = {
        Type = "oneshot";
        ExecStart = lib.escapeShellArgs [
          "${package}/bin/nixos-update-checker-service"
          "--build"
          "--report"
          report
          "--candidate-lock"
          candidateLock
          cfg.repository
        ];
        User = "root";
        StateDirectory = "nixos-update-checker";
        StateDirectoryMode = "0755";
        UMask = "0022";
        KillMode = "control-group";
        TimeoutStopSec = "30s";
        SendSIGKILL = true;
        TimeoutStartSec = "infinity";
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
          candidateLock
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
        Unit = "nixos-update-checker-background.service";
      };
    };

    systemd.timers.nixos-update-checker = {
      description = "Run NixOS update checks after boot and daily";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnBootSec = "10m";
        OnCalendar = "daily";
        Persistent = true;
        Unit = "nixos-update-checker-background.service";
      };
    };
  };
}
