const std = @import("std");
const builtin = @import("builtin");
// const assert = std.debug.assert;
const io = std.io;
const fs = std.fs;
const mem = std.mem;
const process = std.process;
const Allocator = mem.Allocator;
// const ArrayList = std.ArrayList;
// const Ast = std.zig.Ast;
const Color = std.zig.Color;
// const warn = std.log.warn;
const ThreadPool = std.Thread.Pool;
const cleanExit = std.process.cleanExit;
const native_os = builtin.os.tag;
// const Cache = std.Build.Cache;
// const Path = std.Build.Cache.Path;
const Directory = std.Build.Cache.Directory;
const EnvVar = std.zig.EnvVar;
// const LibCInstallation = std.zig.LibCInstallation;
// const AstGen = std.zig.AstGen;
// const ZonGen = std.zig.ZonGen;
// const Server = std.zig.Server;

// const tracy = @import("tracy.zig");
// const Compilation = @import("Compilation.zig");
// const link = @import("link.zig");
const Package = @import("Package.zig");
// const build_options = @import("build_options");
const introspect = @import("introspect.zig");
// const wasi_libc = @import("wasi_libc.zig");
// const target_util = @import("target.zig");
// const crash_report = @import("crash_report.zig");
// const Zcu = @import("Zcu.zig");
// const mingw = @import("mingw.zig");
// const dev = @import("dev.zig");

const zigs = @import("zigs.zig");

fn determineZigVersion() ![]const u8 {
    std.log.info("hardcoded to zig version 0.13.0", .{});
    return "0.13.0";
}

pub fn main() !void {
    // First, determine which zig version we need
    const zig_version = try determineZigVersion();
    std.log.info("zig version '{s}'", .{zig_version});

    const platform: zigs.Platform = .@"linux-x86_64";
    const hash = zigs.getHash(platform, zig_version) orelse fatal("unknown zig version '{s}'", .{zig_version});

    if (true) std.debug.panic("todo: check if we already have this zig (hash {s})", .{hash});

    var gpa_instance: std.heap.GeneralPurposeAllocator(.{}) = .{};
    defer _ = gpa_instance.deinit();
    const gpa = gpa_instance.allocator();

    var arena_instance = std.heap.ArenaAllocator.init(gpa);
    defer arena_instance.deinit();

    const arena = arena_instance.allocator();
    const args = try std.process.argsAlloc(arena);
    if (args.len <= 1) {
        const stdout = io.getStdOut().writer();
        try stdout.writeAll(usage_fetch);
        return cleanExit();
    }
    const cmd = args[1];
    const cmd_args = args[2..];
    if (!std.mem.eql(u8, cmd, "fetch")) {
        std.log.err("unsupported command '{s}' (only 'fetch' is supported)", .{cmd});
        return cleanExit();
    }
    return cmdFetch(gpa, arena, cmd_args);
}

const usage_fetch =
    \\Usage: zig fetch [options] <url>
    \\Usage: zig fetch [options] <path>
    \\
    \\    Copy a package into the global cache and print its hash.
    \\
    \\Options:
    \\  -h, --help                    Print this help and exit
    \\  --global-cache-dir [path]     Override path to global Zig cache directory
    \\  --debug-hash                  Print verbose hash information to stdout
    \\  --save                        Add the fetched package to build.zig.zon
    \\  --save=[name]                 Add the fetched package to build.zig.zon as name
    \\  --save-exact                  Add the fetched package to build.zig.zon, storing the URL verbatim
    \\  --save-exact=[name]           Add the fetched package to build.zig.zon as name, storing the URL verbatim
    \\
;

