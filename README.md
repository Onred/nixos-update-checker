# NixOS Update Checker

Checks a NixOS flake for newer locked inputs and package derivations without
modifying the repository's `flake.lock`.

This is currently a terminal backend with a versioned JSON interface intended
for a future Qt application.

## Flake outputs

- `packages.<system>.default`: `check-nixos-updates` command
- `apps.<system>.default`: runnable command
- `nixosModules.default`: NixOS integration and evaluated package manifest

## Import the NixOS module

Add the input and make it follow the host's nixpkgs:

```nix
inputs.nixos-update-checker = {
  url = "github:Onred/nixos-update-checker";
  inputs.nixpkgs.follows = "nixpkgs";
};
```

Then import and enable the module:

```nix
{
  imports = [ inputs.nixos-update-checker.nixosModules.default ];

  programs.nixos-update-checker.enable = true;
}
```

For local development, use:

```nix
inputs.nixos-update-checker.url = "path:/home/onred/Projects/nixos-update-checker";
```

## Usage

Run from the NixOS configuration repository:

```console
check-nixos-updates
check-nixos-updates --debug
check-nixos-updates --json
```

The complete package comparison requires the NixOS module because its manifest
is generated from the host's evaluated configuration and option metadata.
Without importing the module, `nix run` can still perform a source-only check:

```console
nix run github:Onred/nixos-update-checker -- --source-only /path/to/nixos-config
```

## JSON backend

`--json` reserves stdout for a schema-versioned report suitable for a GUI
process. Diagnostics are written to stderr. The current backend version is
available with:

```console
check-nixos-updates --version
```
