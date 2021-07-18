// SPDX-FileCopyrightText: 2021 Yoran Heling <projects@yorhel.nl>
// SPDX-License-Identifier: MIT

const std = @import("std");
const main = @import("main.zig");
const model = @import("model.zig");
const scan = @import("scan.zig");
const delete = @import("delete.zig");
const ui = @import("ui.zig");
const c = @cImport(@cInclude("time.h"));
usingnamespace @import("util.zig");

// Currently opened directory and its parents.
pub var dir_parents = model.Parents{};

// Sorted list of all items in the currently opened directory.
// (first item may be null to indicate the "parent directory" item)
var dir_items = std.ArrayList(?*model.Entry).init(main.allocator);

var dir_max_blocks: u64 = 0;
var dir_max_size: u64 = 0;
var dir_has_shared: bool = false;

// Index into dir_items that is currently selected.
var cursor_idx: usize = 0;

const View = struct {
    // Index into dir_items, indicates which entry is displayed at the top of the view.
    // This is merely a suggestion, it will be adjusted upon drawing if it's
    // out of bounds or if the cursor is not otherwise visible.
    top: usize = 0,

    // The hash(name) of the selected entry (cursor), this is used to derive
    // cursor_idx after sorting or changing directory.
    // (collisions may cause the wrong entry to be selected, but dealing with
    // string allocations sucks and I expect collisions to be rare enough)
    cursor_hash: u64 = 0,

    fn hashEntry(entry: ?*model.Entry) u64 {
        return if (entry) |e| std.hash.Wyhash.hash(0, e.name()) else 0;
    }

    // Update cursor_hash and save the current view to the hash table.
    fn save(self: *@This()) void {
        self.cursor_hash = if (dir_items.items.len == 0) 0
                           else hashEntry(dir_items.items[cursor_idx]);
        opened_dir_views.put(@ptrToInt(dir_parents.top()), self.*) catch {};
    }

    // Should be called after dir_parents or dir_items has changed, will load the last saved view and find the proper cursor_idx.
    fn load(self: *@This(), sel: ?*const model.Entry) void {
        if (opened_dir_views.get(@ptrToInt(dir_parents.top()))) |v| self.* = v
        else self.* = @This(){};
        cursor_idx = 0;
        for (dir_items.items) |e, i| {
            if (if (sel != null) e == sel else self.cursor_hash == hashEntry(e)) {
                cursor_idx = i;
                break;
            }
        }
    }
};

var current_view = View{};

// Directories the user has browsed to before, and which item was last selected.
// The key is the @ptrToInt() of the opened *Dir; An int because the pointer
// itself may have gone stale after deletion or refreshing. They're only for
// lookups, not dereferencing.
var opened_dir_views = std.AutoHashMap(usize, View).init(main.allocator);

fn sortIntLt(a: anytype, b: @TypeOf(a)) ?bool {
    return if (a == b) null else if (main.config.sort_order == .asc) a < b else a > b;
}

fn sortLt(_: void, ap: ?*model.Entry, bp: ?*model.Entry) bool {
    const a = ap.?;
    const b = bp.?;

    if (main.config.sort_dirsfirst and a.isDirectory() != b.isDirectory())
        return a.isDirectory();

    switch (main.config.sort_col) {
        .name => {}, // name sorting is the fallback
        .blocks => {
            if (sortIntLt(a.blocks, b.blocks)) |r| return r;
            if (sortIntLt(a.size, b.size)) |r| return r;
        },
        .size => {
            if (sortIntLt(a.size, b.size)) |r| return r;
            if (sortIntLt(a.blocks, b.blocks)) |r| return r;
        },
        .items => {
            const ai = if (a.dir()) |d| d.items else 0;
            const bi = if (b.dir()) |d| d.items else 0;
            if (sortIntLt(ai, bi)) |r| return r;
            if (sortIntLt(a.blocks, b.blocks)) |r| return r;
            if (sortIntLt(a.size, b.size)) |r| return r;
        },
        .mtime => {
            if (!a.isext or !b.isext) return a.isext;
            if (sortIntLt(a.ext().?.mtime, b.ext().?.mtime)) |r| return r;
        },
    }

    // TODO: Unicode-aware sorting might be nice (and slow)
    const an = a.name();
    const bn = b.name();
    return if (main.config.sort_order == .asc) std.mem.lessThan(u8, an, bn)
           else std.mem.lessThan(u8, bn, an);
}

