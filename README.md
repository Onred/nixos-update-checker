# NixOS Update Checker

A Qt 6 application written in typed Python with the official PySide6 bindings
for inspecting and applying updates to the currently running flake-based NixOS
system. It includes a desktop window, tray status, a JSON/CLI checker, and a
low-priority systemd timer.

The checker resolves candidate inputs in a temporary lock file, compares the
evaluated NixOS package manifest, and leaves the repository unchanged. Changes
are made only when **Update inputs** is selected; the GUI requests administrator
authorization when the repository is not writable by the desktop user.
**Rebuild system** always requests authorization and runs `nixos-rebuild switch`
for the configuration discovered as belonging to the current machine.

**Check now** evaluates important candidate packages and compares them with the
realized `/run/current-system` closure. Saved lock-file or configuration changes
therefore remain visible until they are actually rebuilt. **Check with build**
uses the temporary updated lock file to build the complete candidate NixOS
system, then compares both realized closures. It does not modify `flake.lock`,
create a profile generation, or apply the result.

## Nix flake outputs

- `packages.<system>.default`: Qt GUI plus the checker and service commands
- `apps.<system>.default` / `apps.<system>.gui`: Qt GUI
- `apps.<system>.cli`: terminal JSON/human-readable checker
- `nixosModules.default`: NixOS package, tray autostart, service, and timer

The flake currently supports `x86_64-linux` and `aarch64-linux`. Python,
PySide6, and every runtime tool come from the locked nixpkgs input.

## Install on NixOS

Add the input and make it follow the host's nixpkgs:

```nix
inputs.nixos-update-checker = {
  url = "github:Onred/nixos-update-checker";
  inputs.nixpkgs.follows = "nixpkgs";
};
```

Import and configure the module:

```nix
{
  imports = [ inputs.nixos-update-checker.nixosModules.default ];

  programs.nixos-update-checker = {
    enable = true;
    repository = "/etc/nixos";
  };
}
```

The application is intentionally limited to the running system. If the flake
has one `nixosConfigurations` entry, that entry is used. If it has several,
the checker evaluates their `config.networking.hostName` values and selects the
unique entry matching `/proc/sys/kernel/hostname`. The flake attribute name
does not need to equal the hostname. Missing or ambiguous matches are reported
as errors instead of exposing cross-host controls.

After the next NixOS rebuild this installs `nixos-update-checker` and
`check-nixos-updates`, adds the GUI to application menus, starts its tray icon
for desktop sessions, and enables `nixos-update-checker.timer`.

For local flake development:

```nix
inputs.nixos-update-checker.url = "path:/home/onred/Projects/nixos-update-checker";
```

### Background service options

The defaults run a check ten minutes after boot and every six hours with up to
thirty minutes of randomized delay:

```nix
programs.nixos-update-checker = {
  cpuQuota = "25%";
  tray.enable = true;

  service = {
    enable = true;
    user = "root";
    onBootSec = "10m";
    interval = "6h";
    randomizedDelaySec = "30m";
  };
};
```

The system service uses the configured CPU quota, CPU/IO weight 1, nice level
19, and idle I/O scheduling. It atomically publishes the latest report at
`/var/lib/nixos-update-checker/report.json`; the GUI reloads that file while it
is running. Set `service.user` when the repository should be evaluated as a
specific account. That account must be able to read the repository.

The repository settings can enable real builds for timer-driven checks. Those
builds retain the service limits and request at most one Nix build job using one
build core. This matters because Nix daemon workers do not inherit the caller's
systemd cgroup directly. Background builds can run for a long time and consume
additional Nix store space; enabling garbage collection is recommended.

Useful service commands:

```console
systemctl status nixos-update-checker.timer
sudo systemctl start nixos-update-checker.service
journalctl -u nixos-update-checker.service
```

## Run directly from the flake

Open the GUI for `/etc/nixos`:

```console
nix run github:Onred/nixos-update-checker
```

This standalone command performs both fast manifest checks and real candidate
builds without importing the update checker's NixOS module. The module is only
needed to install the application and configure its tray and background service.

Open another checkout of the current system's repository:

```console
nix run github:Onred/nixos-update-checker -- /path/to/config
```

The tray app can be launched without opening its window:

```console
nixos-update-checker --background
```

## Terminal backend

The backend remains available for automation and diagnostics:

```console
check-nixos-updates /path/to/config
check-nixos-updates --json /path/to/config
check-nixos-updates --json --build /path/to/config
check-nixos-updates --debug /path/to/config
nix run github:Onred/nixos-update-checker#cli -- --source-only /path/to/config
```

`--json` reserves stdout for a schema-versioned report and writes diagnostics
to stderr. The backend uses a transient user systemd scope by default with the
same low-impact scheduling policy. `--no-limit` is intended for the enclosing
NixOS service, which supplies its own resource controls.

`--build` realizes the candidate system and changes the package report source
from `evaluatedManifestAgainstRunningClosure` to `realizedClosure`. The JSON
report includes the candidate system path, closure sizes, size delta, and
added/removed store-path counts. The GUI's two check buttons always pass
`--no-limit`, so deliberate foreground checks and builds are not CPU throttled.
Only automatic background work uses the low-impact policy.

