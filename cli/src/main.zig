// SPDX-License-Identifier: Apache-2.0
// SPDX-FileCopyrightText: 2021 The Elixir Team

const std = @import("std");
const builtin = @import("builtin");
const build_options = @import("build_options");

const Io = std.Io;
const Allocator = std.mem.Allocator;
const ArrayList = std.ArrayList;

const is_windows = builtin.os.tag == .windows;
const sep = std.fs.path.sep_str;
const exe_ext = if (is_windows) ".exe" else "";

const tool = build_options.tool;
const version = std.mem.trim(u8, @embedFile("VERSION"), " \t\r\n");

const ElixirArgs = struct {
    /// Arguments for erl. They go before -extra.
    erl: ArrayList([]const u8) = .empty,
    /// Arguments from --erl.
    erl_switches: ArrayList([]const u8) = .empty,
    /// Arguments for Elixir. They go after -extra.
    extra: ArrayList([]const u8) = .empty,
    iex: bool = false,
    pipe_to: ?struct { pipe_dir: []const u8, log_dir: []const u8 } = null,
};

pub fn main(init: std.process.Init) !u8 {
    const arena = init.arena.allocator();
    const io = init.io;
    const argv = try init.minimal.args.toSlice(arena);
    const user_args: []const []const u8 = @ptrCast(argv[1..]);

    var prog = std.fs.path.basename(argv[0]);
    if (is_windows and std.ascii.endsWithIgnoreCase(prog, ".exe")) {
        prog = prog[0 .. prog.len - 4];
    }

    const help = user_args.len > 0 and
        (std.mem.eql(u8, user_args[0], "--help") or
            std.mem.eql(u8, user_args[0], "-h") or
            (is_windows and std.ascii.eqlIgnoreCase(user_args[0], "/h")) or
            (is_windows and std.mem.eql(u8, user_args[0], "/?")));

    var args: ArrayList([]const u8) = .empty;

    switch (tool) {
        .elixir => {
            if (user_args.len == 0 or (user_args.len == 1 and help)) {
                return usage(io, elixir_usage, prog);
            }
            if (user_args.len == 1 and std.mem.eql(u8, user_args[0], "--short-version")) {
                try Io.File.stdout().writeStreamingAll(io, version ++ "\n");
                return 0;
            }
        },
        .elixirc => {
            if (user_args.len == 0 or help) {
                return usage(io, elixirc_usage, prog);
            }
            try args.append(arena, "+elixirc");
        },
        .iex => {
            if (help) {
                return usage(io, iex_usage, prog);
            }
            try args.appendSlice(arena, &.{ "--no-halt", "--erl", "-user elixir", "+iex" });
        },
        .mix => {
            try args.appendSlice(arena, &.{ "-e", "Mix.CLI.main()", "--" });
        },
    }

    try args.appendSlice(arena, user_args);

    const bin_dir = try std.process.executableDirPathAlloc(io, arena);
    const parsed = try parseArgs(arena, io, init.environ_map, bin_dir, args.items);

    if (parsed.pipe_to) |pipe_to| {
        if (is_windows) {
            try Io.File.stderr().writeStreamingAll(io, "--pipe-to : Option is not supported on Windows\n");
            return 1;
        }
        if (std.mem.startsWith(u8, pipe_to.pipe_dir, "-")) {
            try Io.File.stderr().writeStreamingAll(io, "--pipe-to : PIPEDIR cannot be a switch\n");
            return 1;
        }
        if (std.mem.startsWith(u8, pipe_to.log_dir, "-")) {
            try Io.File.stderr().writeStreamingAll(io, "--pipe-to : LOGDIR cannot be a switch\n");
            return 1;
        }
    }

    var erl_argv: ArrayList([]const u8) = .empty;
    try erl_argv.appendSlice(arena, &.{
        "erl",
        "-noshell",
        "-elixir_root",
        try std.mem.concat(arena, u8, &.{ bin_dir, sep ++ ".." ++ sep ++ "lib" }),
        "-pa",
        try std.mem.concat(arena, u8, &.{ bin_dir, sep ++ ".." ++ sep ++ "lib" ++ sep ++ "elixir" ++ sep ++ "ebin" }),
    });
    if (init.environ_map.get("ELIXIR_ERL_OPTIONS")) |options| {
        try appendSplit(arena, &erl_argv, options);
    }
    if (!parsed.iex) {
        try erl_argv.appendSlice(arena, &.{ "-s", "elixir", "start_cli" });
    }
    try erl_argv.appendSlice(arena, parsed.erl_switches.items);
    try erl_argv.appendSlice(arena, parsed.erl.items);
    try erl_argv.append(arena, "-extra");
    try erl_argv.appendSlice(arena, parsed.extra.items);

    if (parsed.pipe_to) |pipe_to| {
        var escaped: ArrayList(u8) = .empty;
        for (erl_argv.items) |arg| {
            try escaped.append(arena, ' ');
            for (arg) |c| {
                if (!(std.ascii.isAlphanumeric(c) or c == '_' or c == '/' or c == '-')) {
                    try escaped.append(arena, '\\');
                }
                try escaped.append(arena, c);
            }
        }
        erl_argv.clearRetainingCapacity();
        try erl_argv.appendSlice(arena, &.{
            "run_erl",
            "-daemon",
            try std.mem.concat(arena, u8, &.{ pipe_to.pipe_dir, "/" }),
            try std.mem.concat(arena, u8, &.{ pipe_to.log_dir, "/" }),
            escaped.items,
        });
    }

    if (init.environ_map.get("ELIXIR_CLI_DRY_RUN")) |value| {
        if (value.len > 0) {
            const line = try std.mem.join(arena, " ", erl_argv.items);
            try Io.File.stdout().writeStreamingAll(io, try std.mem.concat(arena, u8, &.{ line, "\n" }));
            return 0;
        }
    }

    if (parsed.pipe_to) |pipe_to| {
        try Io.Dir.cwd().createDirPath(io, pipe_to.pipe_dir);
        try Io.Dir.cwd().createDirPath(io, pipe_to.log_dir);
        return replace(io, null, erl_argv.items);
    }

    if (is_windows) {
        return spawnAndWait(io, erl_argv.items);
    }

    if (build_options.skip_erl) {
        if (try findErlexec(arena, io, init.environ_map)) |erlexec| {
            try init.environ_map.put("ROOTDIR", erlexec.root_dir);
            try init.environ_map.put("BINDIR", erlexec.bin_dir);
            try init.environ_map.put("PROGNAME", "erl");
            erl_argv.items[0] = erlexec.path;
            return replace(io, init.environ_map, erl_argv.items);
        }
    }

    return replace(io, null, erl_argv.items);
}

