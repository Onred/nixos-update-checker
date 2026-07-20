# NixOS Update Checker

A small NixOS service that previews updates from the active configuration
without performing background builds, plus an opt-in verifier and a native Qt
application that displays their reports.

The application has a deliberately narrow boundary:

- `nixos-update-checker-service` resolves a temporary candidate `flake.lock`,
  evaluates configured packages, queries local and configured binary caches,
  and atomically writes a schema-3 preview without realizing the candidate.
- `nixos-update-checker-background.service` runs that preview automatically
  with the configured quota and low scheduling priority. Manual **Refresh**
  uses the unrestricted `nixos-update-checker.service` instead.
- `nixos-update-checker-build.service` is started explicitly to run a normal,
  unrestricted Nix build of that exact candidate and replace the preview with
  a verified closure report.
- `nixos-update-checker` reads that JSON and asks systemd to start the service
  when **Refresh** is selected.
- `nixos-update-checker-apply` installs the reviewed candidate lock and either
  switches immediately or makes the verified configuration the next boot target.
  A dedicated low-impact finalize service then refreshes the displayed state as
  the last phase of that installation.

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
persistent timer that checks within about ten minutes after boot and then every
six hours, with up to five minutes of randomized delay. A systemd path unit also
starts the same low-priority check whenever the default system profile changes
outside this application.

Only four module options are exposed:

| Option | Default | Purpose |
|---|---:|---|
| `enable` | `false` | Install and enable the checker. |
| `repository` | `/etc/nixos` | Absolute path to the NixOS flake. |
| `cpuQuota` | `50%` | Aggregate CPU quota for background checks; `null` disables it. |
| `extraPackages` | `{}` | Named packages to preview when automatic discovery cannot find them. |

The quota applies only to automatic previews, which can still contain Nix
evaluation work. Set `cpuQuota = null` to disable that throttle while retaining
low CPU/I/O weights and idle I/O scheduling. Manual refreshes and explicit
builds have no quota.

Discovery starts with the kernel, Nix, systemd, active NVIDIA driver, Ollama,
system/user/font packages, systemd service paths, and active package-valued
module options. Cache metadata expands coverage without being treated as a
complete candidate closure. Site-specific packages can be added without
changing this project:

```nix
programs.nixos-update-checker.extraPackages = {
  inherit (pkgs) my-custom-package;
};
```

## Use

Open **NixOS Update Checker** from the application launcher or system tray. The
window contains only:

- a flat table showing package name, new version or removal, and closure delta;
- a vertically draggable tabbed area: **Details** shows complete versions,
  closure sizes, and store paths, while **Progress** shows live service output;
- a generation line describing a system that is ready for the next boot;
- report time and configuration;
- the application version at the bottom-left;
- state-dependent controls above the table. A preview offers **Build Update**;
  a verified report offers **Update Now** and **Install for Next Boot**. Active
  refreshes and builds expose **Cancel Refresh** or **Cancel Build**.

The application and tray use standard desktop-theme update, refresh, warning,
error, and success icons. The tooltip follows the live service state and shows
the cached update counts while idle.

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

An active local desktop user may start or cancel preview and explicit build
services without authentication. Installing either kind of system update is a
separate service and still requires administrator authentication. After a
successful immediate update, a banner offers to restart the GUI when the newly
activated system contains a different updater package. The old tray instance is
hidden before its replacement starts. The banner uses the active Qt theme's
highlight and highlighted-text colors.

All preview, build, and install services share one operation lock. A timed or
profile-triggered preview cannot run concurrently with or interrupt a manual
build or install. Explicit builds and both install actions also hold a systemd
inhibitor against sleep, hibernation, reboot, and shutdown until they finish or
are cancelled. Refreshes remain uninhibited. A successful install starts a
dedicated low-impact finishing check after releasing the shared lock. The GUI
presents this as part of the installation rather than a separate refresh.

