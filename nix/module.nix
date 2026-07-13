{ config, lib, options, pkgs, ... }:

let
  cfg = config.programs.nixos-update-checker;

  packageManifest = { config, options }:
    let
      package = packageValue: {
        name = packageValue.name;
        pname = packageValue.pname or null;
        version = packageValue.version or null;
        path = packageValue.outPath;
      };

      packageList = packages: map package packages;

      filterAttrs = predicate: attrs:
        builtins.listToAttrs (
          builtins.concatMap
            (name:
              if predicate name attrs.${name} then
                [ { inherit name; value = attrs.${name}; } ]
              else
                [ ])
            (builtins.attrNames attrs)
        );

      getAttrFromPath = default: path: attrs:
        if path == [ ] then
          attrs
        else if !builtins.isAttrs attrs || !builtins.hasAttr (builtins.head path) attrs then
          default
        else
          getAttrFromPath default (builtins.tail path) attrs.${builtins.head path};

      take = count: values:
        if count == 0 || values == [ ] then
          [ ]
        else
          [ (builtins.head values) ] ++ take (count - 1) (builtins.tail values);

      collectPackageOptions = path: attrs:
        builtins.concatMap
          (name:
            let
              value = attrs.${name};
              optionPath = path ++ [ name ];
            in
            if builtins.isAttrs value && (value._type or null) == "option" then
              if value.type.name == "package" then [ optionPath ] else [ ]
            else if builtins.isAttrs value then
              collectPackageOptions optionPath value
            else
              [ ])
          (builtins.attrNames attrs);

      ancestorPaths = optionPath:
        let
          parentLength = builtins.length optionPath - 1;
        in
        builtins.genList
          (index: take (index + 1) optionPath)
          parentLength;

      pathIsEnabled = optionPath:
        let
          hasCurrentEnableOption = ancestorPath:
            let
              enableOption = getAttrFromPath null (ancestorPath ++ [ "enable" ]) options;
            in
            builtins.isAttrs enableOption
            && (enableOption._type or null) == "option"
            && (enableOption.visible or true);

          enableScopes = builtins.filter hasCurrentEnableOption (ancestorPaths optionPath);

          scopeIsEnabled = ancestorPath:
            let
              result = builtins.tryEval (
                getAttrFromPath false (ancestorPath ++ [ "enable" ]) config == true
              );
            in
            result.success && result.value;
        in
        enableScopes != [ ] && builtins.all scopeIsEnabled enableScopes;

      packageFromOption = optionPath:
        let
          packageValue = package (getAttrFromPath null optionPath config);
          result = builtins.tryEval (builtins.deepSeq packageValue packageValue);
        in
        if result.success then
          result.value // { option = builtins.concatStringsSep "." optionPath; }
        else
          null;

      activeOptionPackages = builtins.filter (value: value != null) (
        map packageFromOption (
          builtins.filter pathIsEnabled (collectPackageOptions [ ] options)
        )
      );

      maybePackage = packageValue:
        let
          value = package packageValue;
          result = builtins.tryEval (builtins.deepSeq value value);
        in
        if result.success then result.value else null;
    in
    {
      toplevelDeriver = config.system.build.toplevel.drvPath;

      userPackages = builtins.mapAttrs (_: user: packageList (user.packages or [ ])) (
        filterAttrs (_: user: (user.packages or [ ]) != [ ]) config.users.users
      );

      systemPackages = packageList config.environment.systemPackages;

      inherit activeOptionPackages;

      manual = {
        systemd = maybePackage config.systemd.package;
        kernel = maybePackage config.boot.kernelPackages.kernel;
        nvidia = maybePackage config.hardware.nvidia.package;
        qemu = maybePackage config.virtualisation.libvirtd.qemu.package;
        kvmfr = maybePackage config.boot.kernelPackages.kvmfr;
      };
    };

in
{
  options.programs.nixos-update-checker = {
    enable = lib.mkEnableOption "the NixOS flake update checker";

    host = lib.mkOption {
      type = lib.types.str;
      default = "nixos";
      description = "Flake nixosConfigurations attribute checked by default.";
    };

    cpuQuota = lib.mkOption {
      type = lib.types.strMatching "[1-9][0-9]*%";
      default = "25%";
      description = "Default transient systemd scope CPU quota.";
    };

    package = lib.mkOption {
      type = lib.types.package;
      default = import ./package.nix {
        inherit pkgs;
        defaultHost = cfg.host;
        defaultCpuQuota = cfg.cpuQuota;
      };
      description = "Packaged update-checker command.";
    };

    manifest = lib.mkOption {
      type = lib.types.raw;
      readOnly = true;
      internal = true;
      description = "Evaluated package manifest consumed by the checker.";
    };
  };

  config = lib.mkMerge [
    {
      programs.nixos-update-checker.manifest = packageManifest {
        inherit config options;
      };
    }

    (lib.mkIf cfg.enable {
      environment.systemPackages = [ cfg.package ];
    })
  ];
}