// {s} is the program name.

const elixir_usage =
    \\Usage: {s} [options] [.exs file] [data]
    \\
    \\## General options
    \\
    \\  -e "COMMAND"                 Evaluates the given command (*)
    \\  -h, --help                   Prints this message (standalone)
    \\  -r "FILE"                    Requires the given files/patterns (*)
    \\  -S SCRIPT                    Finds and executes the given script in $PATH
    \\  -pr "FILE"                   Requires the given files/patterns in parallel (*)
    \\  -pa "PATH"                   Prepends the given path to Erlang code path (*)
    \\  -pz "PATH"                   Appends the given path to Erlang code path (*)
    \\  -v, --version                Prints Erlang/OTP and Elixir versions (standalone)
    \\
    \\  --color, --no-color          Enables or disables ANSI coloring
    \\  --erl "SWITCHES"             Switches to be passed down to Erlang (*)
    \\  --eval "COMMAND"             Evaluates the given command, same as -e (*)
    \\  --logger-otp-reports BOOL    Enables or disables OTP reporting
    \\  --logger-sasl-reports BOOL   Enables or disables SASL reporting
    \\  --no-halt                    Does not halt the Erlang VM after execution
    \\  --short-version              Prints Elixir version (standalone)
    \\
    \\Options given after the .exs file or -- are passed down to the executed code.
    \\Options can be passed to the Erlang runtime using $ELIXIR_ERL_OPTIONS or --erl.
    \\
    \\## Distribution options
    \\
    \\The following options are related to node distribution.
    \\
    \\  --cookie COOKIE              Sets a cookie for this distributed node
    \\  --hidden                     Makes a hidden node
    \\  --name NAME                  Makes and assigns a name to the distributed node
    \\  --rpc-eval NODE "COMMAND"    Evaluates the given command on the given remote node (*)
    \\  --sname NAME                 Makes and assigns a short name to the distributed node
    \\
    \\--name and --sname may be set to undefined so one is automatically generated.
    \\
    \\## Release options
    \\
    \\The following options are generally used under releases.
    \\
    \\  --boot "FILE"                Uses the given FILE.boot to start the system
    \\  --boot-var VAR "VALUE"       Makes $VAR available as VALUE to FILE.boot (*)
    \\  --erl-config "FILE"          Loads configuration in FILE.config written in Erlang (*)
    \\  --pipe-to "PIPEDIR" "LOGDIR" Starts the Erlang VM as a named PIPEDIR and LOGDIR
    \\  --vm-args "FILE"             Passes the contents in file as arguments to the VM
    \\
    \\--pipe-to starts Elixir detached from console (Unix-like only).
    \\It will attempt to create PIPEDIR and LOGDIR if they don't exist.
    \\See run_erl to learn more. To reattach, run: to_erl PIPEDIR.
    \\
    \\** Options marked with (*) can be given more than once.
    \\** Standalone options can't be combined with other options.
    \\