Direct configuration inputs appear first, changed packages are sorted alphabetically,
and unchanged-version rebuilds are represented by one aggregate row. Long
version lists remain short in the table and are shown in full in the details
area. Generated unversioned outputs such as NixOS documentation and indexes are
grouped into one **NixOS system data** row instead of being presented as packages.

Verified reports show signed net closure change: paths added to the candidate
minus paths no longer referenced by it. Preview reports leave size unknown and
never infer removals. Closure change is a comparison metric, not an exact disk
space prediction; old generations can retain removed paths.

The last successful report is stored at
`/var/lib/nixos-update-checker/report.json`. Live operation state and the most
recent failure or cancellation are stored separately at
`/var/lib/nixos-update-checker/status.json`, so a bad configuration cannot erase
the last useful report. Each successful explicit build also keeps one bounded
diagnostic pair at `last-build-preview.json` and `last-build-verified.json` in
the same directory. The verified copy records names missed by the preview and
preview-only names; a later refresh does not overwrite this pair.

Service diagnostics remain in the system journal:

```console
systemctl status nixos-update-checker.timer
systemctl status nixos-update-checker.path
systemctl status nixos-update-checker.service
systemctl status nixos-update-checker-background.service
systemctl status nixos-update-checker-build.service
systemctl status nixos-update-checker-finalize.service
journalctl -u nixos-update-checker.service
journalctl -u nixos-update-checker-background.service
journalctl -u nixos-update-checker-build.service
journalctl -u nixos-update-checker-finalize.service
journalctl -u nixos-update-checker-apply.service
journalctl -u nixos-update-checker-boot.service
systemctl start nixos-update-checker.service
systemctl start nixos-update-checker-build.service
sudo systemctl start nixos-update-checker-apply.service
sudo systemctl start nixos-update-checker-boot.service
jq . /var/lib/nixos-update-checker/report.json
jq . /var/lib/nixos-update-checker/status.json
jq . /var/lib/nixos-update-checker/last-build-preview.json
jq . /var/lib/nixos-update-checker/last-build-verified.json
```

For a destructive end-to-end regression using an older lock, see
`scripts/live-regression-test.sh`. It preserves the current updater input and
lock backup, creates an old-content generation, deletes other system
generations, runs garbage collection, and validates the resulting report before
leaving it ready for the GUI's Build Update and install flow.

## Safety and scope

- A preview never modifies the working `flake.lock` or realizes the candidate.
- A preview never treats missing cache metadata as a removal or as a complete
  runtime closure. Exact removals and closure sizes require a realized candidate.
- Package-valued module options are discovery hints, not proof of closure
  membership. A preview accepts an updated option package only when the same
  option source supplied a package proven present in the realized baseline.
  Explicit configured packages remain eligible as additions.
- A manual build realizes the exact saved candidate but never activates it.
- Installing is privileged, installs the exact reviewed `flake.lock`, and runs
  either `nixos-rebuild switch` or `nixos-rebuild boot` for the configuration
  recorded in the report.
- Failed and cancelled operations leave the last successful report and reviewed
  candidate untouched. Manual operations do not restart automatically;
  automatic previews retry only transient failures and stop after bounded retries.
- When the default boot profile differs from the running system, both package
  and input comparisons use that newer boot generation. This avoids reporting
  work already present after `nixos-rebuild boot` or while manually running an
  older generation.
- The checker stores one system-bound lock and package-discovery snapshot in
  `/var/lib/nixos-update-checker/system-lock.json`. If no complete lock can be
  matched to the baseline system, it recovers only nixpkgs history from that
  system and marks the report incomplete.
- Apply is disabled for previews, out-of-date reports, old report formats, and
  reports with no remaining updates. Missing historical input data affects only
  the source-change summary; it does not block an exact update that has already
  been built and verified. The root apply helper repeats the live system and
  configuration checks before modifying anything.
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
