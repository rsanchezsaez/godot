import os
import platform
import shutil
import subprocess
import sys

import methods

# NOTE: The multiprocessing module is not compatible with SCons due to conflict on cPickle


compatibility_platform_aliases = {
    "osx": "macos",
    "iphone": "ios",
    "x11": "linuxbsd",
    "javascript": "web",
}

# CPU architecture options.
architectures = ["x86_32", "x86_64", "arm32", "arm64", "rv64", "ppc64", "wasm32", "wasm64", "loongarch64"]
architecture_aliases = {
    "x86": "x86_32",
    "x64": "x86_64",
    "amd64": "x86_64",
    "armv7": "arm32",
    "armv8": "arm64",
    "arm64v8": "arm64",
    "aarch64": "arm64",
    "rv": "rv64",
    "riscv": "rv64",
    "riscv64": "rv64",
    "ppc64le": "ppc64",
    "loong64": "loongarch64",
}


def detect_arch():
    host_machine = platform.machine().lower()
    if host_machine in architectures:
        return host_machine
    elif host_machine in architecture_aliases.keys():
        return architecture_aliases[host_machine]
    elif "86" in host_machine:
        # Catches x86, i386, i486, i586, i686, etc.
        return "x86_32"
    else:
        methods.print_warning(f'Unsupported CPU architecture: "{host_machine}". Falling back to x86_64.')
        return "x86_64"


def validate_arch(arch, platform_name, supported_arches):
    if arch not in supported_arches:
        methods.print_error(
            'Unsupported CPU architecture "%s" for %s. Supported architectures are: %s.'
            % (arch, platform_name, ", ".join(supported_arches))
        )
        sys.exit(255)


def get_build_version(short):
    import version

    name = "custom_build"
    if os.getenv("BUILD_NAME") is not None:
        name = os.getenv("BUILD_NAME")
    v = "%d.%d" % (version.major, version.minor)
    if version.patch > 0:
        v += ".%d" % version.patch
    status = version.status
    if not short:
        if os.getenv("GODOT_VERSION_STATUS") is not None:
            status = str(os.getenv("GODOT_VERSION_STATUS"))
        v += ".%s.%s" % (status, name)
    return v


def lipo(prefix, suffix):
    from pathlib import Path

    target_bin = ""
    lipo_command = ["lipo", "-create"]
    arch_found = 0

    for arch in architectures:
        bin_name = prefix + "." + arch + suffix
        if Path(bin_name).is_file():
            target_bin = bin_name
            lipo_command += [bin_name]
            arch_found += 1

    if arch_found > 1:
        target_bin = prefix + ".fat" + suffix
        lipo_command += ["-output", target_bin]
        subprocess.run(lipo_command)

    return target_bin


def get_mvk_sdk_path(osname):
    def int_or_zero(i):
        try:
            return int(i)
        except (TypeError, ValueError):
            return 0

    def ver_parse(a):
        return [int_or_zero(i) for i in a.split(".")]

    dirname = os.path.expanduser("~/VulkanSDK")
    if not os.path.exists(dirname):
        return ""

    ver_min = ver_parse("1.3.231.0")
    ver_num = ver_parse("0.0.0.0")
    files = os.listdir(dirname)
    lib_name_out = dirname
    for file in files:
        if os.path.isdir(os.path.join(dirname, file)):
            ver_comp = ver_parse(file)
            if ver_comp > ver_num and ver_comp >= ver_min:
                # Try new SDK location.
                lib_name = os.path.join(os.path.join(dirname, file), "macOS/lib/MoltenVK.xcframework/" + osname + "/")
                if os.path.isfile(os.path.join(lib_name, "libMoltenVK.a")):
                    ver_num = ver_comp
                    lib_name_out = os.path.join(os.path.join(dirname, file), "macOS/lib/MoltenVK.xcframework")
                else:
                    # Try old SDK location.
                    lib_name = os.path.join(
                        os.path.join(dirname, file), "MoltenVK/MoltenVK.xcframework/" + osname + "/"
                    )
                    if os.path.isfile(os.path.join(lib_name, "libMoltenVK.a")):
                        ver_num = ver_comp
                        lib_name_out = os.path.join(os.path.join(dirname, file), "MoltenVK/MoltenVK.xcframework")

    return lib_name_out


