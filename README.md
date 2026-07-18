# NixOS Update Checker

A small NixOS service that previews updates from the active configuration
without performing background builds, plus an opt-in verifier and a native Qt
application that displays their reports.

The application has a deliberately narrow boundary:

- `nixos-update-checker-service` resolves a temporary candidate `flake.lock`,
  evaluates configured packages, queries local and configured binary caches,
  and atomically writes a schema-3 preview without realizing the candidate.
- `nixos-update-checker-build.service` is started explicitly to run a normal,
  unrestricted Nix build of that exact candidate and replace the preview with
  a verified closure report.
- `nixos-update-checker` reads that JSON and asks systemd to start the service
  when **Refresh** is selected.
- `nixos-update-checker-apply` installs the reviewed candidate lock and switches
  the verified configuration when the GUI starts the privileged apply service.

The GUI itself does not run Nix, modify the configuration, or collect garbage.
Preview, build, and update operations remain root-owned systemd services. The
GUI is only a state reader and service launcher; it never evaluates Nix itself.

## Install

Add the flake input:

```nix
inputs.nixos-update-checker = {
  url = "github:Onred/nixos-update-checker";
  inputs.nixpkgs.follows = "nixpkgs";
};
```

Import and enable the module:

```nix
{
  imports = [ inputs.nixos-update-checker.nixosModules.default ];

  programs.nixos-update-checker = {
    enable = true;
    repository = "/etc/nixos";
  };
}
```

The module installs the app, starts it from desktop autostart, and enables a
persistent timer that checks ten minutes after boot and then daily. A systemd
path unit also starts the same low-priority check whenever the default system
profile changes outside this application.

Only four module options are exposed:

| Option | Default | Purpose |
|---|---:|---|
| `enable` | `false` | Install and enable the checker. |
| `repository` | `/etc/nixos` | Absolute path to the NixOS flake. |
| `cpuQuota` | `50%` | Aggregate CPU quota for background checks; `null` disables it. |
| `extraPackages` | `{}` | Named packages to preview when automatic discovery cannot find them. |

The quota applies only to automatic previews, which can still contain Nix
evaluation work. Set `cpuQuota = null` to disable that throttle while retaining
low CPU/I/O weights and idle I/O scheduling. The explicit build service has no
quota: it uses normal Nix scheduling because a heavily throttled source build
can otherwise take hours.

Discovery starts with the kernel, Nix, systemd, active NVIDIA driver, Ollama,
system/user/font packages, systemd service paths, and active package-valued
module options. It then uses the candidate derivation graph to fill gaps for
packages already present in the baseline. Site-specific packages can be added
without changing this project:

```nix
programs.nixos-update-checker.extraPackages = {
  inherit (pkgs) my-custom-package;
};
```

## Use

Open **NixOS Update Checker** from the application launcher or system tray. The
window contains only:

- a flat table showing package name, new version or removal, and closure delta;
- a vertically draggable text area with complete versions, closure sizes, and
  store paths for the selected row, plus live service output;
- a generation line describing a system that is ready for the next boot;
- report time and configuration;
- **Refresh** and one state-dependent update button above the table. A preview
  offers **Build Update**; a verified report offers **Update**.

The tray icon uses a colored status badge: orange means updates are pending,
green means the report is current with no updates, blue means work is running,
and red means the last check failed. Its tooltip follows the live service state
and shows the cached update counts while idle.

The GUI reads optional user settings from
`$XDG_CONFIG_HOME/nixos-update-checker/nixos-update-checker.conf` (normally
`~/.config/nixos-update-checker/nixos-update-checker.conf`). Supported keys in
the `[General]` section are `trayEnabled` and `reportPath`. Explicit command-line
options take precedence, followed by this file, packaged environment defaults,
and built-in defaults. The obsolete `windowGeometry` key from older releases is
removed automatically; window placement is left to the desktop.

```ini
[General]
trayEnabled=true
reportPath=/var/lib/nixos-update-checker/report.json
```

An active local desktop user may start the preview and explicit build services
without authentication. Updating the active system is a separate service and
still requires administrator authentication. After a successful update, the GUI
restarts from the newly activated system so an updated checker is loaded too.

Direct configuration inputs appear first, changed packages are sorted alphabetically,
and unchanged-version rebuilds are represented by one aggregate row. Long
version lists remain short in the table and are shown in full in the details
area.

The size column is the signed net closure change: paths added to the candidate
minus paths no longer referenced by it. This is a comparison metric, not an
exact prediction of freed or consumed disk space. Candidate paths may already
exist in the Nix store, and old generations may continue to retain removed
paths.

The report is stored at `/var/lib/nixos-update-checker/report.json`.

Service diagnostics remain in the system journal:

```console
systemctl status nixos-update-checker.timer
systemctl status nixos-update-checker.path
systemctl status nixos-update-checker.service
systemctl status nixos-update-checker-build.service
journalctl -u nixos-update-checker.service
journalctl -u nixos-update-checker-build.service
journalctl -u nixos-update-checker-apply.service
systemctl start nixos-update-checker.service
systemctl start nixos-update-checker-build.service
sudo systemctl start nixos-update-checker-apply.service
jq . /var/lib/nixos-update-checker/report.json
```

## Safety and scope

- A preview never modifies the working `flake.lock` or realizes the candidate.
- A manual build realizes the exact saved candidate but never activates it.
- Applying requires confirmation, installs the exact reviewed `flake.lock`, and runs
  `nixos-rebuild switch` for the configuration recorded in the report.
- When the default boot profile differs from the running system, both package
  and input comparisons use that newer boot generation. This avoids reporting
  work already present after `nixos-rebuild boot` or while manually running an
  older generation.
- The checker stores one system-bound lock snapshot in
  `/var/lib/nixos-update-checker/system-lock.json`. If no complete lock can be
  matched to the baseline system, it recovers only nixpkgs history from that
  system and marks the report incomplete.
- Apply is disabled for previews, stale reports, incomplete input history, old
  reports, and reports with no remaining updates. The root apply helper repeats
  the live profile check before modifying anything.
- Only changed inputs declared directly by the configuration flake are reported.
  These are not every transitive node in `flake.lock`: direct inputs may
  themselves be flakes or non-flake sources, and direct `follows`
  references are resolved before comparison.
- The service currently requires `flake.nix` and `flake.lock`.

Supporting arbitrary non-flake configurations would require a separate answer
to “which nixpkgs source should be updated?” A plain configuration build alone
cannot discover available updates reproducibly, so that ambiguity is kept out of
the service rather than hidden behind more options.

## Development

The flake is the complete development and validation interface:

```console
nix develop
shellcheck src/checker.sh src/apply.sh
tests/checker-fixtures.sh ./src/checker.sh
nix fmt
nix flake check
nix build
```

There is no Python environment, generated editor configuration, or unit-test
framework. The package build compiles the C++ application, checks the Bash
service with ShellCheck, and smoke-tests both installed command-line interfaces.
