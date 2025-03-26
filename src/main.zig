const builtin = @import("builtin");
const std = @import("std");
const wl = @import("wayland.zig").WaylandClient(App);

/// The main entrypoint to the entire program!
pub fn main() !void {
    var gpalloc = std.heap.GeneralPurposeAllocator(.{
        .safety = true,
    }).init;
    const allocator = gpalloc.allocator();

    var app: App = undefined;
    try app.init(allocator);

    try app.runLoop();

    app.deinit();

    std.log.info("Were there memory leaks: {}", .{gpalloc.deinit()});
}

const App = struct {
    running: bool = true,
    allocator: std.mem.Allocator,

    client: *wl.Client,
    compositor: *wl.Compositor,
    shm: *wl.Shm,
    xdg_base: *wl.XdgWmBase,
    xdg_decoration_manager: ?*wl.XdgDecorationManager,

    shm_pool: *wl.ShmPool,
    buffer: *wl.Buffer,
    surface: *wl.Surface,
    xdg_surface: *wl.XdgSurface,
    toplevel: *wl.XdgToplevel,
    xdg_toplevel_decoration: ?*wl.XdgToplevedDecoration,

    fn init(a: *App, allocator: std.mem.Allocator) !void {
        a.running = true;
        a.allocator = allocator;
        a.client = try wl.Client.init(allocator, a);
        errdefer a.client.deinit();
        try a.client.sync();

        a.compositor = try wl.Compositor.init(a.client);
        errdefer a.compositor.deinit();

        a.shm = try wl.Shm.create(a.client);
        errdefer a.shm.release();

        a.xdg_base = try wl.XdgWmBase.init(a.client);
        errdefer a.xdg_base.destroy();

        a.xdg_decoration_manager = wl.XdgDecorationManager.create(a.client) catch null;
        errdefer if (a.xdg_decoration_manager) |dm| dm.destroy();

        a.shm_pool = try a.shm.createPool(300 * 300 * 4);
        errdefer a.shm_pool.destroy();

        a.buffer = try a.shm_pool.createBuffer(
            0,
            300,
            300,
            300 * 4,
            .xrgb8888,
        );
        errdefer a.buffer.destroy();

        a.surface = try a.compositor.createSurface();
        errdefer a.surface.destroy();

        a.xdg_surface = try a.xdg_base.getXdgSurface(a.surface);
        errdefer a.xdg_surface.destroy();
        a.xdg_surface.configureHandler = &handleSurfaceConfigure;

        a.toplevel = try a.xdg_surface.getToplevel();
        errdefer a.toplevel.destroy();

        try a.toplevel.setTitle("Hello Ziggity");
        try a.toplevel.setMaxSize(300, 300);
        try a.toplevel.setMinSize(300, 300);
        a.toplevel.closeHandler = &handleClose;

        if (a.xdg_decoration_manager) |dm|
            a.xdg_toplevel_decoration = try dm.getToplevelDecoration(a.toplevel);
        errdefer if (a.xdg_toplevel_decoration) |tld|
            tld.destroy();
        if (a.xdg_toplevel_decoration) |tld| {
            try tld.setMode(.server_side);
        }

        try a.client.sync();

        try a.surface.commit();
        try a.surface.attach(a.buffer, 0, 0);
    }

    fn deinit(a: *App) void {
        if (a.xdg_toplevel_decoration) |tld| tld.destroy();
        a.toplevel.destroy();
        a.xdg_surface.destroy();
        a.surface.destroy();
        a.buffer.destroy();
        a.shm_pool.destroy();

        if (a.xdg_decoration_manager) |dm| dm.destroy();
        a.xdg_base.destroy();
        a.shm.release();
        a.compositor.deinit();
        a.client.deinit();
    }

    fn handleSurfaceConfigure(a: *App) !void {
        try a.surface.commit();
    }

    fn handleClose(a: *App) void {
        a.running = false;
    }

    fn runLoop(a: *App) !void {
        while (a.running) {
            try a.client.read();
        }
    }
};
