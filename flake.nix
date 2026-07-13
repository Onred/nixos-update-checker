{
  description = "Inspect pending NixOS flake and package updates without modifying flake.lock";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs = { self, nixpkgs }:
    let
      supportedSystems = [
        "x86_64-linux"
        "aarch64-linux"
      ];
      forAllSystems = nixpkgs.lib.genAttrs supportedSystems;
      pkgsFor = system: import nixpkgs { inherit system; };
    in
    {
      packages = forAllSystems (system: {
        default = import ./nix/package.nix {
          pkgs = pkgsFor system;
        };
      });

      apps = forAllSystems (system: {
        default = {
          type = "app";
          program = "${self.packages.${system}.default}/bin/check-nixos-updates";
          meta.description = "Check a NixOS flake for pending input and package updates";
        };
      });

      checks = forAllSystems (system: {
        package = self.packages.${system}.default;
      });

      formatter = forAllSystems (system: (pkgsFor system).nixfmt-tree);

      nixosModules = {
        default = import ./nix/module.nix;
        nixos-update-checker = self.nixosModules.default;
      };
    };
}
