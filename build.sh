#!/bin/sh
# Build k4: the C dependencies (stb, kb_text_shape) as static libs, then the Odin program.
#   ./build.sh            release build to ./k4
#   ./build.sh debug      debug build
#   ./build.sh install    release build, copy to ~/.local/bin/k4
#   ./build.sh test       run the unit tests
set -e
cd "$(dirname "$0")"
cc=${CC:-cc}; ar=${AR:-ar}
mkdir -p lib vendor/kb_text_shape/lib
if [ ! -f lib/k4c.a ] || [ csrc/k4c.c -nt lib/k4c.a ]; then
  $cc -O2 -fPIC -w -c csrc/k4c.c -o lib/k4c.o && $ar -rcs lib/k4c.a lib/k4c.o && rm lib/k4c.o
fi
if [ ! -f vendor/kb_text_shape/lib/kb_text_shape.a ]; then
  (cd vendor/kb_text_shape/src && $cc -O2 -fPIC -w -c kb_text_shape.c -o ../lib/kb_text_shape.o \
     && $ar -rcs ../lib/kb_text_shape.a ../lib/kb_text_shape.o && rm ../lib/kb_text_shape.o)
fi
case "${1:-}" in
  debug)   odin build src -out:k4 -debug -collection:vendor_k4=vendor ;;
  test)    odin test tests -collection:vendor_k4=vendor -define:ODIN_TEST_LOG_LEVEL=warning ;;
  install) odin build src -out:k4 -o:speed -collection:vendor_k4=vendor && install -Dm755 k4 "$HOME/.local/bin/k4" ;;
  *)       odin build src -out:k4 -o:speed -collection:vendor_k4=vendor ;;
esac