// Should be called when:
// - config.sort_* changes
// - dir_items changes (i.e. from loadDir())
// - files in this dir have changed in a way that affects their ordering
fn sortDir(next_sel: ?*const model.Entry) void {
    // No need to sort the first item if that's the parent dir reference,
    // excluding that allows sortLt() to ignore null values.
    const lst = dir_items.items[(if (dir_items.items.len > 0 and dir_items.items[0] == null) @as(usize, 1) else 0)..];
    std.sort.sort(?*model.Entry, lst, @as(void, undefined), sortLt);
    current_view.load(next_sel);
}

// Must be called when:
// - dir_parents changes (i.e. we change directory)
// - config.show_hidden changes
// - files in this dir have been added or removed
pub fn loadDir(next_sel: ?*const model.Entry) void {
    dir_items.shrinkRetainingCapacity(0);
    dir_max_size = 1;
    dir_max_blocks = 1;
    dir_has_shared = false;

    if (!dir_parents.isRoot())
        dir_items.append(null) catch unreachable;
    var it = dir_parents.top().sub;
    while (it) |e| {
        if (e.blocks > dir_max_blocks) dir_max_blocks = e.blocks;
        if (e.size > dir_max_size) dir_max_size = e.size;
        const shown = main.config.show_hidden or blk: {
            const excl = if (e.file()) |f| f.excluded else false;
            const name = e.name();
            break :blk !excl and name[0] != '.' and name[name.len-1] != '~';
        };
        if (shown) {
            dir_items.append(e) catch unreachable;
            if (e.dir()) |d| if (d.shared_blocks > 0 or d.shared_size > 0) { dir_has_shared = true; };
        }
        it = e.next;
    }
    sortDir(next_sel);
}