pub fn cmdFetch(
    gpa: Allocator,
    arena: Allocator,
    args: []const []const u8,
) !void {
    const color: Color = .auto;
    const work_around_btrfs_bug = native_os == .linux and
        try EnvVar.ZIG_BTRFS_WORKAROUND.isSet(arena);
    var opt_path_or_url: ?[]const u8 = null;
    var override_global_cache_dir: ?[]const u8 = try EnvVar.ZIG_GLOBAL_CACHE_DIR.get(arena);
    var debug_hash: bool = false;
    var save: union(enum) {
        no,
        yes: ?[]const u8,
        exact: ?[]const u8,
    } = .no;

    {
        var i: usize = 0;
        while (i < args.len) : (i += 1) {
            const arg = args[i];
            if (mem.startsWith(u8, arg, "-")) {
                if (mem.eql(u8, arg, "-h") or mem.eql(u8, arg, "--help")) {
                    const stdout = io.getStdOut().writer();
                    try stdout.writeAll(usage_fetch);
                    return cleanExit();
                } else if (mem.eql(u8, arg, "--global-cache-dir")) {
                    if (i + 1 >= args.len) fatal("expected argument after '{s}'", .{arg});
                    i += 1;
                    override_global_cache_dir = args[i];
                } else if (mem.eql(u8, arg, "--debug-hash")) {
                    debug_hash = true;
                } else if (mem.eql(u8, arg, "--save")) {
                    save = .{ .yes = null };
                } else if (mem.startsWith(u8, arg, "--save=")) {
                    save = .{ .yes = arg["--save=".len..] };
                } else if (mem.eql(u8, arg, "--save-exact")) {
                    save = .{ .exact = null };
                } else if (mem.startsWith(u8, arg, "--save-exact=")) {
                    save = .{ .exact = arg["--save-exact=".len..] };
                } else {
                    fatal("unrecognized parameter: '{s}'", .{arg});
                }
            } else if (opt_path_or_url != null) {
                fatal("unexpected extra parameter: '{s}'", .{arg});
            } else {
                opt_path_or_url = arg;
            }
        }
    }

    const path_or_url = opt_path_or_url orelse fatal("missing url or path parameter", .{});

    var thread_pool: ThreadPool = undefined;
    try thread_pool.init(.{ .allocator = gpa });
    defer thread_pool.deinit();

    var http_client: std.http.Client = .{ .allocator = gpa };
    defer http_client.deinit();

    try http_client.initDefaultProxies(arena);

    var root_prog_node = std.Progress.start(.{
        .root_name = "Fetch",
    });
    defer root_prog_node.end();

    var global_cache_directory: Directory = l: {
        const p = override_global_cache_dir orelse try introspect.resolveGlobalCacheDir(arena);
        break :l .{
            .handle = try fs.cwd().makeOpenPath(p, .{}),
            .path = p,
        };
    };
    defer global_cache_directory.handle.close();

    var job_queue: Package.Fetch.JobQueue = .{
        .http_client = &http_client,
        .thread_pool = &thread_pool,
        .global_cache = global_cache_directory,
        .recursive = false,
        .read_only = false,
        .debug_hash = debug_hash,
        .work_around_btrfs_bug = work_around_btrfs_bug,
    };
    defer job_queue.deinit();

    var fetch: Package.Fetch = .{
        .arena = std.heap.ArenaAllocator.init(gpa),
        .location = .{ .path_or_url = path_or_url },
        .location_tok = 0,
        .hash_tok = 0,
        .name_tok = 0,
        .lazy_status = .eager,
        .parent_package_root = undefined,
        .parent_manifest_ast = null,
        .prog_node = root_prog_node,
        .job_queue = &job_queue,
        .omit_missing_hash_error = true,
        .allow_missing_paths_field = false,
        .use_latest_commit = true,

        .package_root = undefined,
        .error_bundle = undefined,
        .manifest = null,
        .manifest_ast = undefined,
        .actual_hash = undefined,
        .has_build_zig = false,
        .oom_flag = false,
        .latest_commit = null,

        .module = null,
    };
    defer fetch.deinit();

    fetch.run() catch |err| switch (err) {
        error.OutOfMemory => fatal("out of memory", .{}),
        error.FetchFailed => {}, // error bundle checked below
    };

    if (fetch.error_bundle.root_list.items.len > 0) {
        var errors = try fetch.error_bundle.toOwnedBundle("");
        errors.renderToStdErr(color.renderOptions());
        process.exit(1);
    }

    const hex_digest = Package.Manifest.hexDigest(fetch.actual_hash);

    root_prog_node.end();
    root_prog_node = .{ .index = .none };

    try io.getStdOut().writeAll(hex_digest ++ "\n");
    return cleanExit();

    // const name = switch (save) {
    //     .no => {
    //         try io.getStdOut().writeAll(hex_digest ++ "\n");
    //         return cleanExit();
    //     },
    //     .yes, .exact => |name| name: {
    //         if (name) |n| break :name n;
    //         const fetched_manifest = fetch.manifest orelse
    //             fatal("unable to determine name; fetched package has no build.zig.zon file", .{});
    //         break :name fetched_manifest.name;
    //     },
    // };

    // const cwd_path = try process.getCwdAlloc(arena);

    // var build_root = try findBuildRoot(arena, .{
    //     .cwd_path = cwd_path,
    // });
    // defer build_root.deinit();

    // The name to use in case the manifest file needs to be created now.
    // const init_root_name = fs.path.basename(build_root.directory.path orelse cwd_path);
    // var manifest, var ast = try loadManifest(gpa, arena, .{
    //     .root_name = init_root_name,
    //     .dir = build_root.directory.handle,
    //     .color = color,
    // });
    // defer {
    //     manifest.deinit(gpa);
    //     ast.deinit(gpa);
    // }

    // var fixups: Ast.Fixups = .{};
    // defer fixups.deinit(gpa);

    // var saved_path_or_url = path_or_url;

    // if (fetch.latest_commit) |latest_commit| resolved: {
    //     const latest_commit_hex = try std.fmt.allocPrint(arena, "{}", .{latest_commit});

    //     var uri = try std.Uri.parse(path_or_url);

    //     if (uri.fragment) |fragment| {
    //         const target_ref = try fragment.toRawMaybeAlloc(arena);

    //         // the refspec may already be fully resolved
    //         if (std.mem.eql(u8, target_ref, latest_commit_hex)) break :resolved;

    //         std.log.info("resolved ref '{s}' to commit {s}", .{ target_ref, latest_commit_hex });

    //         // include the original refspec in a query parameter, could be used to check for updates
    //         uri.query = .{ .percent_encoded = try std.fmt.allocPrint(arena, "ref={%}", .{fragment}) };
    //     } else {
    //         std.log.info("resolved to commit {s}", .{latest_commit_hex});
    //     }

    //     // replace the refspec with the resolved commit SHA
    //     uri.fragment = .{ .raw = latest_commit_hex };

    //     switch (save) {
    //         .yes => saved_path_or_url = try std.fmt.allocPrint(arena, "{}", .{uri}),
    //         .no, .exact => {}, // keep the original URL
    //     }
    // }

    // const new_node_init = try std.fmt.allocPrint(arena,
    //     \\.{{
    //     \\            .url = "{}",
    //     \\            .hash = "{}",
    //     \\        }}
    // , .{
    //     std.zig.fmtEscapes(saved_path_or_url),
    //     std.zig.fmtEscapes(&hex_digest),
    // });

    // const new_node_text = try std.fmt.allocPrint(arena, ".{p_} = {s},\n", .{
    //     std.zig.fmtId(name), new_node_init,
    // });

    // const dependencies_init = try std.fmt.allocPrint(arena, ".{{\n        {s}    }}", .{
    //     new_node_text,
    // });

    // const dependencies_text = try std.fmt.allocPrint(arena, ".dependencies = {s},\n", .{
    //     dependencies_init,
    // });

    // if (manifest.dependencies.get(name)) |dep| {
    //     if (dep.hash) |h| {
    //         switch (dep.location) {
    //             .url => |u| {
    //                 if (mem.eql(u8, h, &hex_digest) and mem.eql(u8, u, saved_path_or_url)) {
    //                     std.log.info("existing dependency named '{s}' is up-to-date", .{name});
    //                     process.exit(0);
    //                 }
    //             },
    //             .path => {},
    //         }
    //     }

    //     const location_replace = try std.fmt.allocPrint(
    //         arena,
    //         "\"{}\"",
    //         .{std.zig.fmtEscapes(saved_path_or_url)},
    //     );
    //     const hash_replace = try std.fmt.allocPrint(
    //         arena,
    //         "\"{}\"",
    //         .{std.zig.fmtEscapes(&hex_digest)},
    //     );

    //     warn("overwriting existing dependency named '{s}'", .{name});
    //     try fixups.replace_nodes_with_string.put(gpa, dep.location_node, location_replace);
    //     try fixups.replace_nodes_with_string.put(gpa, dep.hash_node, hash_replace);
    // } else if (manifest.dependencies.count() > 0) {
    //     // Add fixup for adding another dependency.
    //     const deps = manifest.dependencies.values();
    //     const last_dep_node = deps[deps.len - 1].node;
    //     try fixups.append_string_after_node.put(gpa, last_dep_node, new_node_text);
    // } else if (manifest.dependencies_node != 0) {
    //     // Add fixup for replacing the entire dependencies struct.
    //     try fixups.replace_nodes_with_string.put(gpa, manifest.dependencies_node, dependencies_init);
    // } else {
    //     // Add fixup for adding dependencies struct.
    //     try fixups.append_string_after_node.put(gpa, manifest.version_node, dependencies_text);
    // }

    // var rendered = std.ArrayList(u8).init(gpa);
    // defer rendered.deinit();
    // try ast.renderToArrayList(&rendered, fixups);

    // build_root.directory.handle.writeFile(.{ .sub_path = Package.Manifest.basename, .data = rendered.items }) catch |err| {
    //     fatal("unable to write {s} file: {s}", .{ Package.Manifest.basename, @errorName(err) });
    // };

    // return cleanExit();
}

