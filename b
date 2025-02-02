#!/usr/bin/env sh
set -ex
#exec ninja -Cbuild
# NOTE: -Duse-llvm=false breaks the cache, but it copmiles like 3x faster
time ./build/stage3/bin/zig build -p stage4 -Dno-lib -Denable-llvm=false -Duse-llvm=false -Ddev=msvc_link

exec ./t

#zig=./build/stage3/bin/zig
zig=./stage4/bin/zig


# TODO disable test-macho linker tests
# optimize?
# -Dtarget=x86_64-windows-gnu  ??
# -Dofmt=coff  ??
# -Denable-llvm=false  ??
# -Duse-llvm=false ??
$zig build --build-file test/link/build.zig coff --help

#rm -f main.exe
#$zig build-exe --verbose-link -target x86_64-windows coff/main.zig && wine64 ./main.exe
#$zig build-exe --verbose-link -Dlog --debug-log link -target x86_64-windows -fno-llvm coff/main.zig && wine64 ./main.exe

#./build/stage3/bin/zig build test-link
