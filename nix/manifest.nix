{ config, options }:

let
  package = packageValue: {
    name = packageValue.name;
    pname = packageValue.pname or null;
    version = packageValue.version or null;
    path = packageValue.outPath;
  };

  packageList = packages: map package packages;

  filterAttrs =
    predicate: attrs:
    builtins.listToAttrs (
      builtins.concatMap (
        name:
        if predicate name attrs.${name} then
          [
            {
              inherit name;
              value = attrs.${name};
            }
          ]
        else
          [ ]
      ) (builtins.attrNames attrs)
    );

  getAttrFromPath =
    default: path: attrs:
    if path == [ ] then
      attrs
    else if !builtins.isAttrs attrs || !builtins.hasAttr (builtins.head path) attrs then
      default
    else
      getAttrFromPath default (builtins.tail path) attrs.${builtins.head path};

  take =
    count: values:
    if count == 0 || values == [ ] then
      [ ]
    else
      [ (builtins.head values) ] ++ take (count - 1) (builtins.tail values);

  collectPackageOptions =
    path: attrs:
    builtins.concatMap (
      name:
      let
        value = attrs.${name};
        optionPath = path ++ [ name ];
      in
      if builtins.isAttrs value && (value._type or null) == "option" then
        if (value.visible or true) == false then
          [ ]
        else if value.type.name == "package" then
          [
            {
              path = optionPath;
              list = false;
            }
          ]
        else if
          value.type.name == "listOf" && (value.type.nestedTypes.elemType.name or null) == "package"
        then
          [
            {
              path = optionPath;
              list = true;
            }
          ]
        else
          [ ]
      else if builtins.isAttrs value then
        collectPackageOptions optionPath value
      else
        [ ]
    ) (builtins.attrNames attrs);

  ancestorPaths =
    optionPath:
    let
      parentLength = builtins.length optionPath - 1;
    in
    builtins.genList (index: take (index + 1) optionPath) parentLength;

  pathIsEnabled =
    optionPath:
    let
      hasCurrentEnableOption =
        ancestorPath:
        let
          enableOption = getAttrFromPath null (ancestorPath ++ [ "enable" ]) options;
        in
        builtins.isAttrs enableOption
        && (enableOption._type or null) == "option"
        && (enableOption.visible or true);

      enableScopes = builtins.filter hasCurrentEnableOption (ancestorPaths optionPath);

      scopeIsEnabled =
        ancestorPath:
        let
          result = builtins.tryEval (getAttrFromPath false (ancestorPath ++ [ "enable" ]) config == true);
        in
        result.success && result.value;
    in
    enableScopes != [ ] && builtins.all scopeIsEnabled enableScopes;

  packagesFromOption =
    optionInfo:
    let
      optionName = builtins.concatStringsSep "." optionInfo.path;
      optionValue = getAttrFromPath null optionInfo.path config;
      packageValues =
        if optionInfo.list then
          if builtins.isList optionValue then optionValue else [ ]
        else
          [ optionValue ];
      values = map (packageValue: package packageValue // { option = optionName; }) packageValues;
      result = builtins.tryEval (
        builtins.fromJSON (builtins.unsafeDiscardStringContext (builtins.toJSON values))
      );
    in
    if result.success && builtins.isList result.value then result.value else [ ];

  packageOptions = collectPackageOptions [ ] options;

  activeOptionPackages = builtins.concatMap packagesFromOption (
    builtins.filter (optionInfo: pathIsEnabled optionInfo.path) packageOptions
  );
in
{
  toplevelDeriver = config.system.build.toplevel.drvPath;

  userPackages = builtins.mapAttrs (_: user: packageList (user.packages or [ ])) (
    filterAttrs (_: user: (user.packages or [ ]) != [ ]) config.users.users
  );

  systemPackages = packageList config.environment.systemPackages;

  corePackages = packageList [
    config.systemd.package
    config.boot.kernelPackages.kernel
  ];

  inherit activeOptionPackages;
}
