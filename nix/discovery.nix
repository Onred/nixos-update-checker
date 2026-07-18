system:

let
  inherit (system) config options pkgs;
  inherit (pkgs) lib;

  isPackage = value: lib.isDerivation value || (builtins.isAttrs value && value ? outPath);

  packageInfo =
    source: label: value:
    let
      attempted = builtins.tryEval value;
    in
    if !attempted.success || !isPackage attempted.value then
      [ ]
    else
      let
        package = attempted.value;
        packageName = package.name or (baseNameOf (toString package.outPath));
        parsed = builtins.parseDrvName packageName;
      in
      [
        {
          inherit label source;
          name = package.pname or parsed.name;
          version = toString (package.version or parsed.version);
          storePath = toString package.outPath;
          drvPath = toString (package.drvPath or "");
          position = toString (package.meta.position or "");
        }
      ];

  flattenPackages =
    source: label: value:
    let
      attempted = builtins.tryEval value;
    in
    if !attempted.success then
      [ ]
    else if isPackage attempted.value then
      packageInfo source label attempted.value
    else if builtins.isList attempted.value then
      lib.concatLists (
        lib.imap0 (
          index: item: flattenPackages source "${label} ${toString (index + 1)}" item
        ) attempted.value
      )
    else if builtins.isAttrs attempted.value then
      lib.concatLists (lib.mapAttrsToList (name: item: flattenPackages source name item) attempted.value)
    else
      [ ];

  containsPackageType =
    depth: type:
    depth < 5
    && builtins.isAttrs type
    && (
      (type.name or "") == "package"
      || builtins.any (containsPackageType (depth + 1)) (builtins.attrValues (type.nestedTypes or { }))
    );

  isOption = value: builtins.isAttrs value && (value._type or null) == "option";

  walkPackageOptions =
    path: optionNode: configNode: enabled: hasEnable:
    lib.concatLists (
      map (
        name:
        let
          optionValue = optionNode.${name};
          optionVisible = !isOption optionValue || (optionValue.visible or true) == true;
          configValue = builtins.tryEval (
            if builtins.isAttrs configNode && builtins.hasAttr name configNode then configNode.${name} else null
          );
          nextConfig = if configValue.success then configValue.value else null;
          enableOption = if builtins.isAttrs optionValue then optionValue.enable or null else null;
          enableVisible = isOption enableOption && (enableOption.visible or true) == true;
          enableValue = builtins.tryEval (
            if enableVisible && builtins.isAttrs nextConfig && nextConfig ? enable then
              nextConfig.enable
            else
              null
          );
          localEnable = enableValue.success && builtins.isBool enableValue.value;
          nextEnabled = enabled && (!localEnable || enableValue.value);
          nextHasEnable = hasEnable || localEnable;
          optionPath = path ++ [ name ];
          optionName = lib.concatStringsSep "." optionPath;
        in
        if isOption optionValue then
          if
            enabled
            && hasEnable
            && optionVisible
            && configValue.success
            && containsPackageType 0 optionValue.type
          then
            flattenPackages "option:${optionName}" optionName nextConfig
          else
            [ ]
        else if builtins.isAttrs optionValue && builtins.isAttrs nextConfig then
          walkPackageOptions optionPath optionValue nextConfig nextEnabled nextHasEnable
        else
          [ ]
      ) (builtins.attrNames optionNode)
    );

  environmentPackages =
    flattenPackages "environment.systemPackages" "System package"
      config.environment.systemPackages;
  fontPackages = flattenPackages "fonts.packages" "Font" config.fonts.packages;
  userPackages = lib.concatLists (
    lib.mapAttrsToList (
      name: user: flattenPackages "users.users.${name}.packages" name (user.packages or [ ])
    ) config.users.users
  );
  servicePathPackages = lib.concatLists (
    lib.mapAttrsToList (
      name: service: flattenPackages "systemd.services.${name}.path" name (service.path or [ ])
    ) config.systemd.services
  );
  extraPackages = lib.concatLists (
    lib.mapAttrsToList (name: package: flattenPackages "extraPackages.${name}" name package) (
      config.programs.nixos-update-checker.extraPackages or { }
    )
  );
  corePackages =
    packageInfo "core:kernel" "Linux kernel" config.boot.kernelPackages.kernel
    ++ packageInfo "core:nix" "Nix" config.nix.package
    ++ packageInfo "core:systemd" "systemd" config.systemd.package
    ++
      lib.optionals
        (builtins.any (driver: lib.hasPrefix "nvidia" driver) config.services.xserver.videoDrivers)
        (packageInfo "core:nvidia" "NVIDIA driver" config.hardware.nvidia.package)
    ++ lib.optionals config.services.ollama.enable (
      packageInfo "core:ollama" "Ollama" config.services.ollama.package
    );
in
{
  system = {
    drvPath = toString config.system.build.toplevel.drvPath;
    storePath = toString config.system.build.toplevel.outPath;
  };
  packages =
    corePackages
    ++ environmentPackages
    ++ fontPackages
    ++ userPackages
    ++ servicePathPackages
    ++ extraPackages
    ++ walkPackageOptions [ ] options config true false;
}