// const FindBuildRootOptions = struct {
//     build_file: ?[]const u8 = null,
//     cwd_path: ?[]const u8 = null,
// };

// fn findBuildRoot(arena: Allocator, options: FindBuildRootOptions) !BuildRoot {
//     const cwd_path = options.cwd_path orelse try process.getCwdAlloc(arena);
//     const build_zig_basename = if (options.build_file) |bf|
//         fs.path.basename(bf)
//     else
//         Package.build_zig_basename;

//     if (options.build_file) |bf| {
//         if (fs.path.dirname(bf)) |dirname| {
//             const dir = fs.cwd().openDir(dirname, .{}) catch |err| {
//                 fatal("unable to open directory to build file from argument 'build-file', '{s}': {s}", .{ dirname, @errorName(err) });
//             };
//             return .{
//                 .build_zig_basename = build_zig_basename,
//                 .directory = .{ .path = dirname, .handle = dir },
//                 .cleanup_build_dir = dir,
//             };
//         }

//         return .{
//             .build_zig_basename = build_zig_basename,
//             .directory = .{ .path = null, .handle = fs.cwd() },
//             .cleanup_build_dir = null,
//         };
//     }
//     // Search up parent directories until we find build.zig.
//     var dirname: []const u8 = cwd_path;
//     while (true) {
//         const joined_path = try fs.path.join(arena, &[_][]const u8{ dirname, build_zig_basename });
//         if (fs.cwd().access(joined_path, .{})) |_| {
//             const dir = fs.cwd().openDir(dirname, .{}) catch |err| {
//                 fatal("unable to open directory while searching for build.zig file, '{s}': {s}", .{ dirname, @errorName(err) });
//             };
//             return .{
//                 .build_zig_basename = build_zig_basename,
//                 .directory = .{
//                     .path = dirname,
//                     .handle = dir,
//                 },
//                 .cleanup_build_dir = dir,
//             };
//         } else |err| switch (err) {
//             error.FileNotFound => {
//                 dirname = fs.path.dirname(dirname) orelse {
//                     std.log.info("initialize {s} template file with 'zig init'", .{
//                         Package.build_zig_basename,
//                     });
//                     std.log.info("see 'zig --help' for more options", .{});
//                     fatal("no build.zig file found, in the current directory or any parent directories", .{});
//                 };
//                 continue;
//             },
//             else => |e| return e,
//         }
//     }
// }

pub fn fatal(comptime format: []const u8, args: anytype) noreturn {
    std.log.err(format, args);
    process.exit(1);
}
