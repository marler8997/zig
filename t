#!/usr/bin/env sh
set -eu
set -x
if [ ! -e llvm19 ]; then
    git clone --depth 1 --branch release/19.x https://github.com/llvm/llvm-project llvm19
fi

if [ ! -e llvm19/build/build.ninja ]; then
    cmake -S llvm19/llvm -B llvm19/build -GNinja -DLLVM_ENABLE_PROJECTS=lld -DCMAKE_BUILD_TYPE=Debug
fi

zig=./stage4/bin/zig

# not sure what this is doing
# ninja -Cllvm19/build lld-test-depends

# run coff tests?
# ninja -Cllvm19/build check-lld-coff

rm -rf out
mkdir -p out

zig 0.14.0-dev.3028+cdc9d65b0 build --build-file buildtools.zig
zig 0.14.0-dev.3028+cdc9d65b0 lib /machine:x64 /def:./lib/libc/mingw/lib64/kernel32.def /out:out/kernel32.lib

zig 0.14.0-dev.3028+cdc9d65b0 build-obj -femit-bin=out/simpleconsole.obj -target x86_64-windows-gnu -O ReleaseSmall coff/simpleconsole.zig
rm out/simpleconsole.obj.obj
./zig-out/bin/coffdump out/simpleconsole.obj > out/simpleconsole.obj.dump
zig 0.14.0-dev.3028+cdc9d65b0 lld-link /out:out/simpleconsole-lld.exe /subsystem:console out/simpleconsole.obj
./zig-out/bin/coffdump out/simpleconsole-lld.exe > out/simpleconsole-lld.exe.dump
$zig msvc-link /out:out/simpleconsole-zig.exe /subsystem:console out/simpleconsole.obj
./zig-out/bin/coffdump out/simpleconsole-zig.exe > out/simpleconsole-zig.exe.dump
exec meld out/simpleconsole-lld.exe.dump out/simpleconsole-zig.exe.dump


zig 0.14.0-dev.3028+cdc9d65b0 build-obj -target x86_64-windows-gnu -O ReleaseSmall coff/simplewindows.zig
./zig-out/bin/coffdump simplewindows.obj
zig 0.14.0-dev.3028+cdc9d65b0 lld-link /out:simple-lld.exe /subsystem:windows simplewindows.obj
./zig-out/bin/coffdump simple-lld.exe > simple-lld.exe.dump
$zig msvc-link /out:simple-zig.exe /subsystem:windows simplewindows.obj
./zig-out/bin/coffdump simple-zig.exe > simple-zig.exe.dump
exec meld simplewindows.exe.lld-linked.dump simplewindows.exe.zig-linked.dump

echo here
exit
#zig 0.14.0-dev.3028+cdc9d65b0 build-obj -target x86_64-windows-gnu -O ReleaseSmall coff/hello.zig
#zig 0.14.0-dev.3028+cdc9d65b0 lld-link /subsystem:windows hello.obj kernel32.lib
# ./zig-out/bin/coffdump hello.exe > hello.exe.lld-linked.dump

# $zig msvc-link /subsystem:windows hello.obj kernel32.lib
# ./zig-out/bin/coffdump hello.exe > hello.exe.zig-linked.dump

# exec meld hello.exe.lld-linked.dump hello.exe.zig-linked.dump



#LLVM_LIT_OVERRIDE_lld_link=/home/marler8997/git/zig/my-lld-bin/lld-link ./llvm-lit llvm19/lld/test/COFF/gfids-relocations64.s

#./llvm-lit llvm19/lld/test/COFF/basic.c
#./llvm-lit llvm19/lld/test/COFF/baserel.test
#./llvm-lit llvm19/compiler-rt/test/asan/TestCases/Windows/unsymbolized.cpp
LLVM_LIT_OVERRIDE_lld_link=/home/marler8997/git/zig/my-lld-bin/lld-link ./llvm-lit llvm19/lld/test/COFF/export-exe.test
