# NixOS Update Checker

A small NixOS service that quietly builds an updated system once a day, plus a
native Qt application that displays the resulting report.

The application has a deliberately narrow boundary:

- `nixos-update-checker-service` resolves a temporary candidate `flake.lock`,
  builds it, compares it with the appropriate system generation, and atomically
  writes a schema-2 JSON report.
- `nixos-update-checker` reads that JSON and asks systemd to start the service
  when **Check now** is selected.
- `nixos-update-checker-apply` updates the real lock and switches the reported
  configuration when the GUI starts the apply service.

The GUI itself does not run Nix, modify the configuration, collect garbage, or
duplicate service logs. Check and apply operations remain root-owned systemd
services, with their output available through `journalctl`.

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
daily persistent timer with up to one hour of random delay. A systemd path unit
also starts the same low-priority check whenever the default system profile
changes outside this application.

Only three module options are exposed:

| Option | Default | Purpose |
|---|---:|---|
| `enable` | `false` | Install and enable the checker. |
| `repository` | `/etc/nixos` | Absolute path to the NixOS flake. |
| `cpuQuota` | `25%` | Aggregate CPU quota for background checks. |

For example, `cpuQuota = "25%"` limits both single-threaded evaluation and
parallel builds to one quarter of a CPU's total throughput. Nix workers and
their cores are still split with the following bounded square allocation:

| Available CPUs | Nix jobs | Cores per job | Worker budget |
|---:|---:|---:|---:|
| 1 | 1 | 1 | 1 |
| 4 | 2 | 2 | 4 |
| 8 | 2 | 4 | 8 |
| 16 | 4 | 4 | 16 |
| 32 or more | 5 | 6 | 32 |

This lets independent builds and multithreaded build phases share the available
CPUs instead of forcing all work through one builder. No Nix job setting can
guarantee that an individual compiler thread never briefly uses a complete core.

The service uses the direct local Nix store. This is intentional: work delegated
to `nix-daemon.service` would leave the checker's cgroup and escape its CPU
limit. CPU and I/O weights, nice level, and idle I/O scheduling further favor
interactive work.

## Use

Open **NixOS Update Checker** from the application launcher or system tray. The
window contains only:

- a flat table showing package name, new version or removal, and closure delta;
- a vertically draggable text area with complete versions, closure sizes, and
  store paths for the selected row;
- a generation line describing a system that is ready for the next boot;
- report time and configuration;
- **Check now** and **Apply update** buttons that start their systemd services.

Top-level flake inputs appear first, changed packages are sorted alphabetically,
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
journalctl -u nixos-update-checker.service
journalctl -u nixos-update-checker-apply.service
sudo systemctl start nixos-update-checker.service
```

## Safety and scope

- A check never modifies the working `flake.lock`.
- A check builds but never activates the candidate system.
- Applying requires confirmation, updates the real `flake.lock`, and runs
  `nixos-rebuild switch` for the configuration recorded in the report.
- When the default boot profile differs from the running system, both package
  and input comparisons use that newer boot generation. This avoids reporting
  work already present after `nixos-rebuild boot` or while manually running an
  older generation.
- The checker stores one system-bound lock snapshot in
  `/var/lib/nixos-update-checker/system-lock.json`. If no complete lock can be
  matched to the baseline system, it recovers only nixpkgs history from that
  system and marks the report incomplete.
- Apply is disabled for stale reports, incomplete input history, schema-1
  reports, and reports with no remaining updates. The root apply helper repeats
  the live profile check before modifying anything.
- Only changed top-level flake inputs are reported.
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