const Row = struct {
    row: u32,
    col: u32 = 0,
    bg: ui.Bg = .default,
    item: ?*model.Entry,

    const Self = @This();

    fn flag(self: *Self) void {
        defer self.col += 2;
        const item = self.item orelse return;
        const ch: u7 = ch: {
            if (item.file()) |f| {
                if (f.err) break :ch '!';
                if (f.excluded) break :ch '<';
                if (f.other_fs) break :ch '>';
                if (f.kernfs) break :ch '^';
                if (f.notreg) break :ch '@';
            } else if (item.dir()) |d| {
                if (d.err) break :ch '!';
                if (d.suberr) break :ch '.';
                if (d.sub == null) break :ch 'e';
            } else if (item.link()) |_| break :ch 'H';
            return;
        };
        ui.move(self.row, self.col);
        self.bg.fg(.flag);
        ui.addch(ch);
    }

    fn size(self: *Self) void {
        var width = if (main.config.si) @as(u32, 9) else 10;
        if (dir_has_shared and main.config.show_shared != .off)
            width += 2 + width;
        defer self.col += width;
        const item = self.item orelse return;
        const siz = if (main.config.show_blocks) blocksToSize(item.blocks) else item.size;
        var shr = if (item.dir()) |d| (if (main.config.show_blocks) blocksToSize(d.shared_blocks) else d.shared_size) else 0;
        if (main.config.show_shared == .unique) shr = saturateSub(siz, shr);

        ui.move(self.row, self.col);
        ui.addsize(self.bg, siz);
        if (shr > 0 and main.config.show_shared != .off) {
            self.bg.fg(.flag);
            ui.addstr(if (main.config.show_shared == .unique) " U " else " S ");
            ui.addsize(self.bg, shr);
        }
    }

    fn graph(self: *Self) void {
        if (main.config.show_graph == .off or self.col + 20 > ui.cols) return;

        const bar_size = std.math.max(ui.cols/7, 10);
        defer self.col += switch (main.config.show_graph) {
            .off => unreachable,
            .graph => bar_size + 3,
            .percent => 9,
            .both => bar_size + 10,
        };
        const item = self.item orelse return;

        ui.move(self.row, self.col);
        self.bg.fg(.default);
        ui.addch('[');
        if (main.config.show_graph == .both or main.config.show_graph == .percent) {
            self.bg.fg(.num);
            ui.addprint("{d:>5.1}", .{ 100*
                if (main.config.show_blocks) @intToFloat(f32, item.blocks) / @intToFloat(f32, std.math.max(1, dir_parents.top().entry.blocks))
                else                         @intToFloat(f32, item.size)   / @intToFloat(f32, std.math.max(1, dir_parents.top().entry.size))
            });
            self.bg.fg(.default);
            ui.addch('%');
        }
        if (main.config.show_graph == .both) ui.addch(' ');
        if (main.config.show_graph == .both or main.config.show_graph == .graph) {
            const perblock = std.math.divFloor(u64, if (main.config.show_blocks) dir_max_blocks else dir_max_size, bar_size) catch unreachable;
            const num = if (main.config.show_blocks) item.blocks else item.size;
            var i: u32 = 0;
            var siz: u64 = 0;
            self.bg.fg(.graph);
            while (i < bar_size) : (i += 1) {
                siz = saturateAdd(siz, perblock);
                ui.addch(if (siz <= num) '#' else ' ');
            }
        }
        self.bg.fg(.default);
        ui.addch(']');
    }

    fn items(self: *Self) void {
        if (!main.config.show_items or self.col + 10 > ui.cols) return;
        defer self.col += 7;
        const n = (if (self.item) |d| d.dir() orelse return else return).items;
        ui.move(self.row, self.col);
        self.bg.fg(.num);
        if (n < 1000)
            ui.addprint("  {d:>4}", .{n})
        else if (n < 10_000) {
            ui.addch(' ');
            ui.addnum(self.bg, n);
        } else if (n < 100_000)
            ui.addnum(self.bg, n)
        else if (n < 1000_000) {
            ui.addprint("{d:>5.1}", .{ @intToFloat(f32, n) / 1000 });
            self.bg.fg(.default);
            ui.addch('k');
        } else if (n < 1000_000_000) {
            ui.addprint("{d:>5.1}", .{ @intToFloat(f32, n) / 1000_000 });
            self.bg.fg(.default);
            ui.addch('M');
        } else {
            self.bg.fg(.default);
            ui.addstr("  > ");
            self.bg.fg(.num);
            ui.addch('1');
            self.bg.fg(.default);
            ui.addch('G');
        }
    }

    fn mtime(self: *Self) void {
        if (!main.config.show_mtime or self.col + 37 > ui.cols) return;
        defer self.col += 27;
        ui.move(self.row, self.col+1);
        const ext = (if (self.item) |e| e.ext() else @as(?*model.Ext, null)) orelse dir_parents.top().entry.ext();
        if (ext) |e| ui.addts(self.bg, e.mtime)
        else ui.addstr("                 no mtime");
    }

    fn name(self: *Self) void {
        ui.move(self.row, self.col);
        if (self.item) |i| {
            self.bg.fg(if (i.etype == .dir) .dir else .default);
            ui.addch(if (i.isDirectory()) '/' else ' ');
            ui.addstr(ui.shorten(ui.toUtf8(i.name()), saturateSub(ui.cols, self.col + 1)));
        } else {
            self.bg.fg(.dir);
            ui.addstr("/..");
        }
    }

    fn draw(self: *Self) void {
        if (self.bg == .sel) {
            self.bg.fg(.default);
            ui.move(self.row, 0);
            ui.hline(' ', ui.cols);
        }
        self.flag();
        self.size();
        self.graph();
        self.items();
        self.mtime();
        self.name();
    }
};

var state: enum { main, quit, info } = .main;
var message: ?[:0]const u8 = null;

