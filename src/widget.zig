const dvui = @import("dvui");
const std = @import("std");

const Parser = @import("./Parser.zig");

const MarkdownWidget = @This();

pub const InitOptions = struct {
    /// Used for Code Block rendering
    tree_sitter: ?dvui.TextEntryWidget.InitOptions.TreeSitterOption = null,
    unordered_list_indicators: []const []const u8 = &.{ "•", "◦", "▪", "▫" },
    header_font_increment: [6]f32 = [_]f32{ 15, 12, 10, 8, 6, 3 },
    /// Follow pattern `a., b., c.` instead of `1., 2., 3.`.
    /// This also makes it so that custom initial numbers do not work
    ordered_list_alphabetic: bool = false,
    code_block: dvui.Options = .{},
    highlight_color: struct {
        background: dvui.Color = .yellow,
        text: dvui.Color = .black,
    } = .{},
    image: struct {
        size_limit: ?dvui.Size = null,
        manual_scale: bool = false,
        calculate_custom_scale: ?*const fn (image_size: dvui.Size) struct { min: ?dvui.Size, max: ?dvui.Size } = null,
    } = .{},
    get_image: *const fn (path_or_url: []const u8) dvui.Texture.ImageSource,
    /// This is for shortcodes such as `:joy:` not for `UTF-8` codes
    render_emoji: ?*const fn (tl: *dvui.TextLayoutWidget, shortcode: []const u8, option_stack: dvui.Options) void = null,
};

pub fn init(src: std.builtin.SourceLocation, arena: *std.heap.ArenaAllocator, file: []const u8, options: InitOptions) !void {
    var main_box = dvui.box(src, .{}, .{ .expand = .horizontal, .background = true, .padding = .all(9) });
    defer main_box.deinit();

    const graph_id = dvui.parentGet().extendId(src, 0);

    var graph = dvui.dataGet(null, graph_id, "__graph", []*Parser.Node);
    if (graph == null) {
        graph = try Parser.parse(arena.allocator(), file, .{});
        dvui.dataSet(null, graph_id, "__graph", graph.?);
    }

    try Renderer.init(arena.child_allocator, graph.?, options);
}

