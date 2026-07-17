# NixOS Update Checker

A PySide6 desktop application for checking and applying updates to the currently
running, flake-based NixOS system.

The checker has one source of truth: it resolves updated inputs into a temporary
lock file, builds the complete candidate NixOS system, and compares that realized
closure with the running system. There is no package manifest, recursive package
set search, manual package list, or fast approximation.

The temporary candidate lock and completed build do not modify the repository,
create a system generation, or switch the machine. The **Rebuild** action is the
only operation that updates the real `flake.lock` and applies a system.

## What the GUI shows

The main update list has three native list sections:

- **Flake**: a locked input changed.
- **Package**: a package was added, removed, or has a different parsed version in
  the realized candidate closure.
- **Rebuild**: one aggregate row for paths whose package version is unchanged but
  whose store identity changed. Selecting it lists every underlying path change.

Flake inputs appear first, packages second, and the rebuild-only aggregate last.
There is no type column or custom window frame; the desktop supplies the normal
window decorations. Selecting a row shows old versions and other detail in the
Information tab. The Activity tab shows output from refresh, rebuild, and garbage
collection commands.

**Refresh** performs a complete unrestricted candidate build. **Rebuild** updates
the repository lock, runs `nixos-rebuild switch`, and then refreshes the report.
Optional garbage collection runs only after a successful rebuild and retains 30
days by default.

Opening the GUI loads the last report written by the background service. It does
not automatically start a second build.

The backend compares the system derivation described by the saved configuration
with `/run/current-system`, so saved-but-unapplied changes remain in the report.
Package comparisons keep using the running closure as their baseline until a
rebuild is applied; merely changing `flake.lock` does not make pending changes
disappear.

Flake inputs use an applied-lock snapshot instead of assuming the working lock is
running. A successful Rebuild records the applied lock, and a background check
also refreshes the snapshot whenever the saved system derivation exactly matches
the running derivation. Before the first snapshot exists, the embedded running
NixOS nixpkgs revision keeps the primary `nixpkgs` row accurate. Arbitrary
third-party input revisions cannot be reconstructed from a realized NixOS closure
after the fact, so their fully accurate applied baseline begins once a snapshot
has been recorded.

As with every Git-backed Nix flake, newly created source files must be staged
before Nix includes them, though they do not need to be committed.

## Install on NixOS

Add the flake input, normally following the system's nixpkgs input:

```nix
inputs.nixos-update-checker = {
  url = "github:Onred/nixos-update-checker";
  inputs.nixpkgs.follows = "nixpkgs";
};
```

Import the module:

```nix
{
  imports = [ inputs.nixos-update-checker.nixosModules.default ];

  programs.nixos-update-checker = {
    enable = true;
    repository = "/etc/nixos";
  };
}
```

This installs the application, adds its desktop and tray autostart entries, and
enables the background timer. The flake exports packages and apps for
`x86_64-linux` and `aarch64-linux`.

The app only checks the running machine. With one `nixosConfigurations` entry,
that entry is selected regardless of its attribute name. With several entries,
the checker evaluates `config.networking.hostName` and requires exactly one match
for `/proc/sys/kernel/hostname`. It does not require a custom `config.nix`, and
the flake attribute name does not need to equal the hostname.

## Background builds

The system timer defaults to one build per day:

```nix
programs.nixos-update-checker = {
  cpuQuota = "100%";
  tray.enable = true;

  service = {
    enable = true;
    onBootSec = "20m";
    interval = "24h";
    randomizedDelaySec = "1h";
  };
};
```

`cpuQuota = "100%"` means one CPU's aggregate throughput, not 100% of every CPU.
The service uses a short 10 ms quota period, lowest CPU and I/O weights, nice 19,
and idle I/O scheduling. This makes CPU time arrive in small slices rather than
as sustained one-core bursts.

The service deliberately runs Nix against the direct local store. Normal daemon
builders live in `nix-daemon.service` and do not inherit the calling service's
cgroup, so they would escape its CPU quota. Direct local builders remain inside
`nixos-update-checker.service` and share its aggregate limit.

Nix job parallelism adapts to the available logical CPUs and is capped at 32
workers. It chooses an approximately square jobs-by-cores allocation:

| Logical CPUs | Nix jobs | Cores per job | Worker budget |
|---:|---:|---:|---:|
| 1 | 1 | 1 | 1 |
| 4 | 2 | 2 | 4 |
| 8 | 2 | 4 | 8 |
| 16 | 4 | 4 | 16 |
| 32 or more | 5 | 6 | 32 |

This is portable to small and large systems: all values have a minimum of one,
and unexpectedly large CPU counts cannot create unbounded Nix concurrency. The
cgroup quota remains the actual usage limit; job counts only distribute the work.
Individual build systems may still ignore Nix's requested core count or perform a
single-threaded phase, so perfectly even utilization cannot be guaranteed.

Candidate builds can download and retain additional store paths. Garbage
collection is therefore recommended if background checks materially increase
storage use. Configure it in the GUI; it never runs after a check, only after an
applied rebuild.

Useful diagnostics:

```console
systemctl status nixos-update-checker.timer
sudo systemctl start nixos-update-checker.service
journalctl -u nixos-update-checker.service
```

The service atomically publishes its report at
`/var/lib/nixos-update-checker/report.json`, which is readable by the desktop app.

## Run without installing the module

The GUI can perform foreground checks and rebuilds by itself:

```console
nix run . -- /path/to/nixos-flake
```

The NixOS module is required only for installation, desktop autostart, and the
limited background timer. The GUI remembers a chosen repository in Qt's per-user
settings. A packaged module default, positional GUI argument, or the
`NIXOS_UPDATE_CHECKER_REPOSITORY` environment variable can supply the initial
path.

A small terminal backend remains because it is useful for diagnostics and costs
almost no additional code:

```console
check-nixos-updates /path/to/nixos-flake
check-nixos-updates --json /path/to/nixos-flake
nix run .#cli -- --json /path/to/nixos-flake
```

These foreground commands are unrestricted. `--background` is reserved for the
root-owned system service because direct local-store access requires root.

## Development environment

All dependencies are supplied by the flake:

```console
nix develop
pytest
ruff check src tests
mypy src
```

For a checkout-specific default repository, create the ignored `.env.local`:

```console
NIXOS_UPDATE_CHECKER_REPOSITORY=/absolute/path/to/your/nixos-flake
```

The repository includes `.envrc`, VS Code settings, and extension
recommendations. With `direnv` and `nix-direnv` installed, run `direnv allow`
once. The recommended VS Code direnv extension then enters the development shell
when this folder opens, and `.venv` plus `.nixd` symlinks let Python, PySide6, and
Nix language tooling resolve automatically. Automatic direnv extension-host
restarts and file watching are disabled in the workspace settings to avoid VS
Code reload loops.

Validation commands used for releases are:

```console
pytest
ruff check src tests
mypy src
QT_QPA_PLATFORM=offscreen nixos-update-checker --self-test --no-tray
nix flake check
nix build .#default
```

## Safety boundaries

- A check keeps the working `flake.lock` byte-for-byte unchanged.
- A check builds but never activates the candidate system.
- Rebuild is the only action that updates the real lock and switches NixOS.
- Garbage collection is opt-in and follows only a successful applied rebuild.
- Background limiting applies to builders because the service uses the direct
  local store; foreground Refresh and Rebuild remain unrestricted.
