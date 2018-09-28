{
  nixpkgs ? import ./pinnedNixpkgs.nix,
  pkgs ? import nixpkgs {}
}:
let
  serverPackage = pkgs.callPackage ./server {};
  clientPackage = pkgs.callPackage ./python_client {};
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
  mdbServerWithoutPython = serverPackage.override { libpqxx = libpqxxWithoutPython; };

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

  staticServer = selectedStdenv: (serverPackage.override {
    static = true;
    stdenv = pkgs.makeStaticLibraries selectedStdenv;
    libpqxx = staticPqxx selectedStdenv;
  }).overrideAttrs (o: {
    buildInputs = o.buildInputs ++ [staticPostgresql staticOpenssl pkgs.glibc.static];
  });

in rec {
  mdb-server = serverPackage;
  mdb-server-static = staticServer pkgs.stdenv;

  mdb-server-clang  = serverPackage.override { stdenv = pkgs.clangStdenv; };
  mdb-server-clang-static = staticServer pkgs.clangStdenv;

  mdb-webservice = clientPackage;

  mdb-server-docker = makeDockerImage "mdb-server" "${mdbServerWithoutPython}/bin/messagedb-server";
  mdb-webservice-docker = makeDockerImage "mdb-webservice" "${mdb-webservice}/bin/webserver";

  integration-test = import ./integration_test.nix {
    inherit nixpkgs;
    mdbServer = mdb-server;
    mdbWebservice = mdb-webservice;
  };
}
