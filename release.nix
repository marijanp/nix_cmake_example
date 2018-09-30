{
  nixpkgs ? import ./pinnedNixpkgs.nix
}:
let
  pkgs = import nixpkgs {
    overlays = [ (import ./server/overlay.nix) (import ./python_client/overlay.nix) ];
  };

  makeDockerImage = name: entrypoint: pkgs.dockerTools.buildImage {
      name = name;
      tag = "latest";
      contents = [ ];
      config = {
        Entrypoint = [ entrypoint ];
      };
    };

  # this is useful because libpqxx with python support depends on python2.7
  # but we don't want python in its closure if we package it into a small
  # docker image!
  libpqxxWithoutPython = pkgs.libpqxx.override {
    postgresql = pkgs.postgresql.override {
      libxml2 = pkgs.libxml2.override { pythonSupport = false; };
    };
  };
  mdbServerWithoutPython = pkgs.mdb-server.override { libpqxx = libpqxxWithoutPython; };

  staticPostgresql = pkgs.postgresql100.overrideAttrs (o: {
      # https://www.postgresql-archive.org/building-libpq-a-static-library-td5970933.html
      postConfigure = o.postConfigure + ''
        echo -e 'libpq.a: $(OBJS)\n\tar rcs $@ $^'   >> ./src/interfaces/libpq/Makefile
      '';
      buildPhase = ''
        make world
        make -C ./src/interfaces/libpq libpq.a
      '';
      postInstall = o.postInstall + ''
        cp src/interfaces/libpq/libpq.a $out/lib/
        cp src/interfaces/libpq/libpq.a $lib/lib/
      '';
    });

  staticPqxx = selectedStdenv: (pkgs.libpqxx.overrideAttrs (o: { configureFlags = []; })).override {
    stdenv = pkgs.makeStaticLibraries selectedStdenv; postgresql = staticPostgresql;
  };
  staticOpenssl = pkgs.openssl.override { static = true; };

  staticServer = selectedStdenv: (pkgs.mdb-server.override {
    static = true;
    stdenv = pkgs.makeStaticLibraries selectedStdenv;
    libpqxx = staticPqxx selectedStdenv;
  }).overrideAttrs (o: {
    buildInputs = o.buildInputs ++ [staticPostgresql staticOpenssl pkgs.glibc.static];
  });

  integrationTest = serverPkg: import ./integration_test.nix {
    inherit nixpkgs;
    mdbServer = serverPkg;
    mdbWebservice = pkgs.mdb-webserver;
  };

  integrationTests = pkgs.lib.mapAttrs'
    (k: v: pkgs.lib.nameValuePair ("integrationtest-" + k) (integrationTest v));

  staticChoice = [true false];
  boostChoice = map (x: { boost = pkgs.${x}; nameStr = x; })
    ["boost163" "boost164" "boost165" "boost166"];
  stdenvChoice = [ { stdenv = pkgs.stdenv;      nameStr = "gcc";}
                   { stdenv = pkgs.clangStdenv; nameStr = "clang";} ];
  cartesianProduct = f: map (a: map (b: map (c: f a b c) stdenvChoice) boostChoice) staticChoice;

  serverFunction = static: boostSel: stdenvSel: let
    nameStr = "mdb-server-" + stdenvSel.nameStr + "-" + boostSel.nameStr + (if static then "-static" else "");
    package = if static then staticServer stdenvSel.stdenv else pkgs.mdb-server;
    package' = package.override { inherit static; inherit (stdenvSel) stdenv; inherit (boostSel) boost; };
    in pkgs.lib.nameValuePair nameStr package';

  joinLists = builtins.foldl' (l: r: l ++ r) [];
  serverBinaries = builtins.listToAttrs (joinLists (joinLists (cartesianProduct serverFunction)));

in rec {
  mdb-webservice = pkgs.mdb-webserver;

  mdb-server-docker = makeDockerImage "mdb-server" "${mdbServerWithoutPython}/bin/messagedb-server";
  mdb-webservice-docker = makeDockerImage "mdb-webservice" "${mdb-webservice}/bin/webserver";

} // serverBinaries
  // (integrationTests serverBinaries)