;

const elixirc_usage =
    \\Usage: {s} [elixir switches] [compiler switches] [.ex files]
    \\
    \\  -h, --help                Prints this message and exits
    \\  -o                        The directory to output compiled files
    \\  -v, --version             Prints Elixir version and exits (standalone)
    \\
    \\  --ignore-module-conflict  Does not emit warnings if a module was previously defined
    \\  --no-debug-info           Does not attach debug info to compiled modules
    \\  --no-docs                 Does not attach documentation to compiled modules
    \\  --profile time            Profile the time to compile modules
    \\  --verbose                 Prints compilation status
    \\  --warnings-as-errors      Treats warnings as errors and return non-zero exit status
    \\
    \\Options given after -- are passed down to the executed code.
    \\Options can be passed to the Erlang runtime using $ELIXIR_ERL_OPTIONS.
    \\Options can be passed to the Erlang compiler using $ERL_COMPILER_OPTIONS.
    \\
;

const iex_usage =
    \\Usage: {s} [options] [.exs file] [data]
    \\
    \\The following options are exclusive to IEx:
    \\
    \\  --dbg pry           Sets the backend for Kernel.dbg/2 to IEx.pry/0
    \\  --dot-iex "FILE"    Evaluates FILE, line by line, to set up IEx' environment.
    \\                      Defaults to evaluating .iex.exs or ~/.iex.exs, if any exists.
    \\                      If FILE is empty, then no file will be loaded.
    \\  --remsh NAME        Connects to a node using a remote shell.
    \\
    \\It accepts all other options listed by "elixir --help".
    \\
;

