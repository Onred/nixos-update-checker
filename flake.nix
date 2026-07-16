{
  description = "Qt NixOS flake update checker with tray and background service integration";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs =
    { self, nixpkgs }:
    let
      supportedSystems = [
        "x86_64-linux"
        "aarch64-linux"
      ];
      forAllSystems = nixpkgs.lib.genAttrs supportedSystems;
      pkgsFor = system: import nixpkgs { inherit system; };
      revision =
        if self ? shortRev then
          self.shortRev
        else if self ? dirtyShortRev then
          self.dirtyShortRev
        else if self ? narHash then
          "dirty-${builtins.substring 7 12 self.narHash}"
        else
          "unknown";
    in
    {
      packages = forAllSystems (system: rec {
        default = import ./nix/package.nix {
          pkgs = pkgsFor system;
          inherit revision;
        };
        nixos-update-checker = default;
      });

      apps = forAllSystems (system: {
        default = {
          type = "app";
          program = "${self.packages.${system}.default}/bin/nixos-update-checker";
          meta.description = "Open the NixOS Update Checker Qt application";
        };
        gui = {
          type = "app";
          program = "${self.packages.${system}.default}/bin/nixos-update-checker";
          meta.description = "Open the NixOS Update Checker Qt application";
        };
        cli = {
          type = "app";
          program = "${self.packages.${system}.default}/bin/check-nixos-updates";
          meta.description = "Run the NixOS update checker backend in a terminal";
        };
      });

      checks = forAllSystems (
        system:
        let
          pkgs = pkgsFor system;
          componentFixture =
            if pkgs.stdenv.hostPlatform.isx86_64 then
              {
                package = pkgs.linuxPackages.nvidia_x11;
                component = "open";
                pname = "nvidia-open";
              }
            else
              {
                package = pkgs.hello // {
                  passthru = (pkgs.hello.passthru or { }) // {
                    driver = pkgs.jq;
                  };
                };
                component = "driver";
                pname = "jq";
              };
          fixtureModule =
            { lib, pkgs, ... }:
            {
              options.services.update-checker-enabled = {
                enable = lib.mkEnableOption "update checker manifest fixture";
                package = lib.mkOption {
                  type = lib.types.package;
                  default = pkgs.hello;
                };
                packages = lib.mkOption {
                  type = lib.types.listOf lib.types.package;
                  default = [ pkgs.jq ];
                };
              };
              options.services.update-checker-disabled = {
                enable = lib.mkEnableOption "disabled update checker manifest fixture";
                package = lib.mkOption {
                  type = lib.types.package;
                  default = pkgs.curl;
                };
              };
              options.hardware.update-checker-manual.package = lib.mkOption {
                type = lib.types.package;
                default = pkgs.git;
              };
              options.hardware.update-checker-component.package = lib.mkOption {
                type = lib.types.package;
                default = componentFixture.package;
              };

              config = {
                services.update-checker-enabled.enable = true;
                services.update-checker-disabled.enable = false;
              };
            };
          hostModule =
            { pkgs, ... }:
            {
              hardware.graphics = {
                enable = true;
                extraPackages = [ pkgs.libglvnd ];
              };
              system.stateVersion = "26.05";
            };
          moduleEvaluation = nixpkgs.lib.nixosSystem {
            inherit system;
            modules = [
              self.nixosModules.default
              fixtureModule
              hostModule
              { programs.nixos-update-checker.enable = true; }
            ];
          };
          moduleConfig = moduleEvaluation.config;
          standaloneEvaluation = nixpkgs.lib.nixosSystem {
            inherit system;
            modules = [
              fixtureModule
              hostModule
            ];
          };
          standaloneManifest = import ./nix/manifest.nix {
            inherit (standaloneEvaluation) config options;
          };
          standalonePriorityOptionManifest = import ./nix/manifest.nix {
            inherit (standaloneEvaluation) config options;
            includePriorityOptionPackages = true;
          };
        in
        {
          package = self.packages.${system}.default;
          module =
            assert moduleConfig.systemd.services.nixos-update-checker.serviceConfig.CPUQuota == "25%";
            assert moduleConfig.systemd.timers.nixos-update-checker.timerConfig.OnUnitActiveSec == "6h";
            assert moduleConfig.environment.etc ? "xdg/autostart/nixos-update-checker.desktop";
            assert builtins.length standaloneManifest.corePackages == 2;
            assert builtins.any (
              package: package.option == "hardware.graphics.package"
            ) standaloneManifest.activeOptionPackages;
            assert builtins.any (
              package: package.option == "hardware.graphics.extraPackages"
            ) standaloneManifest.activeOptionPackages;
            assert builtins.any (
              package: package.option == "services.update-checker-enabled.package"
            ) standaloneManifest.activeOptionPackages;
            assert builtins.any (
              package: package.option == "services.update-checker-enabled.packages"
            ) standaloneManifest.activeOptionPackages;
            assert
              !(builtins.any (
                package: package.option == "services.update-checker-disabled.package"
              ) standaloneManifest.activeOptionPackages);
            assert
              !(builtins.any (
                package: package.option == "hardware.update-checker-manual.package"
              ) standaloneManifest.activeOptionPackages);
            assert builtins.any (
              package: package.option == "hardware.update-checker-manual.package"
            ) standalonePriorityOptionManifest.priorityOptionPackages;
            assert builtins.any (
              package:
              package.option == "hardware.update-checker-component.package"
              && (package.component or null) == componentFixture.component
              && (package.pname or null) == componentFixture.pname
            ) standalonePriorityOptionManifest.priorityOptionPackages;
            pkgs.runCommand "nixos-update-checker-module-check" { } ''
              touch "$out"
            '';
        }
      );

      devShells = forAllSystems (
        system:
        let
          pkgs = pkgsFor system;
          python = pkgs.python3.withPackages (
            pythonPackages: with pythonPackages; [
              mypy
              pyside6
              pytest
              pytest-cov
            ]
          );
        in
        {
          default = pkgs.mkShell {
            packages = [
              pkgs.nixfmt-tree
              pkgs.ruff
              python
              (pkgs.lib.getBin pkgs.coreutils)
              (pkgs.lib.getBin pkgs.jq)
              (pkgs.lib.getBin pkgs.nix)
              (pkgs.lib.getBin pkgs.nixd)
              (pkgs.lib.getBin pkgs.systemd)
              (pkgs.lib.getBin pkgs.util-linux)
            ];

            shellHook = ''
              ln -sfn ${python} .venv
              ln -sfn ${pkgs.lib.getExe pkgs.nixd} .nixd
              export PYTHONPATH="$PWD/src''${PYTHONPATH:+:$PYTHONPATH}"
            '';
          };
        }
      );

      formatter = forAllSystems (system: (pkgsFor system).nixfmt-tree);

      nixosModules = {
        default = import ./nix/module.nix { inherit revision; };
        nixos-update-checker = self.nixosModules.default;
      };
    };
}