const quit = struct {
    fn draw() void {
        const box = ui.Box.create(4, 22, "Confirm quit");
        box.move(2, 2);
        ui.addstr("Really quit? (");
        ui.style(.key);
        ui.addch('y');
        ui.style(.default);
        ui.addch('/');
        ui.style(.key);
        ui.addch('N');
        ui.style(.default);
        ui.addch(')');
    }

    fn keyInput(ch: i32) void {
        switch (ch) {
            'y', 'Y' => ui.quit(),
            else => state = .main,
        }
    }
};

const info = struct {
    const Tab = enum { info, links };

    var tab: Tab = .info;
    var entry: ?*model.Entry = null;
    var links: ?model.LinkPaths = null;
    var links_top: usize = 0;
    var links_idx: usize = 0;

    // Set the displayed entry to the currently selected item and open the tab.
    fn set(e: ?*model.Entry, t: Tab) void {
        if (e != entry) {
            if (links) |*l| l.deinit();
            links = null;
            links_top = 0;
            links_idx = 0;
        }
        entry = e;
        if (e == null) {
            state = .main;
            return;
        }
        state = .info;
        tab = t;
        if (tab == .links and links == null) {
            links = model.LinkPaths.find(&dir_parents, e.?.link().?);
            for (links.?.paths.items) |n,i| {
                if (&n.node.entry == e) {
                    links_idx = i;
                }
            }
        }
    }

    fn drawLinks(box: ui.Box, row: *u32, rows: u32, cols: u32) void {
        var pathbuf = std.ArrayList(u8).init(main.allocator);

        const numrows = saturateSub(rows, 4);
        if (links_idx < links_top) links_top = links_idx;
        if (links_idx >= links_top + numrows) links_top = links_idx - numrows + 1;

        var i: u32 = 0;
        while (i < numrows) : (i += 1) {
            if (i + links_top >= links.?.paths.items.len) break;
            const e = links.?.paths.items[i+links_top];
            ui.style(if (i+links_top == links_idx) .sel else .default);
            box.move(row.*, 2);
            ui.addch(if (&e.node.entry == entry) '*' else ' ');
            pathbuf.shrinkRetainingCapacity(0);
            e.fmtPath(false, &pathbuf);
            ui.addstr(ui.shorten(ui.toUtf8(arrayListBufZ(&pathbuf)), saturateSub(cols, 5)));
            row.* += 1;
        }
        ui.style(.default);
        box.move(rows-2, 4);
        ui.addprint("{:>3}/{}", .{ links_idx+1, links.?.paths.items.len });
        pathbuf.deinit();
    }

    fn drawSizeRow(box: ui.Box, row: *u32, label: [:0]const u8, size: u64) void {
        box.move(row.*, 3);
        ui.addstr(label);
        ui.addsize(.default, size);
        ui.addstr(" (");
        ui.addnum(.default, size);
        ui.addch(')');
        row.* += 1;
    }

    fn drawSize(box: ui.Box, row: *u32, label: [:0]const u8, size: u64, shared: u64) void {
        ui.style(.bold);
        drawSizeRow(box, row, label, size);
        if (shared > 0) {
            ui.style(.default);
            drawSizeRow(box, row, "     > shared: ", shared);
            drawSizeRow(box, row, "     > unique: ", saturateSub(size, shared));
        }
    }

    fn drawInfo(box: ui.Box, row: *u32, cols: u32, e: *model.Entry) void {
        // Name
        box.move(row.*, 3);
        ui.style(.bold);
        ui.addstr("Name: ");
        ui.style(.default);
        ui.addstr(ui.shorten(ui.toUtf8(e.name()), cols-11));
        row.* += 1;

        // Type / Mode+UID+GID
        box.move(row.*, 3);
        ui.style(.bold);
        if (e.ext()) |ext| {
            ui.addstr("Mode: ");
            ui.style(.default);
            ui.addmode(ext.mode);
            var buf: [32]u8 = undefined;
            ui.style(.bold);
            ui.addstr("  UID: ");
            ui.style(.default);
            ui.addstr(std.fmt.bufPrintZ(&buf, "{d:<6}", .{ ext.uid }) catch unreachable);
            ui.style(.bold);
            ui.addstr(" GID: ");
            ui.style(.default);
            ui.addstr(std.fmt.bufPrintZ(&buf, "{d:<6}", .{ ext.gid }) catch unreachable);
        } else {
            ui.addstr("Type: ");
            ui.style(.default);
            ui.addstr(if (e.isDirectory()) "Directory" else if (if (e.file()) |f| f.notreg else false) "Other" else "File");
        }
        row.* += 1;

        // Last modified
        if (e.ext()) |ext| {
            box.move(row.*, 3);
            ui.style(.bold);
            ui.addstr("Last modified: ");
            ui.addts(.default, ext.mtime);
            row.* += 1;
        }

        // Disk usage & Apparent size
        drawSize(box, row, "   Disk usage: ", blocksToSize(e.blocks), if (e.dir()) |d| blocksToSize(d.shared_blocks) else 0);
        drawSize(box, row, "Apparent size: ", e.size,                 if (e.dir()) |d| d.shared_size                 else 0);

        // Number of items
        if (e.dir()) |d| {
            box.move(row.*, 3);
            ui.style(.bold);
            ui.addstr("    Sub items: ");
            ui.addnum(.default, d.items);
            row.* += 1;
        }

        // Number of links + inode (dev?)
        if (e.link()) |l| {
            box.move(row.*, 3);
            ui.style(.bold);
            ui.addstr("   Link count: ");
            ui.addnum(.default, l.nlink);
            box.move(row.*, 23);
            ui.style(.bold);
            ui.addstr("  Inode: ");
            ui.style(.default);
            var buf: [32]u8 = undefined;
            ui.addstr(std.fmt.bufPrintZ(&buf, "{}", .{ l.ino }) catch unreachable);
            row.* += 1;
        }
    }

    fn draw() void {
        const e = dir_items.items[cursor_idx].?;
        // XXX: The dynamic height is a bit jarring, especially when that
        // causes the same lines of information to be placed on different rows
        // for each item. Think it's better to have a dynamic height based on
        // terminal size and scroll if the content doesn't fit.
        const rows = 5 // border + padding + close message
            + if (tab == .links) 8 else
              4 // name + type + disk usage + apparent size
            + (if (e.ext() != null) @as(u32, 1) else 0) // last modified
            + (if (e.link() != null) @as(u32, 1) else 0) // link count
            + (if (e.dir()) |d| 1 // sub items
                    + (if (d.shared_size > 0) @as(u32, 2) else 0)
                    + (if (d.shared_blocks > 0) @as(u32, 2) else 0)
                else 0);
        const cols = 60; // TODO: dynamic width?
        const box = ui.Box.create(rows, cols, "Item info");
        var row: u32 = 2;

        // Tabs
        if (e.etype == .link) {
            box.tab(cols-19, tab == .info, 1, "Info");
            box.tab(cols-10, tab == .links, 2, "Links");
        }

        switch (tab) {
            .info => drawInfo(box, &row, cols, e),
            .links => drawLinks(box, &row, rows, cols),
        }

        // "Press i to close this window"
        box.move(rows-2, cols-30);
        ui.style(.default);
        ui.addstr("Press ");
        ui.style(.key);
        ui.addch('i');
        ui.style(.default);
        ui.addstr(" to close this window");
    }

    fn keyInput(ch: i32) bool {
        if (entry.?.etype == .link) {
            switch (ch) {
                '1', 'h', ui.c.KEY_LEFT => { set(entry, .info); return true; },
                '2', 'l', ui.c.KEY_RIGHT => { set(entry, .links); return true; },
                else => {},
            }
        }
        if (tab == .links) {
            if (keyInputSelection(ch, &links_idx, links.?.paths.items.len, 5))
                return true;
            if (ch == 10) { // Enter - go to selected entry
                const p = links.?.paths.items[links_idx];
                dir_parents.stack.shrinkRetainingCapacity(0);
                dir_parents.stack.appendSlice(p.path.stack.items) catch unreachable;
                loadDir(&p.node.entry);
                set(null, .info);
            }
        }
        if (keyInputSelection(ch, &cursor_idx, dir_items.items.len, saturateSub(ui.rows, 3))) {
            set(dir_items.items[cursor_idx], .info);
            return true;
        }
        switch (ch) {
            'i', 'q' => set(null, .info),
            else => return false,
        }
        return true;
    }
};