fn parseArgs(
    arena: Allocator,
    io: Io,
    environ_map: *const std.process.Environ.Map,
    bin_dir: []const u8,
    args: []const []const u8,
) !ElixirArgs {
    var result: ElixirArgs = .{};
    var i: usize = 0;

    while (i < args.len) {
        const arg = args[i];
        // The values that follow the option. If a value is missing, it is empty.
        const value1 = if (i + 1 < args.len) args[i + 1] else "";
        const value2 = if (i + 2 < args.len) args[i + 2] else "";
        // The number of arguments to copy to extra.
        var copy: usize = 0;
        // The number of arguments to remove.
        var skip: usize = 0;

        if (std.mem.eql(u8, arg, "+elixirc") or
            std.mem.eql(u8, arg, "-v") or
            std.mem.eql(u8, arg, "--no-halt") or
            std.mem.eql(u8, arg, "--color") or
            std.mem.eql(u8, arg, "--no-color"))
        {
            copy = 1;
        } else if (std.mem.eql(u8, arg, "+iex")) {
            copy = 1;
            result.iex = true;
        } else if (std.mem.eql(u8, arg, "-e") or
            std.mem.eql(u8, arg, "-r") or
            std.mem.eql(u8, arg, "-pr") or
            std.mem.eql(u8, arg, "-pa") or
            std.mem.eql(u8, arg, "-pz") or
            std.mem.eql(u8, arg, "--eval") or
            std.mem.eql(u8, arg, "--remsh") or
            std.mem.eql(u8, arg, "--dot-iex") or
            std.mem.eql(u8, arg, "--dbg"))
        {
            copy = 2;
        } else if (std.mem.eql(u8, arg, "--rpc-eval")) {
            copy = 3;
        } else if (std.mem.eql(u8, arg, "--hidden")) {
            skip = 1;
            try result.erl.append(arena, "-hidden");
        } else if (std.mem.eql(u8, arg, "--logger-otp-reports") or
            std.mem.eql(u8, arg, "--logger-sasl-reports"))
        {
            skip = 2;
            if (std.mem.eql(u8, value1, "true") or std.mem.eql(u8, value1, "false")) {
                const name = if (std.mem.eql(u8, arg, "--logger-otp-reports"))
                    "handle_otp_reports"
                else
                    "handle_sasl_reports";
                try result.erl_switches.appendSlice(arena, &.{ "-logger", name, value1 });
            }
        } else if (std.mem.eql(u8, arg, "--erl")) {
            skip = 2;
            try appendSplit(arena, &result.erl_switches, value1);
        } else if (std.mem.eql(u8, arg, "--cookie")) {
            skip = 2;
            try result.erl.appendSlice(arena, &.{ "-setcookie", value1 });
        } else if (std.mem.eql(u8, arg, "--sname") or std.mem.eql(u8, arg, "--name")) {
            skip = 2;
            try result.erl.appendSlice(arena, &.{ arg[1..], value1 });
        } else if (std.mem.eql(u8, arg, "--erl-config")) {
            skip = 2;
            try result.erl.appendSlice(arena, &.{ "-config", value1 });
        } else if (std.mem.eql(u8, arg, "--vm-args")) {
            skip = 2;
            try result.erl.appendSlice(arena, &.{ "-args_file", value1 });
        } else if (std.mem.eql(u8, arg, "--boot")) {
            skip = 2;
            try result.erl.appendSlice(arena, &.{ "-boot", value1 });
        } else if (std.mem.eql(u8, arg, "--boot-var")) {
            skip = 3;
            try result.erl.appendSlice(arena, &.{ "-boot_var", value1, value2 });
        } else if (std.mem.eql(u8, arg, "--pipe-to")) {
            skip = 3;
            // If PIPEDIR is empty, ignore --pipe-to.
            if (value1.len > 0) {
                result.pipe_to = .{ .pipe_dir = value1, .log_dir = value2 };
            }
        } else {
            // Stop at the first unknown argument.
            // Send all remaining arguments to Elixir without change.
            const rest = args[i..];
            if (std.mem.eql(u8, arg, "-S") and std.mem.eql(u8, value1, "mix")) {
                // -S finds a file. Elixir reads this file as an Elixir script.
                // Elixir cannot read the mix executable as a script.
                // If -S finds the mix executable, start Mix.CLI.main/0.
                if (try findInPath(arena, io, environ_map, "mix" ++ exe_ext)) |found| {
                    const own = try std.fs.path.join(arena, &.{ bin_dir, "mix" ++ exe_ext });
                    const found_real = Io.Dir.cwd().realPathFileAlloc(io, found, arena) catch found;
                    const own_real = Io.Dir.cwd().realPathFileAlloc(io, own, arena) catch own;
                    if (std.mem.eql(u8, found_real, own_real)) {
                        try result.extra.appendSlice(arena, &.{ "-e", "Mix.CLI.main()", "--" });
                        try result.extra.appendSlice(arena, rest[2..]);
                        break;
                    }
                }
            }
            try result.extra.appendSlice(arena, rest);
            break;
        }

        const end = @min(i + copy, args.len);
        try result.extra.appendSlice(arena, args[i..end]);
        i = @min(@max(end, i + skip), args.len);
    }

    return result;
}

/// Split the value at space, tab, and line-end characters. Keep the quotation marks.
fn appendSplit(arena: Allocator, list: *ArrayList([]const u8), value: []const u8) !void {
    var it = std.mem.tokenizeAny(u8, value, " \t\n\r");
    while (it.next()) |part| {
        try list.append(arena, part);
    }
}

fn usage(io: Io, comptime text: []const u8, prog: []const u8) !u8 {
    const placeholder = comptime std.mem.indexOf(u8, text, "{s}").?;
    const stderr: Io.File = .stderr();
    try stderr.writeStreamingAll(io, text[0..placeholder]);
    try stderr.writeStreamingAll(io, prog);
    try stderr.writeStreamingAll(io, text[placeholder + 3 ..]);
    return 1;
}

fn replace(io: Io, environ_map: ?*const std.process.Environ.Map, argv: []const []const u8) u8 {
    const err = std.process.replace(io, .{ .argv = argv, .environ_map = environ_map });
    return reportStartError(io, argv[0], err);
}

