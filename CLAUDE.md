# alpine-tcl

This repo builds two kinds of release from the same Dockerfile:

- **cftcl** (Tcl 9 runtime apks, `v0.10.x`): built and published to
  cftcl.cyanogilvie.com by the cftcl-release CodeBuild pipeline. A pushed tag
  matching `^refs/tags/v.+` triggers it, and the apk version comes from the tag.
- **Legacy alpine-tcl images** (Tcl 8.7b1 + Thread 2.9b1, `v0.9.x`): Docker Hub
  images built locally with `make alpine-tcl`. `LEGACY_TCLVER` (default 8.7)
  selects the Tcl branch, and `VER` in the Makefile sets the image tag.

## Tagging legacy releases

The legacy image build doesn't use the git tag. A tag only marks the commit
that built the published image. **Don't tag legacy releases `v0.9.N`**: the
push would trigger the cftcl release pipeline and build a cftcl apk versioned
`0.9.N` (this happened with `v0.9.123`). Tag them `legacy-v0.9.N` instead, which
the trigger doesn't match.

## Building legacy images

`make alpine-tcl` defaults to `DEST=--push`, so it builds both platforms and
publishes `cyanogilvie/alpine-tcl:$(VER)-stripped` and `:latest` to Docker Hub.
When testing changes, build locally instead:

    make alpine-tcl DEST=--load PLATFORM=linux/amd64 VER=<ver>-test

`make upload` is obsolete.
