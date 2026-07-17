{
  description = "Quiet NixOS update builds with a native Qt report viewer";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs =
    { self, nixpkgs }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];
      eachSystem = nixpkgs.lib.genAttrs systems;
      pkgsFor = system: import nixpkgs { inherit system; };
    in
    {
      packages = eachSystem (system: rec {
        default = import ./nix/package.nix { pkgs = pkgsFor system; };
        nixos-update-checker = default;
      });

      apps = eachSystem (system: {
        default = {
          type = "app";
          program = "${self.packages.${system}.default}/bin/nixos-update-checker";
          meta.description = "Open the NixOS Update Checker";
        };
      });

      checks = eachSystem (system: {
        default = self.packages.${system}.default;
      });

      devShells = eachSystem (system: {
        default = (pkgsFor system).mkShell {
          packages = with pkgsFor system; [
            jq
            nixfmt-tree
            pkg-config
            qt6.qtbase
            shellcheck
          ];
        };
      });

      formatter = eachSystem (system: (pkgsFor system).nixfmt-tree);

      nixosModules.default = import ./nix/module.nix;
    };
}