fn spawnAndWait(io: Io, argv: []const []const u8) u8 {
    // erl.exe handles Ctrl+C. Ignore Ctrl+C in this process.
    // If not, this process stops and the child process continues to run.
    _ = SetConsoleCtrlHandler(null, .TRUE);

    var child = std.process.spawn(io, .{ .argv = argv }) catch |err| {
        return reportStartError(io, argv[0], err);
    };
    const term = child.wait(io) catch |err| {
        return reportStartError(io, argv[0], err);
    };
    return switch (term) {
        .exited => |code| code,
        else => 1,
    };
}

extern "kernel32" fn SetConsoleCtrlHandler(
    handler: ?*const anyopaque,
    add: std.os.windows.BOOL,
) callconv(.winapi) std.os.windows.BOOL;

fn reportStartError(io: Io, program: []const u8, err: anyerror) u8 {
    var buffer: [1024]u8 = undefined;
    const message = std.fmt.bufPrint(&buffer, "{s}: cannot start {s}: {s}\n", .{
        @tagName(tool),
        program,
        @errorName(err),
    }) catch "cannot start erl\n";
    Io.File.stderr().writeStreamingAll(io, message) catch {};
    return if (err == error.FileNotFound) 127 else 126;
}

fn findInPath(
    arena: Allocator,
    io: Io,
    environ_map: *const std.process.Environ.Map,
    name: []const u8,
) !?[]const u8 {
    const path = environ_map.get("PATH") orelse return null;
    var it = std.mem.splitScalar(u8, path, std.fs.path.delimiter);
    while (it.next()) |dir| {
        const candidate = try std.fs.path.join(arena, &.{ if (dir.len == 0) "." else dir, name });
        Io.Dir.cwd().access(io, candidate, .{ .execute = !is_windows }) catch continue;
        return candidate;
    }
    return null;
}

const Erlexec = struct {
    path: []const u8,
    root_dir: []const u8,
    bin_dir: []const u8,
};

/// Find erlexec for the erl in PATH. Return null if erlexec is not found.
fn findErlexec(
    arena: Allocator,
    io: Io,
    environ_map: *const std.process.Environ.Map,
) !?Erlexec {
    const erl_path = try findInPath(arena, io, environ_map, "erl") orelse return null;
    const real_path = Io.Dir.cwd().realPathFileAlloc(io, erl_path, arena) catch return null;

    // erl is in ROOTDIR/bin.
    const root_dir = environ_map.get("ERL_ROOTDIR") orelse
        std.fs.path.dirname(std.fs.path.dirname(real_path) orelse return null) orelse return null;

    var bin_dirs: ArrayList([]const u8) = .empty;

    // In an OTP installation, erlexec is in ROOTDIR/erts-<vsn>/bin.
    // The first word in ROOTDIR/releases/start_erl.data is <vsn>.
    var buffer: [256]u8 = undefined;
    const start_erl = try std.fs.path.join(arena, &.{ root_dir, "releases", "start_erl.data" });
    if (Io.Dir.cwd().readFile(io, start_erl, &buffer)) |data| {
        var words = std.mem.tokenizeAny(u8, data, " \t\r\n");
        if (words.next()) |vsn| {
            try bin_dirs.append(arena, try std.mem.concat(arena, u8, &.{ root_dir, "/erts-", vsn, "/bin" }));
        }
    } else |_| {}

    // In an OTP source tree, erlexec is in ROOTDIR/bin/<target>.
    const root_bin = try std.fs.path.join(arena, &.{ root_dir, "bin" });
    if (Io.Dir.cwd().openDir(io, root_bin, .{ .iterate = true })) |dir| {
        defer dir.close(io);
        var it = dir.iterate();
        while (it.next(io) catch null) |entry| {
            if (entry.kind != .directory) {
                continue;
            }
            try bin_dirs.append(arena, try std.fs.path.join(arena, &.{ root_bin, entry.name }));
        }
    } else |_| {}

    for (bin_dirs.items) |bin_dir| {
        const path = try std.fs.path.join(arena, &.{ bin_dir, "erlexec" });
        Io.Dir.cwd().access(io, path, .{ .execute = true }) catch continue;
        return .{ .path = path, .root_dir = root_dir, .bin_dir = bin_dir };
    }

    return null;
}