def detect_mvk(env, osname):
    mvk_list = [
        get_mvk_sdk_path(osname),
        "/opt/homebrew/Frameworks/MoltenVK.xcframework",
        "/usr/local/homebrew/Frameworks/MoltenVK.xcframework",
        "/opt/local/Frameworks/MoltenVK.xcframework",
    ]
    if env["vulkan_sdk_path"] != "":
        mvk_list.insert(0, os.path.expanduser(env["vulkan_sdk_path"]))
        mvk_list.insert(
            0,
            os.path.join(os.path.expanduser(env["vulkan_sdk_path"]), "macOS/lib/MoltenVK.xcframework"),
        )
        mvk_list.insert(
            0,
            os.path.join(os.path.expanduser(env["vulkan_sdk_path"]), "MoltenVK/MoltenVK.xcframework"),
        )

    for mvk_path in mvk_list:
        if mvk_path and os.path.isfile(os.path.join(mvk_path, f"{osname}/libMoltenVK.a")):
            print(f"MoltenVK found at: {mvk_path}")
            return mvk_path

    return ""


def combine_libs_apple_embedded(target, source, env):
    lib_path = target[0].srcnode().abspath
    if "osxcross" in env:
        libtool = "$APPLE_TOOLCHAIN_PATH/usr/bin/${apple_target_triple}libtool"
    else:
        libtool = "$APPLE_TOOLCHAIN_PATH/usr/bin/libtool"
    env.Execute(
        libtool + ' -static -o "' + lib_path + '" ' + " ".join([('"' + lib.srcnode().abspath + '"') for lib in source])
    )


def lipo_and_copy_apple_embedded(
    platform, framework_dir, framework_dir_sim, rel_prefix, dbg_prefix, module_prefix, app_dir, env
):
    bin_dir = env.Dir("#bin").abspath

    # Lipo template libraries.
    #
    # env.extra_suffix contains ".simulator" when building for simulator,
    # but it's undesired when calling lipo()
    extra_suffix = env.extra_suffix.replace(".simulator", "")
    rel_target_bin = lipo(bin_dir + "/libgodot" + module_prefix + "." + rel_prefix, extra_suffix + ".a")
    dbg_target_bin = lipo(bin_dir + "/libgodot" + module_prefix + "." + dbg_prefix, extra_suffix + ".a")
    rel_target_bin_sim = lipo(
        bin_dir + "/libgodot" + module_prefix + "." + rel_prefix, ".simulator" + extra_suffix + ".a"
    )
    dbg_target_bin_sim = lipo(
        bin_dir + "/libgodot" + module_prefix + "." + dbg_prefix, ".simulator" + extra_suffix + ".a"
    )
    # Assemble Xcode project bundle.
    if rel_target_bin != "":
        print(f' Copying "{platform}" release framework')
        shutil.copy(
            rel_target_bin,
            app_dir
            + "/libgodot"
            + module_prefix
            + "."
            + platform
            + ".release.xcframework/"
            + framework_dir
            + "/libgodot"
            + module_prefix
            + ".a",
        )
    if dbg_target_bin != "":
        print(f' Copying "{platform}" debug framework')
        shutil.copy(
            dbg_target_bin,
            app_dir
            + "/libgodot"
            + module_prefix
            + "."
            + platform
            + ".debug.xcframework/"
            + framework_dir
            + "/libgodot"
            + module_prefix
            + ".a",
        )
    if rel_target_bin_sim != "":
        print(f' Copying "{platform}" (simulator) release framework')
        shutil.copy(
            rel_target_bin_sim,
            app_dir
            + "/libgodot"
            + module_prefix
            + "."
            + platform
            + ".release.xcframework/"
            + framework_dir_sim
            + "/libgodot"
            + module_prefix
            + ".a",
        )
    if dbg_target_bin_sim != "":
        print(f' Copying "{platform}" (simulator) debug framework')
        shutil.copy(
            dbg_target_bin_sim,
            app_dir
            + "/libgodot"
            + module_prefix
            + "."
            + platform
            + ".debug.xcframework/"
            + framework_dir_sim
            + "/libgodot"
            + module_prefix
            + ".a",
        )


