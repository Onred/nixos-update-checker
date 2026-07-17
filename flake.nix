{
  description = "Graphical NixOS update checker using realized system builds";

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
          "source-${builtins.substring 7 12 self.narHash}"
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
          meta.description = "Open the NixOS Update Checker";
        };
        gui = {
          type = "app";
          program = "${self.packages.${system}.default}/bin/nixos-update-checker";
          meta.description = "Open the NixOS Update Checker";
        };
        cli = {
          type = "app";
          program = "${self.packages.${system}.default}/bin/check-nixos-updates";
          meta.description = "Build and compare a candidate system in a terminal";
        };
      });

      checks = forAllSystems (
        system:
        let
          pkgs = pkgsFor system;
          evaluation = nixpkgs.lib.nixosSystem {
            inherit system;
            modules = [
              self.nixosModules.default
              {
                programs.nixos-update-checker.enable = true;
                system.stateVersion = "26.05";
              }
            ];
          };
          cfg = evaluation.config;
          service = cfg.systemd.services.nixos-update-checker.serviceConfig;
          timer = cfg.systemd.timers.nixos-update-checker.timerConfig;
        in
        {
          package = self.packages.${system}.default;
          module =
            assert service.User == "root";
            assert service.CPUQuota == "100%";
            assert service.CPUQuotaPeriodSec == "10ms";
            assert builtins.elem "/nix/store" service.ReadWritePaths;
            assert timer.OnUnitActiveSec == "24h";
            assert timer.Persistent;
            assert cfg.environment.etc ? "xdg/autostart/nixos-update-checker.desktop";
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