pub fn draw() void {
    ui.style(.hd);
    ui.move(0,0);
    ui.hline(' ', ui.cols);
    ui.move(0,0);
    ui.addstr("ncdu " ++ main.program_version ++ " ~ Use the arrow keys to navigate, press ");
    ui.style(.key_hd);
    ui.addch('?');
    ui.style(.hd);
    ui.addstr(" for help");
    if (main.config.imported) {
        ui.move(0, saturateSub(ui.cols, 10));
        ui.addstr("[imported]");
    } else if (main.config.read_only) {
        ui.move(0, saturateSub(ui.cols, 10));
        ui.addstr("[readonly]");
    }

    ui.style(.default);
    ui.move(1,0);
    ui.hline('-', ui.cols);
    ui.move(1,3);
    ui.addch(' ');
    ui.style(.dir);

    var pathbuf = std.ArrayList(u8).init(main.allocator);
    dir_parents.fmtPath(true, &pathbuf);
    ui.addstr(ui.shorten(ui.toUtf8(arrayListBufZ(&pathbuf)), saturateSub(ui.cols, 5)));
    pathbuf.deinit();

    ui.style(.default);
    ui.addch(' ');

    const numrows = saturateSub(ui.rows, 3);
    if (cursor_idx < current_view.top) current_view.top = cursor_idx;
    if (cursor_idx >= current_view.top + numrows) current_view.top = cursor_idx - numrows + 1;

    var i: u32 = 0;
    var sel_row: u32 = 0;
    while (i < numrows) : (i += 1) {
        if (i+current_view.top >= dir_items.items.len) break;
        var row = Row{
            .row = i+2,
            .item = dir_items.items[i+current_view.top],
            .bg = if (i+current_view.top == cursor_idx) .sel else .default,
        };
        if (row.bg == .sel) sel_row = i+2;
        row.draw();
    }

    ui.style(.hd);
    ui.move(ui.rows-1, 0);
    ui.hline(' ', ui.cols);
    ui.move(ui.rows-1, 1);
    ui.style(if (main.config.show_blocks) .bold_hd else .hd);
    ui.addstr("Total disk usage: ");
    ui.addsize(.hd, blocksToSize(dir_parents.top().entry.blocks));
    ui.style(if (main.config.show_blocks) .hd else .bold_hd);
    ui.addstr("  Apparent size: ");
    ui.addsize(.hd, dir_parents.top().entry.size);
    ui.addstr("  Items: ");
    ui.addnum(.hd, dir_parents.top().items);

    switch (state) {
        .main => {},
        .quit => quit.draw(),
        .info => info.draw(),
    }
    if (message) |m| {
        const box = ui.Box.create(6, 60, "Message");
        box.move(2, 2);
        ui.addstr(m);
        box.move(4, 33);
        ui.addstr("Press any key to continue");
    }
    if (sel_row > 0) ui.move(sel_row, 0);
}