def generate_bundle_apple_embedded(platform, framework_dir, framework_dir_sim, use_mkv, target, source, env):
    # Template bundle.
    extra_suffix = env.extra_suffix.replace(".simulator", "")
    app_prefix = "godot." + platform
    rel_prefix = platform + "." + "template_release"
    dbg_prefix = platform + "." + "template_debug"
    if env.dev_build:
        app_prefix += ".dev"
        rel_prefix += ".dev"
        dbg_prefix += ".dev"
    if env["precision"] == "double":
        app_prefix += ".double"
        rel_prefix += ".double"
        dbg_prefix += ".double"

    app_dir = env.Dir("#bin/" + platform + "_xcode").abspath
    templ = env.Dir("#misc/dist/apple_embedded_xcode").abspath
    if os.path.exists(app_dir):
        shutil.rmtree(app_dir)
    shutil.copytree(templ, app_dir)

    lipo_and_copy_apple_embedded(platform, framework_dir, framework_dir_sim, rel_prefix, dbg_prefix, "", app_dir, env)
    if "MODULES_EXTERNAL" in env:
        for mod in env["MODULES_EXTERNAL"]:
            lipo_and_copy_apple_embedded(
                platform, framework_dir, framework_dir_sim, rel_prefix, dbg_prefix, mod, app_dir, env
            )

    # Remove other platform xcframeworks
    for entry in os.listdir(app_dir):
        if (entry.startswith("libgodot.") or entry.startswith("libgodot_")) and entry.endswith(".xcframework"):
            parts = entry.split(".")
            if len(parts) >= 3 and parts[1] != platform:
                full_path = os.path.join(app_dir, entry)
                shutil.rmtree(full_path)

    if use_mkv:
        mvk_path = detect_mvk(env, "ios-arm64")
        if mvk_path != "":
            shutil.copytree(mvk_path + "/ios-arm64", app_dir + "/MoltenVK.xcframework/ios-arm64")
            shutil.copytree(
                mvk_path + "/ios-arm64_x86_64-simulator", app_dir + "/MoltenVK.xcframework/ios-arm64_x86_64-simulator"
            )
            shutil.copy(mvk_path + "/Info.plist", app_dir + "/MoltenVK.xcframework/Info.plist")

    # ZIP Xcode project bundle.
    zip_dir = env.Dir("#bin/" + (app_prefix + extra_suffix).replace(".", "_")).abspath
    shutil.make_archive(zip_dir, "zip", root_dir=app_dir)
    shutil.rmtree(app_dir)


