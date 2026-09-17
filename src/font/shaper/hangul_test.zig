const std = @import("std");
const font = @import("../main.zig");
const terminal = @import("../../terminal/main.zig");

test "shape Hangul with a composed-only face" {
    try testHangul(font.embedded.hangul_test, false, true, null);
}

test "shape Hangul with jamo coverage and style fallback" {
    for ([_]bool{ true, false }) |complete_styles| {
        try testHangul(font.embedded.hangul_jamo_test, true, complete_styles, null);
    }
}

test "shape Hangul when styles have different jamo coverage" {
    try testHangul(font.embedded.hangul_test, false, true, font.embedded.hangul_jamo_test);
}

fn testHangul(
    data: [:0]const u8,
    has_jamo: bool,
    complete_styles: bool,
    bold_data: ?[:0]const u8,
) !void {
    const testing = std.testing;
    const alloc = testing.allocator;

    var lib = try font.Library.init(alloc);
    defer lib.deinit();
    var collection = font.Collection.init();
    collection.load_options = .{ .library = lib };
    const regular = try collection.add(alloc, try font.Face.init(
        lib,
        data,
        .{ .size = .{ .points = 12 } },
    ), .{ .style = .regular, .fallback = false, .size_adjustment = .none });
    if (bold_data) |bytes| {
        _ = try collection.add(alloc, try font.Face.init(
            lib,
            bytes,
            .{ .size = .{ .points = 12 } },
        ), .{ .style = .bold, .fallback = false, .size_adjustment = .none });
    }
    // Without a bold face, bold text must use the resolver's regular fallback.
    if (complete_styles) try collection.completeStyles(alloc, .{});
    var grid = try font.SharedGrid.init(alloc, .{ .collection = collection });
    defer grid.deinit(alloc);
    var shaper = try font.Shaper.init(alloc, .{});
    defer shaper.deinit();

    // Bundled fixtures make both coverage cases independent of installed fonts.
    for ([_]u32{ 0xBB34, 0xC81C, 0xD55C, 0xBC95 }) |cp| {
        try testing.expect(grid.hasCodepoint(regular, cp, null));
    }
    for ([_]u32{ 0x1106, 0x116E, 0x110C, 0x1166, 0x1112, 0x1161, 0x11AB }) |cp| {
        try testing.expectEqual(has_jamo, grid.hasCodepoint(regular, cp, null));
    }

    const cases = [_]struct { input: []const u8, composed: []const u8 }{
        // The reported filename, surrounded by Latin characters.
        .{ .input = "A\u{1106}\u{116E}\u{110C}\u{1166}.md", .composed = "A무제.md" },
        .{ .input = "A무제.md", .composed = "A무제.md" },
        // L+V+T and the partially composed LV+T form.
        .{ .input = "\u{1112}\u{1161}\u{11AB}\u{1107}\u{1165}\u{11B8}", .composed = "한법" },
        .{ .input = "\u{D558}\u{11AB}\u{BC84}\u{11B8}", .composed = "한법" },
    };
    for ([_]bool{ false, true }) |bold| {
        for ([_]?usize{ null, 3 }) |cursor_x| {
            for (cases) |case| {
                var t = try terminal.Terminal.init(testing.io, alloc, .{ .cols = 20, .rows = 3 });
                defer t.deinit(alloc);
                var stream = t.vtStream();
                defer stream.deinit();
                if (bold) stream.nextSlice("\x1b[1m");
                stream.nextSlice(case.input);

                var state: terminal.RenderState = .empty;
                defer state.deinit(alloc);
                try state.update(alloc, &t);
                const cells = state.row_data.get(0).cells.slice();

                var expected = (try std.unicode.Utf8View.init(case.composed)).iterator();
                var expected_x: u16 = 0;
                var it = shaper.runIterator(.{ .grid = &grid, .cells = cells, .cursor_x = cursor_x });
                while (try it.next(alloc)) |run| {
                    try testing.expect(run.font_index.special() == null);
                    try testing.expectEqual(
                        if (bold and complete_styles) font.Style.bold else font.Style.regular,
                        run.font_index.style,
                    );
                    const face = try grid.resolver.collection.getFace(run.font_index);
                    for (try shaper.shape(run)) |cell| {
                        const cp = expected.nextCodepoint() orelse return error.UnexpectedGlyph;
                        try testing.expectEqual(expected_x, run.offset + cell.x);
                        try testing.expectEqual(face.glyphIndex(cp).?, cell.glyph_index);
                        expected_x += if (cp >= 0xAC00 and cp <= 0xD7A3) @as(u16, 2) else 1;
                    }
                }
                try testing.expect(expected.nextCodepoint() == null);
                try testing.expectEqual(expected_x, t.screens.active.cursor.x);

                // The rendering transform must preserve the stored spelling
                // used by selection/copy, including decomposed filename bytes.
                var stored: std.ArrayList(u8) = .empty;
                defer stored.deinit(alloc);
                for (cells.items(.raw), cells.items(.grapheme)) |cell, rest| {
                    switch (cell.wide) {
                        .spacer_head, .spacer_tail => continue,
                        else => {},
                    }
                    if (cell.codepoint() == 0) continue;
                    try appendUtf8(alloc, &stored, cell.codepoint());
                    if (cell.hasGrapheme()) {
                        for (rest) |cp| try appendUtf8(alloc, &stored, cp);
                    }
                }
                try testing.expectEqualStrings(case.input, stored.items);
            }
        }
    }
}

fn appendUtf8(alloc: std.mem.Allocator, buf: *std.ArrayList(u8), cp: u21) !void {
    var bytes: [4]u8 = undefined;
    const len = try std.unicode.utf8Encode(cp, &bytes);
    try buf.appendSlice(alloc, bytes[0..len]);
}