The GUI gives directly configured and important option-backed packages the
primary table. Flake inputs, transitive runtime dependencies, and package
entries whose version is unchanged but whose Nix store path changed are placed
in separate collapsed sections. Store-only entries do not contribute to update
totals or notifications; input and dependency changes still indicate that an
update is available.

The GUI uses the official PySide6 Qt bindings. The CLI, service publisher, and
shared comparison logic are typed Python. The service invokes the same checker
with `--service --report FILE`; there is no shell backend or separate service
runner.

The package evaluator is bundled with the application. It reads `config` and
`options` from the selected `nixosConfigurations` result, so the checked system
does not need to define any update-checker-specific options.

### Package discovery and additional options

The manifest automatically compares:

- system and user package lists;
- systemd and the active kernel as core NixOS components;
- package-valued and `listOf package` options beneath enabled NixOS modules.

The fast check also promotes enabled-module package options and package options
under `hardware.*` when their package identity is present in the running
closure. After a real build, the stronger rule is used: the option's exact
output path must be in the candidate closure. This automatically recognizes
choices such as `hardware.nvidia.package` without maintaining hardware-specific
package names. Package-valued passthru components are inspected as well, so a
realized `hardware.nvidia.package.open` derivation appears as `nvidia-open`
alongside `nvidia-x11`. Non-package passthru metadata is ignored, as are
unrelated disabled service defaults.

There is no built-in NVIDIA, QEMU, Mesa, `kvmfr`, or other hardware-specific
list. If the automatic rules cannot infer that an option is important, open
**Actions → Settings…** and enter its NixOS option path. The GUI stores these
overrides and background policy in the shared, repository-local
`.nixos-update-checker.json` file:

```json
{
  "schemaVersion": 1,
  "packageOptions": [
    "hardware.nvidia.package"
  ],
  "backgroundBuild": false,
  "garbageCollection": {
    "enabled": false,
    "olderThanDays": 30
  }
}
```

Both interactive checks and the background system service read this file. If
the repository is not writable by the desktop user, the GUI requests Polkit
authorization before installing the settings file.

Garbage collection is opt-in and defaults to retaining 30 days. It runs only
after **Rebuild system** has completed successfully—never after a check, a
candidate build, or merely updating `flake.lock`. It uses
`nix-collect-garbage --delete-older-than 30d`, so generations older than the
configured retention period and subsequently unreferenced paths can no longer
be used for rollback.

## Development environment

All development dependencies live in the Nix store; they do not need to be
installed into `environment.systemPackages`. Enter the flake development shell
and run the tests:

```console
nix develop
pytest
ruff check .
mypy src
```

To confirm that `nix run` is using the package from the current checkout, compare
its embedded flake revision with Git:

```console
git rev-parse --short HEAD
nix run path:. -- --version
```

The GUI shows the same revision under **Help → About**, and backend reports
include it as `buildRevision`. A dirty checkout is labeled with a content
fingerprint instead of a commit revision.

The pytest suite contains data-driven cases for single and multiple
`nixosConfigurations`, output names that differ from hostnames, missing
hostnames, unique matches, no matches, duplicate matches, store-path parsing,
settings compatibility, closure comparison, atomic report publication, and the
CLI JSON/build contract. `nix flake check` additionally evaluates a manifest
from a NixOS configuration that does not import this application's module,
including enabled, disabled, package-valued, list-of-package, graphics, and
manual-option cases. The shell supplies Python, PySide6, pytest, mypy, Ruff, Nix,
`nixd`, systemd tools, and the formatter.

### Automatic VS Code environment

The repository includes `.envrc`, extension recommendations, and workspace
settings. Install `direnv` with `nix-direnv` support, run `direnv allow` once in
this folder, and accept the recommended `mkhl.direnv`, Python, Pylance, Ruff,
and Nix IDE extensions.

After that, open the folder normally with `code .` or its desktop entry. The
direnv extension loads the flake environment into VS Code automatically. The
development shell creates stable `.venv` and `.nixd` symlinks to its
Nix-provided Python/PySide6 environment and Nix language server, and VS Code is
already configured to use both paths. Integrated terminals remain normal shell
terminals and inherit the loaded project environment; no custom terminal
profile or automatic task is required.

If direnv is not configured yet, the immediate no-setup fallback is:

```console
nix develop -c code .
```

## Safety notes

- Normal checks never write the repository's `flake.lock`.
- **Update inputs** deliberately runs `nix flake update` and writes `flake.lock`;
  it requests administrator authorization for a non-writable repository.
- **Rebuild system** uses `pkexec` to request authorization, then runs
  `nixos-rebuild switch --flake REPOSITORY#DISCOVERED-CONFIGURATION`.
- Optional garbage collection runs only after that rebuild succeeds and retains
  generations newer than the configured age (30 days by default).
- Candidate evaluation and explicit rebuilds may download paths through the Nix
  daemon. Background real builds therefore combine the service cgroup policy
  with one Nix job and one requested build core.
