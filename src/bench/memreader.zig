// SPDX-License-Identifier: LGPL-3.0-or-later
// Copyright (C) 2026 AstraLibernis

const std = @import("std");
const Reader = std.Io.Reader;
const Writer = std.Io.Writer;

/// In-memory reader with a bounded window, serving the corpus through real
/// refills/rebases — so the streaming number reflects genuine streaming cost,
/// not a single in-memory pass.
pub const MemReader = struct {
    interface: Reader,
    data: []const u8,
    pos: usize,

    pub fn init(window: []u8, data: []const u8) MemReader {
        return .{
            .interface = .{
                .vtable = &.{
                    .stream = streamFn,
                    .discard = Reader.defaultDiscard,
                    .readVec = Reader.defaultReadVec,
                    .rebase = Reader.defaultRebase,
                },
                .buffer = window,
                .seek = 0,
                .end = 0,
            },
            .data = data,
            .pos = 0,
        };
    }

    fn streamFn(r: *Reader, w: *Writer, limit: std.Io.Limit) Reader.StreamError!usize {
        const self: *MemReader = @alignCast(@fieldParentPtr("interface", r));
        if (self.pos >= self.data.len) return error.EndOfStream;
        const n = try w.write(limit.sliceConst(self.data[self.pos..]));
        self.pos += n;
        return n;
    }
};
