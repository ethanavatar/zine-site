const std  = @import("std");
const zine = @import("zine");

pub fn build(b: *std.Build) void {
    const target   = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const lib_mod = b.createModule(.{
        .root_source_file = b.path("src/root.zig"),
        .target   = target,
        .optimize = optimize,
    });

    const lib = b.addLibrary(.{
        .name    = "zine_site",
        .linkage = .static,
        .root_module = lib_mod,
    });

    b.installArtifact(lib);
    b.getInstallStep().dependOn(&zine.website(b, .{}).step);

    const serve = b.step("serve", "Start the Zine dev server");
    const run_zine = zine.serve(b, .{});
    serve.dependOn(&run_zine.step);
}
