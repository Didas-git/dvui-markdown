//! TODO: Support UTF-8 properly, all checks atm assume ascii encoding

const std = @import("std");

pub const Node = union(enum) {
    heading: struct {
        /// \# Heading {**custom-id**}
        id: ?[]const u8,
        level: u8,
        text: []Section,
        parent: ?*Node,
        children: std.ArrayList(*Node),
    },
    list: std.ArrayList(*Element),
    code_block: struct {
        language: []const u8,
        initial_indentation: usize,
        lines: std.ArrayList([]const u8),
        closed: bool,
    },
    text: []Section,
    line_break: void,
    horizontal_rule: void,
    // TODO: All the bellow need to be implemented
    table: []Column,
    block_quote: void,
    footnote: []Section,
    /// > [!x]
    /// >
    alert: void,
    /// ::: x
    ///
    /// :::
    container: void,

    pub const Element = struct {
        text: []Section,
        children: std.ArrayList(*Element),
        data: Data,

        const Data = union(Node.ListType) {
            ordered: usize,
            unordered: void,
            task: bool,
        };
    };

    const ListType = enum {
        ordered,
        unordered,
        task,
    };

    pub const Section = union(enum) {
        default: []const u8,
        code: []const u8,
        // This is just to make the matching logic easier
        bold_italic: []Section,
        bold: []Section,
        italic: []Section,
        underline: []Section,
        strike_through: []Section,
        highlight: []Section,
        subscript: []Section,
        superscript: []Section,
        emoji_shortcode: []const u8,
        /// Only present if `typographic_parsing` is enabled
        typographic: []const u8,
        link: struct {
            title: []Section,
            hover_text: []const u8,
            url: []const u8,
        },
        image: struct {
            alt_text: []Section,
            hover_text: []const u8,
            path: []const u8,
            /// Only available when image is embedded with `<img>` html tag
            size: ?struct {
                width: u32,
                height: u32,
            },
        },
    };

    pub const Column = struct {
        alignment: enum { left, right, center },
        header: []Section,
        values: [][]Section,
    };
};

pub const Options = struct {
    mode: enum(u1) {
        /// Allow padding on contained elements
        loose,
        /// No padding strictly enforced in places like image urls
        strict,
    } = .loose,
    /// **NOT YET IMPLEMENTED**
    parse_arbitrary_urls: bool = false,
    /// Parse `__text__` as an `underline` node
    underline_extension: bool = false,
    /// **NOT YET IMPLEMENTED**
    /// Allows typographic replacement:
    /// (c), (C) => ©
    /// (tm), (TM) => ™
    /// (p), (P) => ℗
    /// ?? => ⁇
    /// ???(?) => ？？？
    /// !! => ‼
    /// !!!(!) => ！！！
    /// -- => –
    /// --- => —
    /// +- => ±
    /// "..." = > “...”
    /// '...' => ‘...’
    /// !..(.) => !..
    /// ?..(.) => ?..
    /// ..(.) => …
    typographic_replacement: bool = false,
};

pub fn parse(arena: std.mem.Allocator, buffer: []const u8, options: Options) ![]*Node {
    var ctx: Context = .{};
    var reader: std.Io.Reader = .fixed(if (std.mem.startsWith(u8, buffer, "\xEF\xBB\xBF")) buffer[3..] else buffer);

    while (try reader.takeDelimiter('\n')) |line| {
        try ctx.parseLine(arena, line, options);
    }

    return ctx.graph.toOwnedSlice(arena);
}