pub const Renderer = struct {
    index: usize = 0,
    current_layout: ?*dvui.TextLayoutWidget = null,
    graph: []*Parser.Node,

    pub fn init(gpa: std.mem.Allocator, graph: []*Parser.Node, options: InitOptions) !void {
        var renderer: Renderer = .{ .graph = graph };
        try renderer.render(gpa, options);
    }

    pub fn render(self: *Renderer, gpa: std.mem.Allocator, options: InitOptions) !void {
        try self.innerRender(gpa, self.graph, options);

        std.debug.assert(self.current_layout == null);
    }

    fn innerRender(
        self: *Renderer,
        gpa: std.mem.Allocator,
        graph: []*Parser.Node,
        options: InitOptions,
    ) !void {
        for (graph, 0..) |node, i| {
            switch (node.*) {
                .heading => |heading| {
                    self.deinitTextLayout();

                    var heading_box = dvui.box(@src(), .{}, .{ .expand = .horizontal, .id_extra = i });
                    defer heading_box.deinit();

                    self.renderHeading(heading.text, heading.level, options);
                    self.deinitTextLayout();
                    _ = dvui.spacer(@src(), .{ .min_size_content = .height(3), .background = true, .id_extra = i });

                    try self.innerRender(gpa, heading.children.items, options);
                    self.deinitTextLayout();
                },
                .code_block => |block| {
                    if (!block.closed) {
                        const tl = self.getTextLayout();
                        tl.format("```{s}", .{block.language}, .{});
                        for (block.lines.items) |line| {
                            tl.addText(line, .{});
                        }
                        continue;
                    }

                    self.deinitTextLayout();
                    const parent_rect = dvui.parentGet().data().rect;

                    var code_block = dvui.box(@src(), .{}, .{ .background = true, .gravity_x = 0.0001, .id_extra = i });
                    defer code_block.deinit();

                    const id = dvui.parentGet().extendId(@src(), 0);

                    var buffer = dvui.dataGet(null, id, "__buffer", []u8);
                    if (buffer == null) {
                        var arr: std.ArrayList(u8) = try .initCapacity(gpa, block.lines.items.len * 20);

                        for (block.lines.items) |line| {
                            try arr.appendSlice(gpa, line);
                            try arr.append(gpa, '\n');
                        }

                        _ = arr.pop();

                        buffer = try arr.toOwnedSlice(gpa);
                        dvui.dataSet(null, id, "buffer", buffer.?);
                    }

                    var te: dvui.TextEntryWidget = undefined;
                    te.init(@src(), .{
                        .multiline = true,
                        .text = .{ .buffer = buffer.? },
                        .tree_sitter = options.tree_sitter,
                    }, .{
                        .background = true,
                        .min_size_content = .width(parent_rect.w * 0.65),
                        .max_size_content = .width(parent_rect.w * 0.65),
                    });
                    te.textLayout.processEvents();
                    te.draw();
                    te.deinit();
                },
                .text => |sections| {
                    self.renderText(sections, options);
                },
                .horizontal_rule => {
                    self.deinitTextLayout();
                    const parent_rect = dvui.parentGet().data().rect;
                    const s: dvui.Size = .{ .h = 0, .w = parent_rect.w * 0.99 };
                    _ = dvui.spacer(@src(), .{
                        .min_size_content = s,
                        .max_size_content = .cast(s),
                        .id_extra = i,
                        .border = .all(0.5),
                        .gravity_x = 0.135,
                        .margin = .all(12),
                    });
                },
                .line_break => {
                    self.deinitTextLayout();
                    _ = dvui.spacer(@src(), .{ .min_size_content = .height(9), .id_extra = i });
                },
                .list => |list| {
                    self.renderList(list, 0, options);
                },
                .table => {},
                .block_quote => {},
                .footnote => {},
                .alert => {},
                .container => {},
            }
        }
    }

    fn renderList(self: *Renderer, list: std.ArrayList(*Parser.Node.Element), iter: usize, options: InitOptions) void {
        const tl = self.getTextLayout();

        var initial: usize = 0;
        for (list.items, 0..) |element, i| {
            switch (element.data) {
                .ordered => |num| {
                    if (initial == 0) initial = if (options.ordered_list_alphabetic) 'a' else @max(num, 1);
                    tl.format("{[e]c: >[i]}{[num]d}. ", .{ .e = ' ', .i = iter * 4, .num = initial + i }, .{});
                },
                .unordered => {
                    const indicator = options.unordered_list_indicators[iter % options.unordered_list_indicators.len];
                    tl.format("{[e]c: >[i]}{[indicator]s} ", .{ .e = ' ', .i = iter * 4, .indicator = indicator }, .{});
                },
                .task => |done| {
                    tl.format("{[e]c: >[i]} ", .{ .e = ' ', .i = iter * 4 }, .{});
                    var wdo: dvui.WidgetData = undefined;
                    checkbox(@src(), done, .{
                        .rect = .fromPoint(tl.insert_pt),
                        .data_out = &wdo,
                        .id_extra = i,
                        .margin = .all(0),
                        .padding = .all(0),
                    });
                    tl.insert_pt.x += wdo.rect.w + 7;
                },
            }

            iterateSections(tl, .{ .font = dvui.themeGet().font_body }, element.text, null, options);
            renderList(self, element.children, iter + 1, options);
        }
    }

    fn checkbox(src: std.builtin.SourceLocation, target: bool, opts: dvui.Options) void {
        const options = dvui.checkbox_defaults.themeOverride(opts.theme).override(opts);

        var b = dvui.box(src, .{ .dir = .horizontal }, options);
        defer b.deinit();

        dvui.tabIndexSet(b.data().id, b.data().options.tab_index, b.data().rectScale().r);

        const check_size = options.fontGet().textHeight() - 3.2;
        const s = dvui.spacer(src, .{ .min_size_content = .all(check_size), .gravity_y = 0.5 });

        const rs = s.borderRectScale();

        if (b.data().visible()) {
            dvui.checkmark(target, false, rs, false, false, options);
        }
    }

    fn deinitTextLayout(self: *Renderer) void {
        if (self.current_layout) |tl| tl.deinit();
        self.current_layout = null;
    }

    fn getTextLayout(self: *Renderer) *dvui.TextLayoutWidget {
        if (self.current_layout) |tl| {
            tl.addText("\n", .{});
            return tl;
        }

        defer self.index += 1;
        const tl = dvui.textLayout(@src(), .{}, .{ .id_extra = self.index, .expand = .horizontal });
        self.current_layout = tl;
        return tl;
    }

    fn renderHeading(self: *Renderer, sections: []Parser.Node.Section, heading_level: u8, options: InitOptions) void {
        const size = options.header_font_increment[heading_level - 1];
        const tl = self.getTextLayout();
        iterateSections(tl, .{ .font = dvui.themeGet().font_heading.larger(size).withWeight(.bold) }, sections, null, options);
    }

    fn renderText(self: *Renderer, sections: []Parser.Node.Section, options: InitOptions) void {
        const tl = self.getTextLayout();
        iterateSections(tl, .{ .font = dvui.themeGet().font_body }, sections, null, options);
    }

    fn iterateSections(
        tl: *dvui.TextLayoutWidget,
        dvui_opts: dvui.Options,
        sections: []Parser.Node.Section,
        url: ?[]const u8,
        options: InitOptions,
    ) void {
        for (sections) |section| {
            switch (section) {
                .default => |text| {
                    if (url) |u| tl.addLink(.{ .url = u, .text = text }, dvui_opts) else tl.addText(text, dvui_opts);
                },
                .bold => |sec| {
                    iterateSections(tl, dvui_opts.override(.{ .font = dvui_opts.font.?.withWeight(.bold) }), sec, url, options);
                },
                .italic => |sec| {
                    iterateSections(tl, dvui_opts.override(.{ .font = dvui_opts.font.?.withStyle(.italic) }), sec, url, options);
                },
                .bold_italic => |sec| {
                    iterateSections(tl, dvui_opts.override(.{ .font = dvui_opts.font.?.withWeight(.bold).withStyle(.italic) }), sec, url, options);
                },
                .underline => |sec| {
                    iterateSections(tl, dvui_opts.override(.{ .font = dvui_opts.font.?.withUnderline(.{}) }), sec, url, options);
                },
                .strike_through => |sec| {
                    iterateSections(tl, dvui_opts.override(.{ .font = dvui_opts.font.?.withStrike(.{}) }), sec, url, options);
                },
                .highlight => |sec| {
                    iterateSections(tl, dvui_opts.override(.{
                        .background = true,
                        .color_fill = options.highlight_color.background,
                        .color_text = options.highlight_color.text,
                    }), sec, url, options);
                },
                .code => |code| {
                    const opts = dvui_opts.override(.{
                        .background = true,
                        .border = .all(1),
                        .color_fill = .fromHex("#0e0e0e"),
                        .corner_radius = .all(1),
                    }).override(options.code_block);
                    if (url) |u| tl.addLink(.{ .url = u, .text = code }, opts) else tl.addText(code, opts);
                },
                .link => |link| {
                    iterateSections(tl, dvui_opts.override(.{ .font = dvui_opts.font.?.withUnderline(.{}) }), link.title, link.url, options);
                },
                .emoji_shortcode => |emoji| {
                    if (options.render_emoji) |render_fn| render_fn(tl, emoji, dvui_opts) else tl.format(":{s}:", .{emoji}, .{});
                },
                .image => |image| {
                    const parent_rect = dvui.parentGet().data().rect;
                    const image_source = options.get_image(image.path);

                    const image_size = dvui.imageSize(image_source) catch {
                        std.log.info("Image size could not be gathered, assuming default size", .{});
                        // TODO: Implement placeholder
                        return;
                    };

                    var image_options: dvui.Options = .{
                        .rect = .fromPoint(tl.insert_pt),
                        .expand = .ratio,
                        .label = .{ .text = image.hover_text },
                    };

                    if (options.image.calculate_custom_scale) |scale_fn| {
                        const res = scale_fn(image_size);
                        image_options.min_size_content = res.min;
                        image_options.max_size_content = .size(res.max);
                    } else if (options.image.size_limit) |max_size| {
                        if (options.image.manual_scale) {
                            const r = image_size.w / image_size.h;
                            const max_fit_w = @min(max_size.w, max_size.h * r);
                            const max_fit_h = @min(max_size.h, max_size.w / r);

                            const scale = @min(1.0, @min(max_fit_w / image_size.w, max_fit_h / image_size.h));
                            const dw = image_size.w * scale;
                            const dh = image_size.h * scale;

                            image_options.min_size_content = .{ .w = dw, .h = dh };
                            image_options.max_size_content = .{ .w = max_fit_w, .h = max_fit_h };
                        } else {
                            image_options.max_size_content = .size(max_size);
                        }
                    } else {
                        image_options.max_size_content = .width(parent_rect.w);
                    }

                    const wdo = dvui.image(@src(), .{ .source = image_source, .shrink = .ratio }, image_options);

                    dvui.log.info("Image Rect: {any}", .{wdo.rect});

                    tl.insert_pt.y += wdo.rect.h;
                    // TODO: Remove this when dvui fixes the issue
                    // Currently updating the cursor doesn't update `min_size`
                    tl.addText(" ", .{});
                },
                .subscript,
                .superscript,
                .typographic,
                => {},
            }
        }
    }
};