def setup_swift_builder(
    env,
    apple_platform,
    sdk_path,
    current_path,
    bridging_header_filename,
    all_swift_files,
):
    """Compile Swift sources and emit a Swift->ObjC interop header.

    Two passes:
    - Per-file `-primary-file` compile of every entry in `all_swift_files` to `.o`.
    - Whole-module `-emit-module` pass over the same files, emitting a single combined
      `<module>-Swift.gen.h` with every `@objc` declaration. ObjC++ `#import`s it to
      call into Swift directly.

    The bridging header must transitively declare every ObjC type referenced by any
    listed Swift source: whole-module mode type-checks them all together, unlike
    per-file mode.
    """
    from SCons.Script import Action, Builder

    if apple_platform == "macos":
        target_suffix = "macosx10.9"
        platform_folder = "macos"

    elif apple_platform == "ios":
        target_suffix = "ios14.0"  # iOS 14.0 needed for SwiftUI lifecycle
        platform_folder = "ios"

    elif apple_platform == "iossimulator":
        target_suffix = "ios14.0-simulator"  # iOS 14.0 needed for SwiftUI lifecycle
        platform_folder = "ios"

    elif apple_platform == "visionos":
        target_suffix = "xros26.0"
        platform_folder = "visionos"

    elif apple_platform == "visionossimulator":
        target_suffix = "xros26.0-simulator"
        platform_folder = "visionos"

    else:
        raise Exception("Invalid platform argument passed to detect_darwin_sdk_path")

    swiftc_target = env["arch"] + "-apple-" + target_suffix

    env["ALL_SWIFT_FILES"] = all_swift_files
    env["CURRENT_PATH"] = current_path
    if "SWIFT_FRONTEND" in env and env["SWIFT_FRONTEND"] != "":
        frontend_path = env["SWIFT_FRONTEND"]
    elif "osxcross" not in env:
        frontend_path = "$APPLE_TOOLCHAIN_PATH/usr/bin/swift-frontend"
    else:
        frontend_path = None

    if frontend_path is None:
        raise Exception("Swift frontend path is not set. Please set SWIFT_FRONTEND.")

    bridging_header_path = current_path + "/" + bridging_header_filename
    swift_module_name = "godot_swift_module"
    # Standard `<module>-Swift.h` name plus `.gen.h` so it's covered by `*.gen.*` in `.gitignore`.
    swift_objc_header_filename = swift_module_name + "-Swift.gen.h"
    swift_objc_header_path = current_path + "/" + swift_objc_header_filename
    env["SWIFTC"] = frontend_path + " -frontend -c"  # Swift compiler
    # Toolchain macro plugins (e.g. `ObservationMacros`); not auto-discovered by `swift-frontend`.
    swift_plugin_path = "$APPLE_TOOLCHAIN_PATH/usr/lib/swift/host/plugins"
    # Flags shared between the per-file compile pass and the whole-module header pass.
    common_swift_flags = [
        "-warnings-as-errors",
        "-cxx-interoperability-mode=default",
        "-target",
        swiftc_target,
        "-sdk",
        sdk_path,
        "-import-objc-header",
        bridging_header_path,
        "-swift-version",
        "6",
        "-parse-as-library",
        "-module-name",
        swift_module_name,
        "-plugin-path",
        swift_plugin_path,
        "-I./",  # Pass the current directory as the header root so bridging headers can include files from any point of the hierarchy
        "-I./platform/"
        + platform_folder
        + "/",  # Pass the current platform directory, so the bridging header can include files that include platform_config.h
    ]
    env["SWIFTCFLAGS"] = ["-emit-object"] + common_swift_flags
    env["SWIFT_OBJC_HEADER_FLAGS"] = common_swift_flags
    env["SWIFT_OBJC_HEADER_PATH"] = swift_objc_header_path
    env["SWIFT_OBJC_HEADER_FILENAME"] = swift_objc_header_filename
    # `swift-frontend -frontend` is `$SWIFTC` minus the `-c` action.
    env["SWIFT_FRONTEND_BIN"] = frontend_path + " -frontend"

    if "osxcross" in env:
        env.Append(
            SWIFTCFLAGS=[
                "-resource-dir",
                "/root/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift",
                "-enable-cross-import-overlays",
            ]
        )
        env.Append(
            SWIFT_OBJC_HEADER_FLAGS=[
                "-resource-dir",
                "/root/Xcode.app/Contents/Developer/Toolchains/XcodeDefault.xctoolchain/usr/lib/swift",
                "-enable-cross-import-overlays",
            ]
        )

    if env["debug_symbols"]:
        env.Append(SWIFTCFLAGS=["-g"])

    if env["optimize"] in ["speed", "speed_trace"]:
        env.Append(SWIFTCFLAGS=["-O"])

    elif env["optimize"] == "size":
        env.Append(SWIFTCFLAGS=["-Osize"])

    elif env["optimize"] in ["debug", "none"]:
        env.Append(SWIFTCFLAGS=["-Onone"])

    def generate_swift_action(source, target, env, for_signature):
        fullpath_swift_files = [env["CURRENT_PATH"] + "/" + file for file in env["ALL_SWIFT_FILES"]]
        fullpath_swift_files.remove(source[0].abspath)

        fullpath_swift_files_string = '"' + '" "'.join(fullpath_swift_files) + '"'
        compile_command = "$SWIFTC " + fullpath_swift_files_string + " -primary-file $SOURCE -o $TARGET $SWIFTCFLAGS"

        swift_comdstr = env.get("SWIFTCOMSTR")
        if swift_comdstr is not None:
            swift_action = Action(compile_command, cmdstr=swift_comdstr)
        else:
            swift_action = Action(compile_command)

        return swift_action

    # Define Builder for Swift files
    swift_builder = Builder(
        generator=generate_swift_action, suffix=env["OBJSUFFIX"], src_suffix=".swift", emitter=methods.redirect_emitter
    )

    env.Append(BUILDERS={"Swift": swift_builder})
    env["BUILDERS"]["Library"].add_src_builder("Swift")
    env["BUILDERS"]["Object"].add_action(".swift", Action(generate_swift_action, generator=1))
    env["BUILDERS"]["Object"].emitter[".swift"] = methods.redirect_emitter

    # Whole-module pass that emits the combined `<module>-Swift.h` for ObjC++ to
    # `#import`. Runs in whole-module mode because `-primary-file` silently drops
    # `-emit-objc-header-path`. The resulting `.swiftmodule` is discarded.
    fullpath_swift_files = [current_path + "/" + f for f in all_swift_files]
    swiftmodule_path = swift_objc_header_path + ".swiftmodule"

    def generate_swift_objc_header_action(target, source, env, for_signature):
        fullpath_swift_files_string = '"' + '" "'.join([s.abspath for s in source]) + '"'
        compile_command = (
            "$SWIFT_FRONTEND_BIN -emit-module "
            + fullpath_swift_files_string
            + ' -emit-objc-header-path "$SWIFT_OBJC_HEADER_PATH"'
            + ' -emit-module-path "$SWIFT_OBJC_HEADER_MODULE_PATH"'
            + " $SWIFT_OBJC_HEADER_FLAGS"
        )

        comdstr = env.get("SWIFTOBJCHEADERCOMSTR")
        if comdstr is not None:
            return Action(compile_command, cmdstr=comdstr)
        return Action(compile_command)

    env["SWIFT_OBJC_HEADER_MODULE_PATH"] = swiftmodule_path
    swift_objc_header_target = env.Command(
        swift_objc_header_path,
        fullpath_swift_files,
        Action(generate_swift_objc_header_action, generator=1),
    )
    env["SWIFT_OBJC_HEADER_TARGET"] = swift_objc_header_target
    env.Clean(swift_objc_header_target, [swift_objc_header_path, swiftmodule_path])