fn sortToggle(col: main.config.SortCol, default_order: main.config.SortOrder) void {
    if (main.config.sort_col != col) main.config.sort_order = default_order
    else if (main.config.sort_order == .asc) main.config.sort_order = .desc
    else main.config.sort_order = .asc;
    main.config.sort_col = col;
    sortDir(null);
}

fn keyInputSelection(ch: i32, idx: *usize, len: usize, page: u32) bool {
    switch (ch) {
        'j', ui.c.KEY_DOWN => {
            if (idx.*+1 < len) idx.* += 1;
        },
        'k', ui.c.KEY_UP => {
            if (idx.* > 0) idx.* -= 1;
        },
        ui.c.KEY_HOME => idx.* = 0,
        ui.c.KEY_END, ui.c.KEY_LL => idx.* = saturateSub(len, 1),
        ui.c.KEY_PPAGE => idx.* = saturateSub(idx.*, page),
        ui.c.KEY_NPAGE => idx.* = std.math.min(saturateSub(len, 1), idx.* + page),
        else => return false,
    }
    return true;
}

pub fn keyInput(ch: i32) void {
    defer current_view.save();

    if (message != null) {
        message = null;
        return;
    }

    switch (state) {
        .main => {}, // fallthrough
        .quit => return quit.keyInput(ch),
        .info => if (info.keyInput(ch)) return,
    }

    switch (ch) {
        'q' => if (main.config.confirm_quit) { state = .quit; } else ui.quit(),
        'i' => if (dir_items.items.len > 0) info.set(dir_items.items[cursor_idx], .info),
        'r' => {
            if (main.config.imported)
                message = "Directory imported from file, refreshing is disabled."
            else {
                main.state = .refresh;
                scan.setupRefresh(dir_parents.copy());
            }
        },
        'b' => {
            if (main.config.imported)
                message = "Shell feature not available for imported directories."
            else if (!main.config.can_shell)
                message = "Shell feature disabled in read-only mode."
            else
                main.state = .shell;
        },
        'd' => {
            if (dir_items.items.len == 0) {
            } else if (main.config.imported)
                message = "Deletion feature not available for imported directories."
            else if (main.config.read_only)
                message = "Deletion feature disabled in read-only mode."
            else if (dir_items.items[cursor_idx]) |e| {
                main.state = .delete;
                const next =
                    if (cursor_idx+1 < dir_items.items.len) dir_items.items[cursor_idx+1]
                    else if (cursor_idx == 0) null
                    else dir_items.items[cursor_idx-1];
                delete.setup(dir_parents.copy(), e, next);
            }
        },

        // Sort & filter settings
        'n' => sortToggle(.name, .asc),
        's' => sortToggle(if (main.config.show_blocks) .blocks else .size, .desc),
        'C' => sortToggle(.items, .desc),
        'M' => if (main.config.extended) sortToggle(.mtime, .desc),
        'e' => {
            main.config.show_hidden = !main.config.show_hidden;
            loadDir(null);
            state = .main;
        },
        't' => {
            main.config.sort_dirsfirst = !main.config.sort_dirsfirst;
            sortDir(null);
        },
        'a' => {
            main.config.show_blocks = !main.config.show_blocks;
            if (main.config.show_blocks and main.config.sort_col == .size) {
                main.config.sort_col = .blocks;
                sortDir(null);
            }
            if (!main.config.show_blocks and main.config.sort_col == .blocks) {
                main.config.sort_col = .size;
                sortDir(null);
            }
        },

        // Navigation
        10, 'l', ui.c.KEY_RIGHT => {
            if (dir_items.items.len == 0) {
            } else if (dir_items.items[cursor_idx]) |e| {
                if (e.dir()) |d| {
                    dir_parents.push(d);
                    loadDir(null);
                    state = .main;
                }
            } else if (!dir_parents.isRoot()) {
                dir_parents.pop();
                loadDir(null);
                state = .main;
            }
        },
        'h', '<', ui.c.KEY_BACKSPACE, ui.c.KEY_LEFT => {
            if (!dir_parents.isRoot()) {
                const e = dir_parents.top();
                dir_parents.pop();
                loadDir(&e.entry);
                state = .main;
            }
        },

        // Display settings
        'c' => main.config.show_items = !main.config.show_items,
        'm' => if (main.config.extended) { main.config.show_mtime = !main.config.show_mtime; },
        'g' => main.config.show_graph = switch (main.config.show_graph) {
            .off => .graph,
            .graph => .percent,
            .percent => .both,
            .both => .off,
        },
        // TODO: This key binding is not final! I'd rather add a menu selection thing for advanced settings rather than risk running out of more keys.
        'u' => main.config.show_shared = switch (main.config.show_shared) {
            .off => .shared,
            .shared => .unique,
            .unique => .off,
        },

        else => _ = keyInputSelection(ch, &cursor_idx, dir_items.items.len, saturateSub(ui.rows, 3)),
    }
}