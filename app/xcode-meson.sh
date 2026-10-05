#!/bin/bash

# Try to figure out the user's PATH to pick up their installed utilities.
# Do not use sudo here: personal Apple developer machines are not always
# configured with sudo for the GUI user, and the build only needs PATH hints.
login_path=$(env -i HOME="$HOME" USER="$USER" SHELL="${SHELL:-/bin/zsh}" /bin/zsh -lc 'print -r -- $PATH' 2>/dev/null || true)
if [[ -n "$login_path" ]]; then
    export PATH="$PATH:$login_path"
fi

terax_tools=/Users/rcarmo/Build/terax
terax_lld=$terax_tools/.tmp-lld-bottle/lld/22.1.5
terax_llvm=$terax_tools/.tmp-llvm-bottle/llvm/22.1.5
terax_z3=$terax_tools/.tmp-homebrew/Cellar/z3/4.15.4
terax_zstd=$terax_tools/.tmp-homebrew/Cellar/zstd/1.5.7_1
terax_lz4=$terax_tools/.tmp-homebrew/Cellar/lz4/1.10.0
if [[ -x "$terax_lld/bin/ld.lld" && -d "$terax_llvm/lib" ]]; then
    export PATH="$terax_lld/bin:$PATH"
    export DYLD_LIBRARY_PATH="$terax_lld/lib:$terax_llvm/lib:$terax_z3/lib:$terax_zstd/lib:$terax_lz4/lib${DYLD_LIBRARY_PATH:+:$DYLD_LIBRARY_PATH}"
fi

mkdir -p "$MESON_BUILD_DIR"
cd "$MESON_BUILD_DIR"

# JIT toggle: ISH_ENABLE_JIT=1 (set by CI) enables the experimental native
# ARM64 backend. On iOS it uses the dual-mapping code region (vm_remap RW +
# RX views, no MAP_JIT, no special entitlements); fault recovery
# (platform/native_fault.c) is compiled into libish unconditionally. Change
# jit and jit_emit together; cli_aot must stay empty for runtime JIT (a
# stale cli_aot fails Meson's dependency check before a later option update
# could clear the images).
jit_args="-Djit=false -Djit_emit=false -Dcli_aot="
if [[ -n "$ISH_ENABLE_JIT" ]]; then
    jit_args="-Djit=true -Djit_emit=true -Dcli_aot="
fi

config=$(meson introspect --buildoptions)
if [[ $? -ne 0 ]]; then
    export CC_FOR_BUILD="env -u SDKROOT -u IPHONEOS_DEPLOYMENT_TARGET xcrun clang"
    export CC="$CC_FOR_BUILD" # compatibility with meson < 0.54.0
    crossfile=cross.txt
    for arch in $ARCHS; do
        arch_args="'-arch', '$arch', $arch_args"
    done
    arch_args="${arch_args%%, }"
    meson_arch=${ARCHS%% *}
    case "$meson_arch" in
        arm64) meson_arch=aarch64 ;;
    esac
    cat | tee $crossfile <<-EOF
    [binaries]
    c = 'clang'
    ar = 'ar'

    [host_machine]
    system = 'darwin'
    cpu_family = '$meson_arch'
    cpu = '$meson_arch'
    endian = 'little'

    [built-in options]
    c_args = [$arch_args]
    
    [properties]
    needs_exe_wrapper = true
EOF
    guest_arch_opt=""
    if [[ -n "$GUEST_ARCH" ]]; then
        guest_arch_opt="-Dguest_arch=$GUEST_ARCH"
    fi
    (set -x; meson "$SRCROOT" --cross-file "$crossfile" $guest_arch_opt $jit_args) || exit $?
    config=$(meson introspect --buildoptions)
fi

buildtype=debug
b_ndebug=false
# Release-equivalent device builds MUST NOT fall back to an unoptimized core.
# The custom configuration name (Xcode FB19282108 workaround) does not contain
# the substring "Release", so it used to silently get Meson's debug buildtype
# (-O0), making the emulator core several times slower than it should be.
case "$CONFIGURATION" in
    Release|*Release*|*ApplePleaseFix*)
        buildtype=release   # -O3, no debug info
        b_ndebug=true       # compile assert() out of the interpreter hot loop
        ;;
esac
b_sanitize=none
if [[ -n "$ENABLE_ADDRESS_SANITIZER" ]]; then
    b_sanitize=address
fi
log=$ISH_LOG
log_handler=$ISH_LOGGER
kernel=ish
if [[ -n "$ISH_KERNEL" ]]; then
    kernel=$ISH_KERNEL
fi
kconfig=""
guest_arch=${GUEST_ARCH:-arm64}
# Never inherit a recorder/AOT configuration from a reused build directory.
(set -x; meson configure $jit_args) || exit $?
for var in buildtype log b_ndebug b_sanitize log_handler kernel kconfig guest_arch; do
    old_value=$(python3 -c "import sys, json; v = next(x['value'] for x in json.load(sys.stdin) if x['name'] == '$var'); print(str(v).lower() if isinstance(v, bool) else ','.join(v) if isinstance(v, list) else v)" <<< $config)
    new_value=${!var}
    if [[ $old_value != $new_value ]]; then
        set -x; meson configure "-D$var=$new_value" || exit $?
    fi
done