const Context = struct {
    graph: std.ArrayList(*Node) = .empty,
    previous_node: ?*Node = null,
    previous_heading: ?*Node = null,

    fn findParentNode(previous_node: ?*Node, level: u8) ?*Node {
        var n = previous_node orelse return null;

        while (n.heading.level > level) {
            n = n.heading.parent orelse break;
        }

        return n;
    }

    fn skipBlank(line: []const u8) usize {
        var i: usize = 0;
        while (std.ascii.isWhitespace(line[i])) : (i += 1) {}
        return i;
    }

    fn appendHeadingNode(ctx: *Context, arena: std.mem.Allocator, level: u8, line: []const u8, options: Options) !void {
        const bracket_index = std.mem.findScalarLast(u8, line, '{');
        const id: ?[]const u8 = if (bracket_index != null and line[line.len - 1] == '}') line[bracket_index.? .. line.len - 2] else null;

        const parent_node = findParentNode(ctx.previous_heading, level);

        const node = try arena.create(Node);
        node.* = .{
            .heading = .{
                .id = id,
                .level = level,
                .text = try parseLineText(arena, line, options),
                .parent = parent_node,
                .children = .empty,
            },
        };

        if (parent_node) |n| try n.heading.children.append(arena, node);
        try ctx.appendNode(arena, node);
    }

    fn innerAppendListNode(
        ctx: *Context,
        arena: std.mem.Allocator,
        list: *std.ArrayList(*Node.Element),
        element_data: Node.Element.Data,
        line: []const u8,
        options: Options,
    ) !void {
        _ = ctx;
        const element = try arena.create(Node.Element);
        element.* = .{
            .text = try parseLineText(arena, line, options),
            .children = .empty,
            .data = element_data,
        };

        try list.append(arena, element);
    }

    fn appendListNode(
        ctx: *Context,
        arena: std.mem.Allocator,
        element_data: Node.Element.Data,
        depth: usize,
        line: []const u8,
        options: Options,
    ) !void {
        if (ctx.previous_node) |previous_node| {
            switch (previous_node.*) {
                .list => |*list_node| {
                    var i: usize = 0;
                    var n = list_node;
                    while (i < depth) : (i += 1) {
                        if (n.items.len == 0) return try ctx.innerAppendListNode(arena, n, element_data, line, options);
                        n = &n.getLast().children;
                    }

                    return try ctx.innerAppendListNode(arena, n, element_data, line, options);
                },
                else => {},
            }
        }

        const node = try arena.create(Node);
        node.* = .{ .list = .empty };

        try ctx.innerAppendListNode(arena, &node.list, element_data, line, options);
        return try ctx.appendNode(arena, node);
    }

    fn appendHorizontalRule(ctx: *Context, arena: std.mem.Allocator) !void {
        const node = try arena.create(Node);
        node.* = .horizontal_rule;

        try ctx.appendNode(arena, node);
    }

    fn appendCodeBlock(ctx: *Context, arena: std.mem.Allocator, skipped: usize, language: []const u8) !void {
        const node = try arena.create(Node);
        node.* = .{
            .code_block = .{
                .closed = false,
                .initial_indentation = skipped,
                .language = language,
                .lines = .empty,
            },
        };

        try ctx.appendNode(arena, node);
    }

    fn appendTextNode(ctx: *Context, arena: std.mem.Allocator, line: []const u8, options: Options) !void {
        const node = try arena.create(Node);
        node.* = .{ .text = try parseLineText(arena, line, options) };

        try ctx.appendNode(arena, node);
    }

    fn makeDefaultSection(reader: *Reader) Node.Section {
        return .{ .default = reader.io_reader.buffer[reader.start..reader.io_reader.seek] };
    }

    const ParseLinkSectionError = error{ InvalidMarkdownFile, OutOfMemory } || std.Io.Reader.DelimiterError;

    fn parseLinkSection(arena: std.mem.Allocator, reader: *Reader, as: enum(u1) { image, link }, options: Options) ParseLinkSectionError!Node.Section {
        const alt_text = try reader.io_reader.takeDelimiterExclusive(']');
        reader.io_reader.toss(1);

        if (try reader.io_reader.takeByte() != '(') return error.InvalidMarkdownFile;

        const contents = try reader.io_reader.takeDelimiterExclusive(')');

        const url, const hover_text = blk: {
            var content_reader: Reader = .init(contents);

            if (options.mode == .strict) {
                if (try content_reader.isBlank()) return error.InvalidMarkdownFile;
            } else try content_reader.skipBlank();

            const url = content_reader.takeExclusive(" ") catch {
                break :blk .{ content_reader.io_reader.buffered(), &.{} };
            };

            if (options.mode == .strict) {
                if (try content_reader.isBlank()) return error.InvalidMarkdownFile;
            } else try content_reader.skipBlank();

            switch (try content_reader.io_reader.takeByte()) {
                ')' => break :blk .{ url, &.{} },
                '"' => {
                    const hover_text = content_reader.io_reader.takeDelimiterExclusive('"') catch return error.InvalidMarkdownFile;
                    break :blk .{ url, hover_text };
                },
                else => return error.InvalidMarkdownFile,
            }
        };

        reader.toss(1);

        return switch (as) {
            .image => .{
                .image = .{
                    .alt_text = try parseLineText(arena, alt_text, options),
                    .hover_text = hover_text,
                    .path = url,
                    .size = null,
                },
            },
            .link => .{
                .link = .{
                    .title = try parseLineText(arena, alt_text, options),
                    .hover_text = hover_text,
                    .url = url,
                },
            },
        };
    }

    const Reader = struct {
        start: usize,
        io_reader: std.Io.Reader,

        pub fn init(buffer: []const u8) Reader {
            return .{
                .start = 0,
                .io_reader = .fixed(buffer),
            };
        }

        pub fn isBlank(self: *Reader) !bool {
            return std.ascii.isWhitespace(try self.io_reader.peekByte());
        }

        pub fn skipBlank(self: *Reader) !void {
            while (try self.isBlank()) {
                self.io_reader.seek += 1;
            }
        }

        pub fn skip(self: *Reader, n: usize) void {
            self.start += n;
        }

        pub fn toss(self: *Reader, n: usize) void {
            if (self.io_reader.seek + n > self.io_reader.end) {
                self.io_reader.seek = self.io_reader.end;
                self.start = self.io_reader.end;
                return;
            }

            self.io_reader.toss(n);
            self.start = self.io_reader.seek;
        }

        pub fn peekInclusive(self: *Reader, needle: []const u8) ![]u8 {
            const contents = self.io_reader.buffer[0..self.io_reader.end];
            const seek = self.io_reader.seek;

            if (std.mem.findPos(u8, contents, seek, needle)) |end| {
                @branchHint(.likely);
                return contents[seek .. end + needle.len];
            }

            return error.EndOfStream;
        }

        pub fn peekExclusive(self: *Reader, needle: []const u8) ![]u8 {
            const result = try self.peekInclusive(needle);
            return result[0 .. result.len - needle.len];
        }

        pub fn takeExclusive(self: *Reader, needle: []const u8) ![]u8 {
            const result = try self.peekExclusive(needle);
            self.io_reader.toss(result.len);
            return result;
        }

        pub fn take(self: *Reader, end: usize) []u8 {
            const slice = self.io_reader.buffer[self.start..end];
            self.start = end;
            return slice;
        }
    };

    fn parseLineText(arena: std.mem.Allocator, line: []const u8, options: Options) ![]Node.Section {
        var arr: std.ArrayList(Node.Section) = try .initCapacity(arena, 2);
        errdefer arr.deinit(arena);

        var reader: Reader = .init(line);

        // Maybe empty line should error?
        loop: switch (reader.io_reader.takeByte() catch return &.{}) {
            '!' => {
                const next_byte = reader.io_reader.takeByte() catch {
                    try arr.append(arena, makeDefaultSection(&reader));
                    break :loop;
                };

                if (next_byte != '[') continue :loop next_byte;
                const seek_pos = reader.io_reader.seek;

                const section = parseLinkSection(arena, &reader, .image, options) catch {
                    reader.io_reader.seek = seek_pos;
                    const next_byte_inner = reader.io_reader.takeByte() catch {
                        try arr.append(arena, makeDefaultSection(&reader));
                        break :loop;
                    };
                    continue :loop next_byte_inner;
                };

                try arr.append(arena, section);
            },
            '[' => {
                const seek_pos = reader.io_reader.seek;

                const section = parseLinkSection(arena, &reader, .link, options) catch {
                    reader.io_reader.seek = seek_pos;
                    const next_byte_inner = reader.io_reader.takeByte() catch {
                        try arr.append(arena, makeDefaultSection(&reader));
                        break :loop;
                    };
                    continue :loop next_byte_inner;
                };

                try arr.append(arena, section);
            },
            '=', '~' => |c| {
                const next_byte = reader.io_reader.takeByte() catch {
                    try arr.append(arena, makeDefaultSection(&reader));
                    break :loop;
                };

                if (next_byte != c) continue :loop next_byte;
                const seek_pos = reader.io_reader.seek;

                const text = reader.takeExclusive(&@as([2]u8, @splat(c))) catch {
                    const next_byte_inner = reader.io_reader.takeByte() catch {
                        try arr.append(arena, makeDefaultSection(&reader));
                        break :loop;
                    };
                    continue :loop next_byte_inner;
                };

                if (reader.start != seek_pos - 2) {
                    try arr.append(arena, .{ .default = reader.take(seek_pos - 2) });
                }

                if (c == '=') {
                    try arr.append(arena, .{ .highlight = try parseLineText(arena, text, options) });
                } else {
                    try arr.append(arena, .{ .strike_through = try parseLineText(arena, text, options) });
                }

                reader.toss(2);
                continue :loop reader.io_reader.takeByte() catch break :loop;
            },
            '`', ':' => |c| {
                const seek_pos = reader.io_reader.seek;
                const text = reader.io_reader.takeDelimiterExclusive(c) catch {
                    const next_byte_inner = reader.io_reader.takeByte() catch {
                        try arr.append(arena, makeDefaultSection(&reader));
                        break :loop;
                    };
                    continue :loop next_byte_inner;
                };

                if (reader.start != seek_pos - 1) {
                    try arr.append(arena, .{ .default = reader.take(seek_pos - 1) });
                }

                if (c == '`') {
                    try arr.append(arena, .{ .code = text });
                } else {
                    try arr.append(arena, .{ .emoji_shortcode = text });
                }

                reader.toss(1);
                continue :loop reader.io_reader.takeByte() catch break :loop;
            },
            '*', '_' => |c| {
                const next_byte = reader.io_reader.peekByte() catch {
                    try arr.append(arena, makeDefaultSection(&reader));
                    break :loop;
                };

                if (next_byte == c) {
                    reader.io_reader.toss(1);

                    const next_byte_inner = reader.io_reader.peekByte() catch {
                        try arr.append(arena, makeDefaultSection(&reader));
                        break :loop;
                    };

                    if (next_byte_inner == c) {
                        reader.io_reader.toss(1);
                        const seek_pos = reader.io_reader.seek;

                        const text = reader.takeExclusive(&@as([2]u8, @splat(c))) catch {
                            const n_next_byte_inner = reader.io_reader.takeByte() catch {
                                try arr.append(arena, makeDefaultSection(&reader));
                                break :loop;
                            };
                            continue :loop n_next_byte_inner;
                        };

                        if (reader.start != seek_pos - 3) {
                            try arr.append(arena, .{ .default = reader.take(seek_pos - 3) });
                        }

                        try arr.append(arena, .{ .bold_italic = try parseLineText(arena, text, options) });

                        reader.toss(3);
                    } else {
                        const seek_pos = reader.io_reader.seek;
                        const text = reader.takeExclusive(&@as([2]u8, @splat(c))) catch continue :loop next_byte_inner;

                        if (reader.start != seek_pos - 2) {
                            try arr.append(arena, .{ .default = reader.take(seek_pos - 2) });
                        }

                        try arr.append(
                            arena,
                            if (options.underline_extension) .{
                                .underline = try parseLineText(arena, text, options),
                            } else .{
                                .bold = try parseLineText(arena, text, options),
                            },
                        );
                        reader.toss(2);
                    }
                } else {
                    const seek_pos = reader.io_reader.seek;

                    const text = reader.io_reader.takeDelimiterExclusive(c) catch {
                        continue :loop next_byte;
                    };

                    if (reader.start != seek_pos - 1) {
                        try arr.append(arena, .{ .default = reader.take(seek_pos - 1) });
                    }

                    try arr.append(arena, .{ .italic = try parseLineText(arena, text, options) });
                    reader.toss(1);
                }

                continue :loop reader.io_reader.takeByte() catch break :loop;
            },
            else => {
                continue :loop reader.io_reader.takeByte() catch {
                    try arr.append(arena, .{ .default = reader.io_reader.buffer[reader.start..] });
                    break :loop;
                };
            },
        }

        return arr.toOwnedSlice(arena);
    }

    fn appendNode(ctx: *Context, arena: std.mem.Allocator, node: *Node) !void {
        defer {
            if (node.* == .heading) ctx.previous_heading = node;
            ctx.previous_node = node;
        }

        if (ctx.previous_heading) |prev_node| {
            if (node.* == .heading) return;
            try prev_node.heading.children.append(arena, node);
        } else {
            try ctx.graph.append(arena, node);
        }
    }

    fn parseLine(ctx: *Context, arena: std.mem.Allocator, raw_line: []const u8, options: Options) !void {
        if (raw_line.len == 0) {
            if (ctx.previous_heading) |heading| {
                if (ctx.previous_node) |node| {
                    switch (node.*) {
                        .text => {
                            const new_node = try arena.create(Node);
                            new_node.* = .line_break;
                            ctx.previous_node = new_node;
                            try heading.heading.children.append(arena, new_node);
                        },
                        else => {},
                    }
                }
            }

            return;
        }

        const line = if (raw_line[raw_line.len - 1] == '\r') raw_line[0 .. raw_line.len - 2] else raw_line;

        if (ctx.previous_node) |node| {
            switch (node.*) {
                .code_block => |*block| {
                    if (!block.closed) {
                        if (std.mem.allEqual(u8, line[Context.skipBlank(line)..], '`')) {
                            block.closed = true;
                            return;
                        }

                        try block.lines.append(arena, line);
                        return;
                    }
                },
                else => {},
            }
        }

        const skipped = skipBlank(line);
        const skipped_line = line[skipped..];

        switch (line[skipped]) {
            '#' => {
                var pos: usize = 1;
                var level: u8 = 1;
                while (skipped_line[pos] == '#') : (pos += 1) {
                    level += 1;
                }

                if (level > 6 or skipped_line[pos] != ' ') return ctx.appendTextNode(arena, skipped_line, options);
                pos += 1;

                return ctx.appendHeadingNode(arena, level, skipped_line[pos..], options);
            },
            '=' => {
                if (std.mem.allEqual(u8, skipped_line[1..], '=')) {
                    if (ctx.previous_node) |prev_node| switch (prev_node.*) {
                        .text => |copy| {
                            prev_node.* = .{
                                .heading = .{
                                    .id = null,
                                    .level = 1,
                                    .text = copy,
                                    .parent = ctx.previous_heading,
                                    .children = .empty,
                                },
                            };
                        },
                        else => return ctx.appendTextNode(arena, skipped_line, options),
                    };
                } else return ctx.appendTextNode(arena, skipped_line, options);
            },
            '-' => {
                if (skipped_line[1] == ' ') {
                    const is_task = skipped_line[2] == '[' and skipped_line[4] == ']' and skipped_line[5] == ' ';

                    return try ctx.appendListNode(
                        arena,
                        if (is_task) .{ .task = skipped_line[3] == 'x' } else .unordered,
                        skipped / 2,
                        if (is_task) skipped_line[6..] else skipped_line[2..],
                        options,
                    );
                } else if (std.mem.allEqual(u8, skipped_line[1..], '-')) {
                    if (ctx.previous_node) |prev_node| switch (prev_node.*) {
                        .text => |copy| {
                            prev_node.* = .{
                                .heading = .{
                                    .id = null,
                                    .level = 2,
                                    .text = copy,
                                    .parent = ctx.previous_heading,
                                    .children = .empty,
                                },
                            };
                        },
                        else => return ctx.appendHorizontalRule(arena),
                    } else {
                        return ctx.appendHorizontalRule(arena);
                    }
                } else return ctx.appendTextNode(arena, skipped_line, options);
            },
            '*', '_' => |c| {
                if (std.mem.allEqual(u8, skipped_line, c)) {
                    return ctx.appendHorizontalRule(arena);
                }
                return ctx.appendTextNode(arena, skipped_line, options);
            },
            '`' => {
                if (std.mem.startsWith(u8, skipped_line, "```")) {
                    return ctx.appendCodeBlock(arena, skipped, skipped_line[3..]);
                }
            },
            // '>' => {},
            // '|' => {},
            // '[' => {},
            '0'...'9' => {
                const num_len = blk: {
                    var i: usize = 1;
                    while (std.ascii.isDigit(skipped_line[i])) : (i += 1) {}
                    break :blk i;
                };

                if (skipped_line[num_len] == '.' and skipped_line[num_len + 1] == ' ') {
                    return try ctx.appendListNode(
                        arena,
                        .{ .ordered = std.fmt.parseInt(usize, skipped_line[0..num_len], 10) catch unreachable },
                        skipped / 2,
                        skipped_line[num_len + 1 ..],
                        options,
                    );
                } else {
                    return ctx.appendTextNode(arena, skipped_line, options);
                }
            },
            else => {
                return ctx.appendTextNode(arena, skipped_line, options);
            },
        }
    }
};
