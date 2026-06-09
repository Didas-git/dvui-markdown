const markdown = @import("markdown");
const std = @import("std");

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    const arena = init.arena.allocator();

    const args = try init.minimal.args.toSlice(arena);

    if (args.len != 3) fatal("Invalid arguments", .{});

    // std.debug.print("Args:\n", .{});
    // for (args) |arg| {
    //     std.debug.print("- {s}\n", .{arg});
    // }

    const source_dir_path = args[1];
    const dest_dir_path = args[2];

    const source_dir = std.Io.Dir.openDirAbsolute(io, source_dir_path, .{ .iterate = true }) catch |err| {
        fatal("Unable to open '{s}': {s}", .{ source_dir_path, @errorName(err) });
    };
    defer source_dir.close(io);

    const dest_dir = std.Io.Dir.openDirAbsolute(io, dest_dir_path, .{ .iterate = true }) catch |err| {
        fatal("Unable to open '{s}': {s}", .{ dest_dir_path, @errorName(err) });
    };
    defer dest_dir.close(io);

    var iter = source_dir.iterate();
    var arr: std.ArrayList([]const u8) = .empty;

    while (iter.next(io) catch |err| fatal("Directory iteration failed: {s}", .{@errorName(err)})) |entry| {
        switch (entry.kind) {
            .file => {
                const source_file = try source_dir.openFile(io, entry.name, .{});
                defer source_file.close(io);

                const file_name = std.fs.path.stem(entry.name);

                const dest_file_path = try std.mem.concat(arena, u8, &.{ file_name, ".zig" });
                defer arena.free(dest_file_path);

                const dest_file = try dest_dir.createFile(io, dest_file_path, .{});
                defer dest_file.close(io);

                try generateFile(io, arena, source_file, dest_file);
                try arr.append(arena, try arena.dupe(u8, file_name));
            },
            else => |kind| fatal("Unsupported entry kind: {s}", .{@tagName(kind)}),
        }
    }

    const main_file = try dest_dir.createFile(io, "main.zig", .{});
    defer main_file.close(io);

    var main_writer = main_file.writer(io, &.{});
    const main_writer_interface = &main_writer.interface;

    for (arr.items) |item| {
        try main_writer_interface.print("pub const {s} = @import(\"{s}.zig\");\n", .{ item, item });
    }

    try main_writer.end();

    return std.process.cleanExit(io);
}

fn fatal(comptime format: []const u8, args: anytype) noreturn {
    std.debug.print(format, args);
    std.process.exit(1);
}

fn generateFile(
    io: std.Io,
    arena: std.mem.Allocator,
    source_file: std.Io.File,
    dest_file: std.Io.File,
) !void {
    var buff: [4096]u8 = undefined;
    var file_reader = source_file.reader(io, &buff);

    const graph = try markdown.Parser.parse(arena, &file_reader.interface);
    // std.debug.print("MD Graph: {any}\n", .{graph});

    var file_writer = dest_file.writer(io, &.{});
    const writer = &file_writer.interface;

    try writer.writeAll(
        \\const dvui = @import("dvui");
        \\const std = @import("std");
        \\
        \\pub fn render() !void {
        \\    var main_box = dvui.box(@src(), .{}, .{ .expand = .horizontal, .background = true });
        \\    defer main_box.deinit();
        \\
    );
    for (graph, 0..) |node, i| {
        try writeNode(writer, node, i, 8);
    }

    try writer.writeByte('\n');
    try writer.writeByte('}');
    try file_writer.end();
}

fn writeNode(
    // arena: std.mem.Allocator,
    writer: *std.Io.Writer,
    node: *markdown.Parser.Node,
    index: usize,
    indent: usize,
) !void {
    try writer.print(
        \\{[empty]c: >[i]}{{
        \\{[empty]c: >[i]}    var box_{[n]d} = dvui.box(@src(), .{{}}, .{{}});
        \\{[empty]c: >[i]}    defer box_{[n]d}.deinit();
        \\
    , .{ .i = indent, .n = index, .empty = ' ' });
    switch (node.kind) {
        .Heading => |heading| {
            try writer.print(
                \\{[empty]c: >[i]}{{
                \\{[empty]c: >[i]}    var header_box = dvui.box(@src(), .{{}}, .{{ .expand = .horizontal }});
                \\{[empty]c: >[i]}    defer header_box.deinit();
                \\{[empty]c: >[i]}
                \\{[empty]c: >[i]}    dvui.labelNoFmt(@src(), "{[text]s}", .{{}}, .{{ .font = dvui.themeGet().font_heading.larger({[size]d}).withWeight(.bold) }});
                \\{[empty]c: >[i]}    _ = dvui.spacer(@src(), .{{ .min_size_content = .{{ .h = 5, .w = std.math.floatMax(f32) }} }});
                \\
            , .{ .i = indent + 4, .empty = ' ', .text = node.text, .size = 30 / heading });

            for (node.children.items, index + 1..) |child_node, i| try writeNode(writer, child_node, i, indent + 8);

            try writer.print("\n{[empty]c: >[i]}}}", .{ .i = indent + 4, .empty = ' ' });
        },
        .Text => {
            try writer.print(
                \\{[empty]c: >[i]}{{
                \\{[empty]c: >[i]}    var tl = dvui.textLayout(@src(), .{{}}, .{{}});
                \\{[empty]c: >[i]}    defer tl.deinit();
                \\{[empty]c: >[i]}
                \\{[empty]c: >[i]}    tl.addText("{[text]s}", .{{}});
                \\{[empty]c: >[i]}}}
            , .{ .i = indent + 4, .empty = ' ', .text = node.text });
        },
    }

    try writer.print("\n{[empty]c: >[i]}}}", .{ .i = indent, .empty = ' ' });
}
