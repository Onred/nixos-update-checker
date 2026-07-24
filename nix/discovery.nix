system:

let
  inherit (system) config options pkgs;
  inherit (pkgs) lib;

  isPackage = value: lib.isDerivation value || (builtins.isAttrs value && value ? outPath);

  packageInfo =
    source: label: value:
    let
      attempted = builtins.tryEval (
        let
          package = value;
        in
        if !isPackage package then
          [ ]
        else
          let
            packageName = package.name or (baseNameOf (toString package.outPath));
            parsed = builtins.parseDrvName packageName;
            info = {
              inherit label source;
              name = package.pname or parsed.name;
              version = toString (package.version or parsed.version);
              storePath = toString package.outPath;
              drvPath = toString (package.drvPath or "");
              position = toString (package.meta.position or "");
            };
          in
          builtins.deepSeq info [ info ]
      );
    in
    if attempted.success then attempted.value else [ ];

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

  # Options outside an activation subtree are weak hints. Limit those to one
  # package so negative or control lists such as excludePackages stay excluded.
  isSingularPackageType =
    depth: type:
    depth < 5
    && builtins.isAttrs type
    && (
      (type.name or "") == "package"
      || (
        lib.hasPrefix "null or " (type.name or "")
        && builtins.any (isSingularPackageType (depth + 1)) (builtins.attrValues (type.nestedTypes or { }))
      )
    );

  isOption = value: builtins.isAttrs value && (value._type or null) == "option";

  boolOption =
    option: value:
    builtins.tryEval (
      if isOption option && (option.visible or true) == true && builtins.isBool value then value else null
    );

  walkPackageOptions =
    path: optionNode: configNode: enabled: hasActivation:
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
          enabledOption = if builtins.isAttrs optionValue then optionValue.enabled or null else null;
          enableValue = boolOption enableOption (
            if builtins.isAttrs nextConfig && nextConfig ? enable then nextConfig.enable else null
          );
          enabledValue = boolOption enabledOption (
            if
              isOption enabledOption
              && (enabledOption.readOnly or false)
              && builtins.isAttrs nextConfig
              && nextConfig ? enabled
            then
              nextConfig.enabled
            else
              null
          );
          hasEnable = enableValue.success && enableValue.value != null;
          hasEnabled = enabledValue.success && enabledValue.value != null;
          localActivation = hasEnable || hasEnabled;
          localEnabled =
            if hasEnable then
              enableValue.value
            else if hasEnabled then
              enabledValue.value
            else
              true;
          nextEnabled = enabled && (!localActivation || localEnabled);
          nextHasActivation = hasActivation || localActivation;
          optionPath = path ++ [ name ];
          optionName = lib.concatStringsSep "." optionPath;
        in
        if isOption optionValue then
          if
            enabled
            && optionVisible
            && configValue.success
            && containsPackageType 0 optionValue.type
            # Activated modules retain support for package collections. A
            # singular unscoped option can later be proven by baseline closure.
            && (hasActivation || isSingularPackageType 0 optionValue.type)
          then
            flattenPackages "option:${optionName}" optionName nextConfig
          else
            [ ]
        else if builtins.isAttrs optionValue && builtins.isAttrs nextConfig then
          walkPackageOptions optionPath optionValue nextConfig nextEnabled nextHasActivation
        else
          [ ]
      ) (builtins.attrNames optionNode)
    );

  environmentPackages =
    flattenPackages "environment.systemPackages" "System package"
      config.environment.systemPackages;
  fontPackages = flattenPackages "fonts.packages" "Font" config.fonts.packages;
  kernelModulePackages =
    flattenPackages "boot.extraModulePackages" "Kernel module"
      config.boot.extraModulePackages;
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
    ++ kernelModulePackages
    ++ userPackages
    ++ servicePathPackages
    ++ extraPackages
    ++ walkPackageOptions [ ] options config true false;
}
