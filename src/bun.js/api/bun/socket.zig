const default_allocator = bun.default_allocator;
const bun = @import("bun");
const Environment = bun.Environment;

const strings = bun.strings;
const string = bun.string;
const Output = bun.Output;
const std = @import("std");
const JSC = bun.JSC;
const JSValue = JSC.JSValue;
const JSGlobalObject = JSC.JSGlobalObject;
const uws = bun.uws;
const ZigString = JSC.ZigString;
const BoringSSL = bun.BoringSSL.c;
const X509 = @import("./x509.zig");
const Async = bun.Async;
const uv = bun.windows.libuv;
const H2FrameParser = @import("./h2_frame_parser.zig").H2FrameParser;
const NodePath = @import("../../node/path.zig");

pub const SocketAddress = @import("./socket/SocketAddress.zig");

noinline fn getSSLException(globalThis: *JSC.JSGlobalObject, defaultMessage: []const u8) JSValue {
    var zig_str: ZigString = ZigString.init("");
    var output_buf: [4096]u8 = undefined;

    output_buf[0] = 0;
    var written: usize = 0;
    var ssl_error = BoringSSL.ERR_get_error();
    while (ssl_error != 0 and written < output_buf.len) : (ssl_error = BoringSSL.ERR_get_error()) {
        if (written > 0) {
            output_buf[written] = '\n';
            written += 1;
        }

        if (BoringSSL.ERR_reason_error_string(
            ssl_error,
        )) |reason_ptr| {
            const reason = std.mem.span(reason_ptr);
            if (reason.len == 0) {
                break;
            }
            @memcpy(output_buf[written..][0..reason.len], reason);
            written += reason.len;
        }

        if (BoringSSL.ERR_func_error_string(
            ssl_error,
        )) |reason_ptr| {
            const reason = std.mem.span(reason_ptr);
            if (reason.len > 0) {
                output_buf[written..][0.." via ".len].* = " via ".*;
                written += " via ".len;
                @memcpy(output_buf[written..][0..reason.len], reason);
                written += reason.len;
            }
        }

        if (BoringSSL.ERR_lib_error_string(
            ssl_error,
        )) |reason_ptr| {
            const reason = std.mem.span(reason_ptr);
            if (reason.len > 0) {
                output_buf[written..][0] = ' ';
                written += 1;
                @memcpy(output_buf[written..][0..reason.len], reason);
                written += reason.len;
            }
        }
    }

    if (written > 0) {
        const message = output_buf[0..written];
        zig_str = ZigString.init(std.fmt.allocPrint(bun.default_allocator, "OpenSSL {s}", .{message}) catch bun.outOfMemory());
        var encoded_str = zig_str.withEncoding();
        encoded_str.mark();

        // We shouldn't *need* to do this but it's not entirely clear.
        BoringSSL.ERR_clear_error();
    }

    if (zig_str.len == 0) {
        zig_str = ZigString.init(defaultMessage);
    }

    // store the exception in here
    // toErrorInstance clones the string
    const exception = zig_str.toErrorInstance(globalThis);

    // reference it in stack memory
    exception.ensureStillAlive();

    return exception;
}

/// we always allow and check the SSL certificate after the handshake or renegotiation
fn alwaysAllowSSLVerifyCallback(_: c_int, _: ?*BoringSSL.X509_STORE_CTX) callconv(.C) c_int {
    return 1;
}

fn normalizeHost(input: anytype) @TypeOf(input) {
    return input;
}

const BinaryType = JSC.ArrayBuffer.BinaryType;

const WrappedType = enum {
    none,
    tls,
    tcp,
};

pub const Handlers = struct {
    onOpen: JSC.JSValue = .zero,
    onClose: JSC.JSValue = .zero,
    onData: JSC.JSValue = .zero,
    onWritable: JSC.JSValue = .zero,
    onTimeout: JSC.JSValue = .zero,
    onConnectError: JSC.JSValue = .zero,
    onEnd: JSC.JSValue = .zero,
    onError: JSC.JSValue = .zero,
    onHandshake: JSC.JSValue = .zero,

    binary_type: BinaryType = .Buffer,

    vm: *JSC.VirtualMachine,
    globalObject: *JSC.JSGlobalObject,
    active_connections: u32 = 0,
    is_server: bool,
    promise: JSC.Strong.Optional = .empty,

    protection_count: bun.DebugOnly(u32) = if (Environment.isDebug) 0,

    pub fn markActive(this: *Handlers) void {
        Listener.log("markActive", .{});

        this.active_connections += 1;
    }

    pub const Scope = struct {
        handlers: *Handlers,

        pub fn exit(this: *Scope) void {
            var vm = this.handlers.vm;
            defer vm.eventLoop().exit();
            this.handlers.markInactive();
        }
    };

    pub fn enter(this: *Handlers) Scope {
        this.markActive();
        this.vm.eventLoop().enter();
        return .{
            .handlers = this,
        };
    }

    // corker: Corker = .{},

    pub fn resolvePromise(this: *Handlers, value: JSValue) void {
        const vm = this.vm;
        if (vm.isShuttingDown()) {
            return;
        }

        const promise = this.promise.trySwap() orelse return;
        const anyPromise = promise.asAnyPromise() orelse return;
        anyPromise.resolve(this.globalObject, value);
    }

    pub fn rejectPromise(this: *Handlers, value: JSValue) bool {
        const vm = this.vm;
        if (vm.isShuttingDown()) {
            return true;
        }

        const promise = this.promise.trySwap() orelse return false;
        const anyPromise = promise.asAnyPromise() orelse return false;
        anyPromise.reject(this.globalObject, value);
        return true;
    }

    pub fn markInactive(this: *Handlers) void {
        Listener.log("markInactive", .{});
        this.active_connections -= 1;
        if (this.active_connections == 0) {
            if (this.is_server) {
                const listen_socket: *Listener = @fieldParentPtr("handlers", this);
                // allow it to be GC'd once the last connection is closed and it's not listening anymore
                if (listen_socket.listener == .none) {
                    listen_socket.poll_ref.unref(this.vm);
                    listen_socket.strong_self.deinit();
                }
            } else {
                this.unprotect();
                bun.default_allocator.destroy(this);
            }
        }
    }

    pub fn callErrorHandler(this: *Handlers, thisValue: JSValue, args: *const [2]JSValue) bool {
        const vm = this.vm;
        if (vm.isShuttingDown()) {
            return false;
        }

        const globalObject = this.globalObject;
        const onError = this.onError;

        if (onError == .zero) {
            _ = vm.uncaughtException(globalObject, args[1], false);
            return false;
        }

        _ = onError.call(globalObject, thisValue, args) catch |e| globalObject.reportActiveExceptionAsUnhandled(e);

        return true;
    }

    pub fn fromJS(globalObject: *JSC.JSGlobalObject, opts: JSC.JSValue, is_server: bool) bun.JSError!Handlers {
        var handlers = Handlers{
            .vm = globalObject.bunVM(),
            .globalObject = globalObject,
            .is_server = is_server,
        };

        if (opts.isEmptyOrUndefinedOrNull() or opts.isBoolean() or !opts.isObject()) {
            return globalObject.throwInvalidArguments("Expected \"socket\" to be an object", .{});
        }

        const pairs = .{
            .{ "onData", "data" },
            .{ "onWritable", "drain" },
            .{ "onOpen", "open" },
            .{ "onClose", "close" },
            .{ "onTimeout", "timeout" },
            .{ "onConnectError", "connectError" },
            .{ "onEnd", "end" },
            .{ "onError", "error" },
            .{ "onHandshake", "handshake" },
        };
        inline for (pairs) |pair| {
            if (try opts.getTruthyComptime(globalObject, pair.@"1")) |callback_value| {
                if (!callback_value.isCell() or !callback_value.isCallable()) {
                    return globalObject.throwInvalidArguments("Expected \"{s}\" callback to be a function", .{pair[1]});
                }

                @field(handlers, pair.@"0") = callback_value;
            }
        }

        if (handlers.onData == .zero and handlers.onWritable == .zero) {
            return globalObject.throwInvalidArguments("Expected at least \"data\" or \"drain\" callback", .{});
        }

        if (try opts.getTruthy(globalObject, "binaryType")) |binary_type_value| {
            if (!binary_type_value.isString()) {
                return globalObject.throwInvalidArguments("Expected \"binaryType\" to be a string", .{});
            }

            handlers.binary_type = try BinaryType.fromJSValue(globalObject, binary_type_value) orelse {
                return globalObject.throwInvalidArguments("Expected 'binaryType' to be 'ArrayBuffer', 'Uint8Array', or 'Buffer'", .{});
            };
        }

        return handlers;
    }

    pub fn unprotect(this: *Handlers) void {
        if (this.vm.isShuttingDown()) {
            return;
        }

        if (comptime Environment.isDebug) {
            bun.assert(this.protection_count > 0);
            this.protection_count -= 1;
        }
        this.onOpen.unprotect();
        this.onClose.unprotect();
        this.onData.unprotect();
        this.onWritable.unprotect();
        this.onTimeout.unprotect();
        this.onConnectError.unprotect();
        this.onEnd.unprotect();
        this.onError.unprotect();
        this.onHandshake.unprotect();
    }

    pub fn protect(this: *Handlers) void {
        if (comptime Environment.isDebug) {
            this.protection_count += 1;
        }
        this.onOpen.protect();
        this.onClose.protect();
        this.onData.protect();
        this.onWritable.protect();
        this.onTimeout.protect();
        this.onConnectError.protect();
        this.onEnd.protect();
        this.onError.protect();
        this.onHandshake.protect();
    }
};

pub const SocketConfig = struct {
    hostname_or_unix: JSC.ZigString.Slice,
    port: ?u16 = null,
    fd: ?bun.FileDescriptor = null,
    ssl: ?JSC.API.ServerConfig.SSLConfig = null,
    handlers: Handlers,
    default_data: JSC.JSValue = .zero,
    exclusive: bool = false,
    allowHalfOpen: bool = false,
    reusePort: bool = false,
    ipv6Only: bool = false,

    pub fn socketFlags(this: *const SocketConfig) i32 {
        var flags: i32 = if (this.exclusive)
            uws.LIBUS_LISTEN_EXCLUSIVE_PORT
        else if (this.reusePort)
            uws.LIBUS_LISTEN_REUSE_PORT | uws.LIBUS_LISTEN_REUSE_ADDR
        else
            uws.LIBUS_LISTEN_DEFAULT;

        if (this.allowHalfOpen) {
            flags |= uws.LIBUS_SOCKET_ALLOW_HALF_OPEN;
        }
        if (this.ipv6Only) {
            flags |= uws.LIBUS_SOCKET_IPV6_ONLY;
        }

        return flags;
    }

    pub fn fromJS(vm: *JSC.VirtualMachine, opts: JSC.JSValue, globalObject: *JSC.JSGlobalObject, is_server: bool) bun.JSError!SocketConfig {
        var hostname_or_unix: JSC.ZigString.Slice = JSC.ZigString.Slice.empty;
        errdefer hostname_or_unix.deinit();
        var port: ?u16 = null;
        var fd: ?bun.FileDescriptor = null;
        var exclusive = false;
        var allowHalfOpen = false;
        var reusePort = false;
        var ipv6Only = false;

        var ssl: ?JSC.API.ServerConfig.SSLConfig = null;
        var default_data = JSValue.zero;

        if (try opts.getTruthy(globalObject, "tls")) |tls| {
            if (tls.isBoolean()) {
                if (tls.toBoolean()) {
                    ssl = JSC.API.ServerConfig.SSLConfig.zero;
                }
            } else {
                if (try JSC.API.ServerConfig.SSLConfig.fromJS(vm, globalObject, tls)) |ssl_config| {
                    ssl = ssl_config;
                }
            }
        }

        errdefer {
            if (ssl != null) {
                ssl.?.deinit();
            }
        }

        hostname_or_unix: {
            if (try opts.getTruthy(globalObject, "fd")) |fd_| {
                if (fd_.isNumber()) {
                    fd = fd_.asFileDescriptor();
                    break :hostname_or_unix;
                }
            }

            if (try opts.getStringish(globalObject, "unix")) |unix_socket| {
                defer unix_socket.deref();

                hostname_or_unix = try unix_socket.toUTF8WithoutRef(bun.default_allocator).cloneIfNeeded(bun.default_allocator);

                if (strings.hasPrefixComptime(hostname_or_unix.slice(), "file://") or strings.hasPrefixComptime(hostname_or_unix.slice(), "unix://") or strings.hasPrefixComptime(hostname_or_unix.slice(), "sock://")) {
                    // The memory allocator relies on the pointer address to
                    // free it, so if we simply moved the pointer up it would
                    // cause an issue when freeing it later.
                    const moved_bytes = try bun.default_allocator.dupeZ(u8, hostname_or_unix.slice()[7..]);
                    hostname_or_unix.deinit();
                    hostname_or_unix = ZigString.Slice.init(bun.default_allocator, moved_bytes);
                }

                if (hostname_or_unix.len > 0) {
                    break :hostname_or_unix;
                }
            }

            if (try opts.getBooleanLoose(globalObject, "exclusive")) |exclusive_| {
                exclusive = exclusive_;
            }
            if (try opts.getBooleanLoose(globalObject, "allowHalfOpen")) |allow_half_open| {
                allowHalfOpen = allow_half_open;
            }

            if (try opts.getBooleanLoose(globalObject, "reusePort")) |reuse_port| {
                reusePort = reuse_port;
            }

            if (try opts.getBooleanLoose(globalObject, "ipv6Only")) |ipv6_only| {
                ipv6Only = ipv6_only;
            }

            if (try opts.getStringish(globalObject, "hostname") orelse try opts.getStringish(globalObject, "host")) |hostname| {
                defer hostname.deref();

                var port_value = try opts.get(globalObject, "port") orelse JSValue.zero;
                hostname_or_unix = try hostname.toUTF8WithoutRef(bun.default_allocator).cloneIfNeeded(bun.default_allocator);

                if (port_value.isEmptyOrUndefinedOrNull() and hostname_or_unix.len > 0) {
                    const parsed_url = bun.URL.parse(hostname_or_unix.slice());
                    if (parsed_url.getPort()) |port_num| {
                        port_value = JSValue.jsNumber(port_num);
                        if (parsed_url.hostname.len > 0) {
                            const moved_bytes = try bun.default_allocator.dupeZ(u8, parsed_url.hostname);
                            hostname_or_unix.deinit();
                            hostname_or_unix = ZigString.Slice.init(bun.default_allocator, moved_bytes);
                        }
                    }
                }

                if (port_value.isEmptyOrUndefinedOrNull()) {
                    return globalObject.throwInvalidArguments("Expected \"port\" to be a number between 0 and 65535", .{});
                }

                const porti32 = port_value.coerceToInt32(globalObject);
                if (globalObject.hasException()) {
                    return error.JSError;
                }

                if (porti32 < 0 or porti32 > 65535) {
                    return globalObject.throwInvalidArguments("Expected \"port\" to be a number between 0 and 65535", .{});
                }

                port = @intCast(porti32);

                if (hostname_or_unix.len == 0) {
                    return globalObject.throwInvalidArguments("Expected \"hostname\" to be a non-empty string", .{});
                }

                if (hostname_or_unix.len > 0) {
                    break :hostname_or_unix;
                }
            }

            if (hostname_or_unix.len == 0) {
                return globalObject.throwInvalidArguments("Expected \"unix\" or \"hostname\" to be a non-empty string", .{});
            }

            return globalObject.throwInvalidArguments("Expected either \"hostname\" or \"unix\"", .{});
        }

        var handlers = try Handlers.fromJS(globalObject, try opts.get(globalObject, "socket") orelse JSValue.zero, is_server);

        if (try opts.fastGet(globalObject, .data)) |default_data_value| {
            default_data = default_data_value;
        }

        handlers.protect();

        return SocketConfig{
            .hostname_or_unix = hostname_or_unix,
            .port = port,
            .fd = fd,
            .ssl = ssl,
            .handlers = handlers,
            .default_data = default_data,
            .exclusive = exclusive,
            .allowHalfOpen = allowHalfOpen,
            .reusePort = reusePort,
            .ipv6Only = ipv6Only,
        };
    }
};

fn isValidPipeName(pipe_name: []const u8) bool {
    if (!Environment.isWindows) {
        return false;
    }
    // check for valid pipe names
    // at minimum we need to have \\.\pipe\ or \\?\pipe\ + 1 char that is not a separator
    return pipe_name.len > 9 and
        NodePath.isSepWindowsT(u8, pipe_name[0]) and
        NodePath.isSepWindowsT(u8, pipe_name[1]) and
        (pipe_name[2] == '.' or pipe_name[2] == '?') and
        NodePath.isSepWindowsT(u8, pipe_name[3]) and
        strings.eql(pipe_name[4..8], "pipe") and
        NodePath.isSepWindowsT(u8, pipe_name[8]) and
        !NodePath.isSepWindowsT(u8, pipe_name[9]);
}

fn normalizePipeName(pipe_name: []const u8, buffer: []u8) ?[]const u8 {
    if (Environment.isWindows) {
        bun.assert(pipe_name.len < buffer.len);
        if (!isValidPipeName(pipe_name)) {
            return null;
        }
        // normalize pipe name with can have mixed slashes
        // pipes are simple and this will be faster than using node:path.resolve()
        // we dont wanna to normalize the pipe name it self only the pipe identifier (//./pipe/, //?/pipe/, etc)
        @memcpy(buffer[0..9], "\\\\.\\pipe\\");
        @memcpy(buffer[9..pipe_name.len], pipe_name[9..]);
        return buffer[0..pipe_name.len];
    } else {
        return null;
    }
}

pub const Listener = struct {
    pub const log = Output.scoped(.Listener, false);

    handlers: Handlers,
    listener: ListenerType = .none,

    poll_ref: Async.KeepAlive = Async.KeepAlive.init(),
    connection: UnixOrHost,
    socket_context: ?*uws.SocketContext = null,
    ssl: bool = false,
    protos: ?[]const u8 = null,

    strong_data: JSC.Strong.Optional = .empty,
    strong_self: JSC.Strong.Optional = .empty,

    pub const js = JSC.Codegen.JSListener;
    pub const toJS = js.toJS;
    pub const fromJS = js.fromJS;
    pub const fromJSDirect = js.fromJSDirect;

    pub const ListenerType = union(enum) {
        uws: *uws.ListenSocket,
        namedPipe: *WindowsNamedPipeListeningContext,
        none: void,
    };

    pub fn getData(this: *Listener, _: *JSC.JSGlobalObject) JSValue {
        log("getData()", .{});
        return this.strong_data.get() orelse .js_undefined;
    }

    pub fn setData(this: *Listener, globalObject: *JSC.JSGlobalObject, value: JSC.JSValue) void {
        log("setData()", .{});
        this.strong_data.set(globalObject, value);
    }

    const UnixOrHost = union(enum) {
        unix: []const u8,
        host: struct {
            host: []const u8,
            port: u16,
        },
        fd: bun.FileDescriptor,

        pub fn clone(this: UnixOrHost) UnixOrHost {
            switch (this) {
                .unix => |u| {
                    return .{
                        .unix = (bun.default_allocator.dupe(u8, u) catch bun.outOfMemory()),
                    };
                },
                .host => |h| {
                    return .{
                        .host = .{
                            .host = (bun.default_allocator.dupe(u8, h.host) catch bun.outOfMemory()),
                            .port = this.host.port,
                        },
                    };
                },
                .fd => |f| return .{ .fd = f },
            }
        }

        pub fn deinit(this: UnixOrHost) void {
            switch (this) {
                .unix => |u| {
                    bun.default_allocator.free(u);
                },
                .host => |h| {
                    bun.default_allocator.free(h.host);
                },
                .fd => {}, // this is an integer
            }
        }
    };

    pub fn reload(this: *Listener, globalObject: *JSC.JSGlobalObject, callframe: *JSC.CallFrame) bun.JSError!JSValue {
        const args = callframe.arguments_old(1);

        if (args.len < 1 or (this.listener == .none and this.handlers.active_connections == 0)) {
            return globalObject.throw("Expected 1 argument", .{});
        }

        const opts = args.ptr[0];
        if (opts.isEmptyOrUndefinedOrNull() or opts.isBoolean() or !opts.isObject()) {
            return globalObject.throwValue(globalObject.toInvalidArguments("Expected options object", .{}));
        }

        const socket_obj = try opts.get(globalObject, "socket") orelse {
            return globalObject.throw("Expected \"socket\" object", .{});
        };

        const handlers = try Handlers.fromJS(globalObject, socket_obj, this.handlers.is_server);

        var prev_handlers = &this.handlers;
        prev_handlers.unprotect();
        this.handlers = handlers; // TODO: this is a memory leak
        this.handlers.protect();

        return .js_undefined;
    }

    pub fn listen(globalObject: *JSC.JSGlobalObject, opts: JSValue) bun.JSError!JSValue {
        log("listen", .{});
        if (opts.isEmptyOrUndefinedOrNull() or opts.isBoolean() or !opts.isObject()) {
            return globalObject.throwInvalidArguments("Expected object", .{});
        }

        const vm = JSC.VirtualMachine.get();

        var socket_config = try SocketConfig.fromJS(vm, opts, globalObject, true);

        var hostname_or_unix = socket_config.hostname_or_unix;
        const port = socket_config.port;
        var ssl = socket_config.ssl;
        var handlers = socket_config.handlers;
        var protos: ?[]const u8 = null;

        const ssl_enabled = ssl != null;

        const socket_flags = socket_config.socketFlags();
        defer if (ssl) |*_ssl| _ssl.deinit();

        if (Environment.isWindows) {
            if (port == null) {
                // we check if the path is a named pipe otherwise we try to connect using AF_UNIX
                const slice = hostname_or_unix.slice();
                var buf: bun.PathBuffer = undefined;
                if (normalizePipeName(slice, buf[0..])) |pipe_name| {
                    const connection: Listener.UnixOrHost = .{ .unix = (hostname_or_unix.cloneIfNeeded(bun.default_allocator) catch bun.outOfMemory()).slice() };
                    if (ssl_enabled) {
                        if (ssl.?.protos) |p| {
                            protos = p[0..ssl.?.protos_len];
                        }
                    }
                    var socket = Listener{
                        .handlers = handlers,
                        .connection = connection,
                        .ssl = ssl_enabled,
                        .socket_context = null,
                        .listener = .none,
                        .protos = if (protos) |p| (bun.default_allocator.dupe(u8, p) catch bun.outOfMemory()) else null,
                    };

                    vm.eventLoop().ensureWaker();

                    socket.handlers.protect();

                    if (socket_config.default_data != .zero) {
                        socket.strong_data = .create(socket_config.default_data, globalObject);
                    }

                    var this: *Listener = handlers.vm.allocator.create(Listener) catch bun.outOfMemory();
                    this.* = socket;
                    //TODO: server_name is not supported on named pipes, I belive its , lets wait for someone to ask for it

                    this.listener = .{
                        // we need to add support for the backlog parameter on listen here we use the default value of nodejs
                        .namedPipe = WindowsNamedPipeListeningContext.listen(globalObject, pipe_name, 511, ssl, this) catch {
                            this.deinit();
                            return globalObject.throwInvalidArguments("Failed to listen at {s}", .{pipe_name});
                        },
                    };

                    const this_value = this.toJS(globalObject);
                    this.strong_self.set(globalObject, this_value);
                    this.poll_ref.ref(handlers.vm);

                    return this_value;
                }
            }
        }
        const ctx_opts: uws.SocketContext.BunSocketContextOptions = if (ssl != null)
            JSC.API.ServerConfig.SSLConfig.asUSockets(ssl.?)
        else
            .{};

        vm.eventLoop().ensureWaker();

        var create_err: uws.create_bun_socket_error_t = .none;
        const socket_context = switch (ssl_enabled) {
            true => uws.SocketContext.createSSLContext(uws.Loop.get(), @sizeOf(usize), ctx_opts, &create_err),
            false => uws.SocketContext.createNoSSLContext(uws.Loop.get(), @sizeOf(usize)),
        } orelse {
            var err = globalObject.createErrorInstance("Failed to listen on {s}:{d}", .{ hostname_or_unix.slice(), port orelse 0 });
            defer {
                socket_config.handlers.unprotect();
                hostname_or_unix.deinit();
            }

            const errno = @intFromEnum(bun.sys.getErrno(@as(c_int, -1)));
            if (errno != 0) {
                err.put(globalObject, ZigString.static("errno"), JSValue.jsNumber(errno));
                if (bun.sys.SystemErrno.init(errno)) |str| {
                    err.put(globalObject, ZigString.static("code"), ZigString.init(@tagName(str)).toJS(globalObject));
                }
            }

            return globalObject.throwValue(err);
        };

        if (ssl_enabled) {
            if (ssl.?.protos) |p| {
                protos = p[0..ssl.?.protos_len];
            }

            uws.NewSocketHandler(true).configure(
                socket_context,
                true,
                *TLSSocket,
                struct {
                    pub const onOpen = NewSocket(true).onOpen;
                    pub const onCreate = onCreateTLS;
                    pub const onClose = NewSocket(true).onClose;
                    pub const onData = NewSocket(true).onData;
                    pub const onWritable = NewSocket(true).onWritable;
                    pub const onTimeout = NewSocket(true).onTimeout;
                    pub const onConnectError = NewSocket(true).onConnectError;
                    pub const onEnd = NewSocket(true).onEnd;
                    pub const onHandshake = NewSocket(true).onHandshake;
                },
            );
        } else {
            uws.NewSocketHandler(false).configure(
                socket_context,
                true,
                *TCPSocket,
                struct {
                    pub const onOpen = NewSocket(false).onOpen;
                    pub const onCreate = onCreateTCP;
                    pub const onClose = NewSocket(false).onClose;
                    pub const onData = NewSocket(false).onData;
                    pub const onWritable = NewSocket(false).onWritable;
                    pub const onTimeout = NewSocket(false).onTimeout;
                    pub const onConnectError = NewSocket(false).onConnectError;
                    pub const onEnd = NewSocket(false).onEnd;
                    pub const onHandshake = NewSocket(false).onHandshake;
                },
            );
        }

        var connection: Listener.UnixOrHost = if (port) |port_| .{
            .host = .{ .host = (hostname_or_unix.cloneIfNeeded(bun.default_allocator) catch bun.outOfMemory()).slice(), .port = port_ },
        } else if (socket_config.fd) |fd| .{ .fd = fd } else .{
            .unix = (hostname_or_unix.cloneIfNeeded(bun.default_allocator) catch bun.outOfMemory()).slice(),
        };
        var errno: c_int = 0;
        const listen_socket: *uws.ListenSocket = brk: {
            switch (connection) {
                .host => |c| {
                    const host = bun.default_allocator.dupeZ(u8, c.host) catch bun.outOfMemory();
                    defer bun.default_allocator.free(host);

                    const socket = socket_context.listen(ssl_enabled, host.ptr, c.port, socket_flags, 8, &errno);
                    // should return the assigned port
                    if (socket) |s| {
                        connection.host.port = @as(u16, @intCast(s.getLocalPort(ssl_enabled)));
                    }
                    break :brk socket;
                },
                .unix => |u| {
                    const host = bun.default_allocator.dupeZ(u8, u) catch bun.outOfMemory();
                    defer bun.default_allocator.free(host);
                    break :brk socket_context.listenUnix(ssl_enabled, host, host.len, socket_flags, 8, &errno);
                },
                .fd => |fd| {
                    _ = fd;
                    return globalObject.ERR(.INVALID_ARG_VALUE, "Bun does not support listening on a file descriptor.", .{}).throw();
                },
            }
        } orelse {
            defer {
                hostname_or_unix.deinit();
                socket_context.free(ssl_enabled);
            }

            const err = globalObject.createErrorInstance("Failed to listen at {s}", .{bun.span(hostname_or_unix.slice())});
            log("Failed to listen {d}", .{errno});
            if (errno != 0) {
                err.put(globalObject, ZigString.static("syscall"), bun.String.createUTF8ForJS(globalObject, "listen"));
                err.put(globalObject, ZigString.static("errno"), JSValue.jsNumber(errno));
                err.put(globalObject, ZigString.static("address"), hostname_or_unix.toZigString().toJS(globalObject));
                if (port) |p| err.put(globalObject, ZigString.static("port"), .jsNumber(p));
                if (bun.sys.SystemErrno.init(errno)) |str| {
                    err.put(globalObject, ZigString.static("code"), ZigString.init(@tagName(str)).toJS(globalObject));
                }
            }
            return globalObject.throwValue(err);
        };

        var socket = Listener{
            .handlers = handlers,
            .connection = connection,
            .ssl = ssl_enabled,
            .socket_context = socket_context,
            .listener = .{ .uws = listen_socket },
            .protos = if (protos) |p| (bun.default_allocator.dupe(u8, p) catch bun.outOfMemory()) else null,
        };

        socket.handlers.protect();

        if (socket_config.default_data != .zero) {
            socket.strong_data = .create(socket_config.default_data, globalObject);
        }

        if (ssl) |ssl_config| {
            if (ssl_config.server_name) |server_name| {
                const slice = bun.asByteSlice(server_name);
                if (slice.len > 0)
                    socket.socket_context.?.addServerName(true, server_name, ctx_opts);
            }
        }

        var this: *Listener = handlers.vm.allocator.create(Listener) catch bun.outOfMemory();
        this.* = socket;
        this.socket_context.?.ext(ssl_enabled, *Listener).?.* = this;

        const this_value = this.toJS(globalObject);
        this.strong_self.set(globalObject, this_value);
        this.poll_ref.ref(handlers.vm);

        return this_value;
    }

    pub fn onCreateTLS(socket: uws.NewSocketHandler(true)) void {
        onCreate(true, socket);
    }

    pub fn onCreateTCP(socket: uws.NewSocketHandler(false)) void {
        onCreate(false, socket);
    }

    pub fn constructor(globalObject: *JSC.JSGlobalObject, _: *JSC.CallFrame) bun.JSError!*Listener {
        return globalObject.throw("Cannot construct Listener", .{});
    }

    pub fn onNamePipeCreated(comptime ssl: bool, listener: *Listener) *NewSocket(ssl) {
        const Socket = NewSocket(ssl);
        bun.assert(ssl == listener.ssl);

        var this_socket = Socket.new(.{
            .ref_count = .init(),
            .handlers = &listener.handlers,
            .this_value = .zero,
            // here we start with a detached socket and attach it later after accept
            .socket = Socket.Socket.detached,
            .protos = listener.protos,
            .flags = .{ .owned_protos = false },
            .socket_context = null, // dont own the socket context
        });
        this_socket.ref();
        if (listener.strong_data.get()) |default_data| {
            const globalObject = listener.handlers.globalObject;
            Socket.js.dataSetCached(this_socket.getThisValue(globalObject), globalObject, default_data);
        }
        return this_socket;
    }

    pub fn onCreate(comptime ssl: bool, socket: uws.NewSocketHandler(ssl)) void {
        JSC.markBinding(@src());
        log("onCreate", .{});
        //PS: We dont reach this path when using named pipes on windows see onNamePipeCreated

        var listener: *Listener = socket.context().?.ext(ssl, *Listener).?.*;
        const Socket = NewSocket(ssl);
        bun.assert(ssl == listener.ssl);

        const this_socket = bun.new(Socket, .{
            .ref_count = .init(),
            .handlers = &listener.handlers,
            .this_value = .zero,
            .socket = socket,
            .protos = listener.protos,
            .flags = .{ .owned_protos = false },
            .socket_context = null, // dont own the socket context
        });
        this_socket.ref();
        if (listener.strong_data.get()) |default_data| {
            const globalObject = listener.handlers.globalObject;
            Socket.js.dataSetCached(this_socket.getThisValue(globalObject), globalObject, default_data);
        }
        if (socket.ext(**anyopaque)) |ctx| {
            ctx.* = bun.cast(**anyopaque, this_socket);
        }
        socket.setTimeout(120);
    }

    pub fn addServerName(this: *Listener, global: *JSC.JSGlobalObject, hostname: JSValue, tls: JSValue) bun.JSError!JSValue {
        if (!this.ssl) {
            return global.throwInvalidArguments("addServerName requires SSL support", .{});
        }
        if (!hostname.isString()) {
            return global.throwInvalidArguments("hostname pattern expects a string", .{});
        }
        const host_str = try hostname.toSlice(
            global,
            bun.default_allocator,
        );
        defer host_str.deinit();
        const server_name = bun.default_allocator.dupeZ(u8, host_str.slice()) catch bun.outOfMemory();
        defer bun.default_allocator.free(server_name);
        if (server_name.len == 0) {
            return global.throwInvalidArguments("hostname pattern cannot be empty", .{});
        }

        if (try JSC.API.ServerConfig.SSLConfig.fromJS(JSC.VirtualMachine.get(), global, tls)) |ssl_config| {
            // to keep nodejs compatibility, we allow to replace the server name
            this.socket_context.?.removeServerName(true, server_name);
            this.socket_context.?.addServerName(true, server_name, ssl_config.asUSockets());
        }

        return .js_undefined;
    }

    pub fn dispose(this: *Listener, _: *JSC.JSGlobalObject, _: *JSC.CallFrame) bun.JSError!JSValue {
        this.doStop(true);
        return .js_undefined;
    }

    pub fn stop(this: *Listener, _: *JSC.JSGlobalObject, callframe: *JSC.CallFrame) bun.JSError!JSValue {
        const arguments = callframe.arguments_old(1);
        log("close", .{});

        this.doStop(if (arguments.len > 0 and arguments.ptr[0].isBoolean()) arguments.ptr[0].toBoolean() else false);

        return .js_undefined;
    }

    fn doStop(this: *Listener, force_close: bool) void {
        if (this.listener == .none) return;
        const listener = this.listener;
        defer switch (listener) {
            .uws => |socket| socket.close(this.ssl),
            .namedPipe => |namedPipe| if (Environment.isWindows) namedPipe.closePipeAndDeinit(),
            .none => {},
        };
        this.listener = .none;

        // if we already have no active connections, we can deinit the context now
        if (this.handlers.active_connections == 0) {
            this.poll_ref.unref(this.handlers.vm);

            this.handlers.unprotect();
            // deiniting the context will also close the listener
            if (this.socket_context) |ctx| {
                this.socket_context = null;
                ctx.deinit(this.ssl);
            }
            this.strong_self.clearWithoutDeallocation();
            this.strong_data.clearWithoutDeallocation();
        } else {
            if (force_close) {
                // close all connections in this context and wait for them to close
                if (this.socket_context) |ctx| {
                    ctx.close(this.ssl);
                }
            }
        }
    }

    pub fn finalize(this: *Listener) callconv(.C) void {
        log("finalize", .{});
        const listener = this.listener;
        this.listener = .none;
        switch (listener) {
            .uws => |socket| socket.close(this.ssl),
            .namedPipe => |namedPipe| if (Environment.isWindows) namedPipe.closePipeAndDeinit(),
            .none => {},
        }
        this.deinit();
    }

    pub fn deinit(this: *Listener) void {
        log("deinit", .{});
        this.strong_self.deinit();
        this.strong_data.deinit();
        this.poll_ref.unref(this.handlers.vm);
        bun.assert(this.listener == .none);
        this.handlers.unprotect();

        if (this.handlers.active_connections > 0) {
            if (this.socket_context) |ctx| {
                ctx.close(this.ssl);
            }
            // TODO: fix this leak.
        } else {
            if (this.socket_context) |ctx| {
                ctx.deinit(this.ssl);
            }
        }

        this.connection.deinit();
        if (this.protos) |protos| {
            this.protos = null;
            bun.default_allocator.free(protos);
        }
        bun.default_allocator.destroy(this);
    }

    pub fn getConnectionsCount(this: *Listener, _: *JSC.JSGlobalObject) JSValue {
        return JSValue.jsNumber(this.handlers.active_connections);
    }

    pub fn getUnix(this: *Listener, globalObject: *JSC.JSGlobalObject) JSValue {
        if (this.connection != .unix) {
            return .js_undefined;
        }

        return ZigString.init(this.connection.unix).withEncoding().toJS(globalObject);
    }

    pub fn getHostname(this: *Listener, globalObject: *JSC.JSGlobalObject) JSValue {
        if (this.connection != .host) {
            return .js_undefined;
        }
        return ZigString.init(this.connection.host.host).withEncoding().toJS(globalObject);
    }

    pub fn getPort(this: *Listener, _: *JSC.JSGlobalObject) JSValue {
        if (this.connection != .host) {
            return .js_undefined;
        }
        return JSValue.jsNumber(this.connection.host.port);
    }

    pub fn ref(this: *Listener, globalObject: *JSC.JSGlobalObject, callframe: *JSC.CallFrame) bun.JSError!JSValue {
        const this_value = callframe.this();
        if (this.listener == .none) return .js_undefined;
        this.poll_ref.ref(globalObject.bunVM());
        this.strong_self.set(globalObject, this_value);
        return .js_undefined;
    }

    pub fn unref(this: *Listener, globalObject: *JSC.JSGlobalObject, _: *JSC.CallFrame) bun.JSError!JSValue {
        this.poll_ref.unref(globalObject.bunVM());
        if (this.handlers.active_connections == 0) {
            this.strong_self.clearWithoutDeallocation();
        }
        return .js_undefined;
    }

    pub fn connect(globalObject: *JSC.JSGlobalObject, opts: JSValue) bun.JSError!JSValue {
        return connectInner(globalObject, null, null, opts);
    }

    pub fn connectInner(globalObject: *JSC.JSGlobalObject, prev_maybe_tcp: ?*TCPSocket, prev_maybe_tls: ?*TLSSocket, opts: JSValue) bun.JSError!JSValue {
        if (opts.isEmptyOrUndefinedOrNull() or opts.isBoolean() or !opts.isObject()) {
            return globalObject.throwInvalidArguments("Expected options object", .{});
        }
        const vm = globalObject.bunVM();

        const socket_config = try SocketConfig.fromJS(vm, opts, globalObject, false);

        var hostname_or_unix = socket_config.hostname_or_unix;
        const port = socket_config.port;
        var ssl = socket_config.ssl;
        var handlers = socket_config.handlers;
        var default_data = socket_config.default_data;

        var protos: ?[]const u8 = null;
        var server_name: ?[]const u8 = null;
        const ssl_enabled = ssl != null;
        defer if (ssl != null) ssl.?.deinit();

        vm.eventLoop().ensureWaker();

        var connection: Listener.UnixOrHost = blk: {
            if (try opts.getTruthy(globalObject, "fd")) |fd_| {
                if (fd_.isNumber()) {
                    const fd = fd_.asFileDescriptor();
                    break :blk .{ .fd = fd };
                }
            }
            if (port) |_| {
                break :blk .{ .host = .{ .host = (hostname_or_unix.cloneIfNeeded(bun.default_allocator) catch bun.outOfMemory()).slice(), .port = port.? } };
            }

            break :blk .{ .unix = (hostname_or_unix.cloneIfNeeded(bun.default_allocator) catch bun.outOfMemory()).slice() };
        };

        if (Environment.isWindows) {
            var buf: bun.PathBuffer = undefined;
            var pipe_name: ?[]const u8 = null;
            const isNamedPipe = switch (connection) {
                // we check if the path is a named pipe otherwise we try to connect using AF_UNIX
                .unix => |slice| brk: {
                    pipe_name = normalizePipeName(slice, buf[0..]);
                    break :brk (pipe_name != null);
                },
                .fd => |fd| brk: {
                    const uvfd = fd.uv();
                    const fd_type = uv.uv_guess_handle(uvfd);
                    if (fd_type == uv.Handle.Type.named_pipe) {
                        break :brk true;
                    }
                    if (fd_type == uv.Handle.Type.unknown) {
                        // is not a libuv fd, check if it's a named pipe
                        const osfd: uv.uv_os_fd_t = @ptrFromInt(@as(usize, @intCast(uvfd)));
                        if (bun.windows.GetFileType(osfd) == bun.windows.FILE_TYPE_PIPE) {
                            // yay its a named pipe lets make it a libuv fd
                            connection.fd = bun.FD.fromNative(osfd).makeLibUVOwned() catch @panic("failed to allocate file descriptor");
                            break :brk true;
                        }
                    }
                    break :brk false;
                },
                else => false,
            };
            if (isNamedPipe) {
                default_data.ensureStillAlive();

                var handlers_ptr = handlers.vm.allocator.create(Handlers) catch bun.outOfMemory();
                handlers_ptr.* = handlers;

                var promise = JSC.JSPromise.create(globalObject);
                const promise_value = promise.toJS();
                handlers_ptr.promise.set(globalObject, promise_value);

                if (ssl_enabled) {
                    var tls = if (prev_maybe_tls) |prev| blk: {
                        bun.destroy(prev.handlers);
                        bun.assert(prev.this_value != .zero);
                        prev.handlers = handlers_ptr;
                        bun.assert(prev.socket.socket == .detached);
                        prev.connection = connection;
                        prev.protos = if (protos) |p| (bun.default_allocator.dupe(u8, p) catch bun.outOfMemory()) else null;
                        prev.server_name = server_name;
                        prev.socket_context = null;
                        break :blk prev;
                    } else TLSSocket.new(.{
                        .ref_count = .init(),
                        .handlers = handlers_ptr,
                        .this_value = .zero,
                        .socket = TLSSocket.Socket.detached,
                        .connection = connection,
                        .protos = if (protos) |p| (bun.default_allocator.dupe(u8, p) catch bun.outOfMemory()) else null,
                        .server_name = server_name,
                        .socket_context = null,
                    });
                    TLSSocket.js.dataSetCached(tls.getThisValue(globalObject), globalObject, default_data);
                    tls.poll_ref.ref(handlers.vm);
                    tls.ref();
                    if (connection == .unix) {
                        const named_pipe = WindowsNamedPipeContext.connect(globalObject, pipe_name.?, ssl, .{ .tls = tls }) catch {
                            return promise_value;
                        };
                        tls.socket = TLSSocket.Socket.fromNamedPipe(named_pipe);
                    } else {
                        // fd
                        const named_pipe = WindowsNamedPipeContext.open(globalObject, connection.fd, ssl, .{ .tls = tls }) catch {
                            return promise_value;
                        };
                        tls.socket = TLSSocket.Socket.fromNamedPipe(named_pipe);
                    }
                } else {
                    var tcp = if (prev_maybe_tcp) |prev| blk: {
                        bun.assert(prev.this_value != .zero);
                        prev.handlers = handlers_ptr;
                        bun.assert(prev.socket.socket == .detached);
                        bun.assert(prev.connection == null);
                        bun.assert(prev.protos == null);
                        bun.assert(prev.server_name == null);
                        prev.socket_context = null;
                        break :blk prev;
                    } else TCPSocket.new(.{
                        .ref_count = .init(),
                        .handlers = handlers_ptr,
                        .this_value = .zero,
                        .socket = TCPSocket.Socket.detached,
                        .connection = null,
                        .protos = null,
                        .server_name = null,
                        .socket_context = null,
                    });
                    tcp.ref();
                    TCPSocket.js.dataSetCached(tcp.getThisValue(globalObject), globalObject, default_data);
                    tcp.poll_ref.ref(handlers.vm);

                    if (connection == .unix) {
                        const named_pipe = WindowsNamedPipeContext.connect(globalObject, pipe_name.?, null, .{ .tcp = tcp }) catch {
                            return promise_value;
                        };
                        tcp.socket = TCPSocket.Socket.fromNamedPipe(named_pipe);
                    } else {
                        // fd
                        const named_pipe = WindowsNamedPipeContext.open(globalObject, connection.fd, null, .{ .tcp = tcp }) catch {
                            return promise_value;
                        };
                        tcp.socket = TCPSocket.Socket.fromNamedPipe(named_pipe);
                    }
                }
                return promise_value;
            }
        }

        const ctx_opts: uws.SocketContext.BunSocketContextOptions = if (ssl != null)
            JSC.API.ServerConfig.SSLConfig.asUSockets(ssl.?)
        else
            .{};

        var create_err: uws.create_bun_socket_error_t = .none;
        const socket_context = switch (ssl_enabled) {
            true => uws.SocketContext.createSSLContext(uws.Loop.get(), @sizeOf(usize), ctx_opts, &create_err),
            false => uws.SocketContext.createNoSSLContext(uws.Loop.get(), @sizeOf(usize)),
        } orelse {
            const err = JSC.SystemError{
                .message = bun.String.static("Failed to connect"),
                .syscall = bun.String.static("connect"),
                .code = if (port == null) bun.String.static("ENOENT") else bun.String.static("ECONNREFUSED"),
            };
            handlers.unprotect();
            connection.deinit();
            return globalObject.throwValue(err.toErrorInstance(globalObject));
        };

        if (ssl_enabled) {
            if (ssl.?.protos) |p| {
                protos = p[0..ssl.?.protos_len];
            }
            if (ssl.?.server_name) |s| {
                server_name = bun.default_allocator.dupe(u8, s[0..bun.len(s)]) catch bun.outOfMemory();
            }
            uws.NewSocketHandler(true).configure(socket_context, true, *TLSSocket, NewSocket(true));
        } else {
            uws.NewSocketHandler(false).configure(socket_context, true, *TCPSocket, NewSocket(false));
        }

        default_data.ensureStillAlive();

        var handlers_ptr = handlers.vm.allocator.create(Handlers) catch bun.outOfMemory();
        handlers_ptr.* = handlers;
        handlers_ptr.is_server = false;

        var promise = JSC.JSPromise.create(globalObject);
        const promise_value = promise.toJS();
        handlers_ptr.promise.set(globalObject, promise_value);

        switch (ssl_enabled) {
            inline else => |is_ssl_enabled| {
                const SocketType = NewSocket(is_ssl_enabled);
                const maybe_previous: ?*SocketType = if (is_ssl_enabled) prev_maybe_tls else prev_maybe_tcp;

                const socket = if (maybe_previous) |prev| blk: {
                    bun.assert(prev.this_value != .zero);
                    prev.handlers = handlers_ptr;
                    bun.assert(prev.socket.socket == .detached);
                    prev.connection = connection;
                    prev.protos = if (protos) |p| (bun.default_allocator.dupe(u8, p) catch bun.outOfMemory()) else null;
                    prev.server_name = server_name;
                    prev.socket_context = socket_context;
                    break :blk prev;
                } else bun.new(SocketType, .{
                    .ref_count = .init(),
                    .handlers = handlers_ptr,
                    .this_value = .zero,
                    .socket = SocketType.Socket.detached,
                    .connection = connection,
                    .protos = if (protos) |p| (bun.default_allocator.dupe(u8, p) catch bun.outOfMemory()) else null,
                    .server_name = server_name,
                    .socket_context = socket_context, // owns the socket context
                });
                socket.ref();
                SocketType.js.dataSetCached(socket.getThisValue(globalObject), globalObject, default_data);
                socket.flags.allow_half_open = socket_config.allowHalfOpen;
                socket.doConnect(connection) catch {
                    socket.handleConnectError(@intFromEnum(if (port == null) bun.sys.SystemErrno.ENOENT else bun.sys.SystemErrno.ECONNREFUSED));
                    return promise_value;
                };

                // if this is from node:net there's surface where the user can .ref() and .deref() before the connection starts. make sure we honor that here.
                // in the Bun.connect path, this will always be true at this point in time.
                if (socket.ref_pollref_on_connect) socket.poll_ref.ref(handlers.vm);

                return promise_value;
            },
        }
    }

    pub fn getsockname(this: *Listener, globalThis: *JSC.JSGlobalObject, callFrame: *JSC.CallFrame) bun.JSError!JSValue {
        if (this.listener != .uws) {
            return .js_undefined;
        }

        const out = callFrame.argumentsAsArray(1)[0];
        const socket = this.listener.uws;

        var buf: [64]u8 = [_]u8{0} ** 64;
        var text_buf: [512]u8 = undefined;
        const address_bytes: []const u8 = socket.getLocalAddress(this.ssl, &buf) catch return .js_undefined;
        const address_zig: std.net.Address = switch (address_bytes.len) {
            4 => std.net.Address.initIp4(address_bytes[0..4].*, 0),
            16 => std.net.Address.initIp6(address_bytes[0..16].*, 0, 0, 0),
            else => return .js_undefined,
        };
        const family_js = switch (address_bytes.len) {
            4 => bun.String.static("IPv4").toJS(globalThis),
            16 => bun.String.static("IPv6").toJS(globalThis),
            else => return .js_undefined,
        };
        const address_js = ZigString.init(bun.fmt.formatIp(address_zig, &text_buf) catch unreachable).toJS(globalThis);
        const port_js: JSValue = .jsNumber(socket.getLocalPort(this.ssl));

        out.put(globalThis, bun.String.static("family"), family_js);
        out.put(globalThis, bun.String.static("address"), address_js);
        out.put(globalThis, bun.String.static("port"), port_js);
        return .js_undefined;
    }
};

fn JSSocketType(comptime ssl: bool) type {
    if (!ssl) {
        return JSC.Codegen.JSTCPSocket;
    } else {
        return JSC.Codegen.JSTLSSocket;
    }
}

fn selectALPNCallback(_: ?*BoringSSL.SSL, out: [*c][*c]const u8, outlen: [*c]u8, in: [*c]const u8, inlen: c_uint, arg: ?*anyopaque) callconv(.C) c_int {
    const this = bun.cast(*TLSSocket, arg);
    if (this.protos) |protos| {
        if (protos.len == 0) {
            return BoringSSL.SSL_TLSEXT_ERR_NOACK;
        }
        const status = BoringSSL.SSL_select_next_proto(bun.cast([*c][*c]u8, out), outlen, protos.ptr, @as(c_uint, @intCast(protos.len)), in, inlen);
        // Previous versions of Node.js returned SSL_TLSEXT_ERR_NOACK if no protocol
        // match was found. This would neither cause a fatal alert nor would it result
        // in a useful ALPN response as part of the Server Hello message.
        // We now return SSL_TLSEXT_ERR_ALERT_FATAL in that case as per Section 3.2
        // of RFC 7301, which causes a fatal no_application_protocol alert.
        return if (status == BoringSSL.OPENSSL_NPN_NEGOTIATED) BoringSSL.SSL_TLSEXT_ERR_OK else BoringSSL.SSL_TLSEXT_ERR_ALERT_FATAL;
    } else {
        return BoringSSL.SSL_TLSEXT_ERR_NOACK;
    }
}

fn NewSocket(comptime ssl: bool) type {
    return struct {
        const This = @This();
        pub const js = if (!ssl) JSC.Codegen.JSTCPSocket else JSC.Codegen.JSTLSSocket;
        pub const toJS = js.toJS;
        pub const fromJS = js.fromJS;
        pub const fromJSDirect = js.fromJSDirect;

        pub const new = bun.TrivialNew(@This());

        const RefCount = bun.ptr.RefCount(@This(), "ref_count", deinit, .{});
        pub const ref = RefCount.ref;
        pub const deref = RefCount.deref;

        pub const Socket = uws.NewSocketHandler(ssl);
        socket: Socket,
        // if the socket owns a context it will be here
        socket_context: ?*uws.SocketContext,

        flags: Flags = .{},
        ref_count: RefCount,
        wrapped: WrappedType = .none,
        // TODO: make this optional
        handlers: *Handlers,
        this_value: JSC.JSValue = .zero,
        poll_ref: Async.KeepAlive = Async.KeepAlive.init(),
        ref_pollref_on_connect: bool = true,
        connection: ?Listener.UnixOrHost = null,
        protos: ?[]const u8,
        server_name: ?[]const u8 = null,
        buffered_data_for_node_net: bun.ByteList = .{},
        bytes_written: u64 = 0,

        // TODO: switch to something that uses `visitAggregate` and have the
        // `Listener` keep a list of all the sockets JSValue in there
        // This is wasteful because it means we are keeping a JSC::Weak for every single open socket
        has_pending_activity: std.atomic.Value(bool) = std.atomic.Value(bool).init(true),
        native_callback: NativeCallbacks = .none,

        // We use this direct callbacks on HTTP2 when available
        pub const NativeCallbacks = union(enum) {
            h2: *H2FrameParser,
            none,

            pub fn onData(this: NativeCallbacks, data: []const u8) bool {
                switch (this) {
                    .h2 => |h2| {
                        h2.onNativeRead(data) catch return false; // TODO: properly propagate exception upwards
                        return true;
                    },
                    .none => return false,
                }
            }
            pub fn onWritable(this: NativeCallbacks) bool {
                switch (this) {
                    .h2 => |h2| {
                        h2.onNativeWritable();
                        return true;
                    },
                    .none => return false,
                }
            }
        };

        const log = Output.scoped(.Socket, false);

        const WriteResult = union(enum) {
            fail: void,
            success: struct {
                wrote: i32 = 0,
                total: usize = 0,
            },
        };

        const Flags = packed struct(u16) {
            is_active: bool = false,
            /// Prevent onClose from calling into JavaScript while we are finalizing
            finalizing: bool = false,
            authorized: bool = false,
            handshake_complete: bool = false,
            empty_packet_pending: bool = false,
            end_after_flush: bool = false,
            owned_protos: bool = true,
            is_paused: bool = false,
            allow_half_open: bool = false,
            _: u7 = 0,
        };

        pub fn hasPendingActivity(this: *This) callconv(.C) bool {
            return this.has_pending_activity.load(.acquire);
        }

        pub fn memoryCost(this: *This) usize {
            return @sizeOf(This) + this.buffered_data_for_node_net.cap;
        }

        pub fn attachNativeCallback(this: *This, callback: NativeCallbacks) bool {
            if (this.native_callback != .none) return false;
            this.native_callback = callback;

            switch (callback) {
                .h2 => |h2| h2.ref(),
                .none => {},
            }
            return true;
        }

        pub fn detachNativeCallback(this: *This) void {
            const native_callback = this.native_callback;
            this.native_callback = .none;

            switch (native_callback) {
                .h2 => |h2| {
                    h2.onNativeClose();
                    h2.deref();
                },
                .none => {},
            }
        }

        pub fn doConnect(this: *This, connection: Listener.UnixOrHost) !void {
            bun.assert(this.socket_context != null);
            this.ref();
            errdefer this.deref();

            switch (connection) {
                .host => |c| {
                    this.socket = try This.Socket.connectAnon(
                        normalizeHost(c.host),
                        c.port,
                        this.socket_context.?,
                        this,
                        this.flags.allow_half_open,
                    );
                },
                .unix => |u| {
                    this.socket = try This.Socket.connectUnixAnon(
                        u,
                        this.socket_context.?,
                        this,
                        this.flags.allow_half_open,
                    );
                },
                .fd => |f| {
                    const socket = This.Socket.fromFd(this.socket_context.?, f, This, this, null, false) orelse return error.ConnectionFailed;
                    this.onOpen(socket);
                },
            }
        }

        pub fn constructor(globalObject: *JSC.JSGlobalObject, _: *JSC.CallFrame) bun.JSError!*This {
            return globalObject.throw("Cannot construct Socket", .{});
        }

        pub fn resumeFromJS(this: *This, _: *JSC.JSGlobalObject, _: *JSC.CallFrame) bun.JSError!JSValue {
            JSC.markBinding(@src());
            if (this.socket.isDetached()) return .js_undefined;

            log("resume", .{});
            // we should not allow pausing/resuming a wrapped socket because a wrapped socket is 2 sockets and this can cause issues
            if (this.wrapped == .none and this.flags.is_paused) {
                this.flags.is_paused = !this.socket.resumeStream();
            }
            return .js_undefined;
        }

        pub fn pauseFromJS(this: *This, _: *JSC.JSGlobalObject, _: *JSC.CallFrame) bun.JSError!JSValue {
            JSC.markBinding(@src());
            if (this.socket.isDetached()) return .js_undefined;

            log("pause", .{});
            // we should not allow pausing/resuming a wrapped socket because a wrapped socket is 2 sockets and this can cause issues
            if (this.wrapped == .none and !this.flags.is_paused) {
                this.flags.is_paused = this.socket.pauseStream();
            }

            return .js_undefined;
        }

        pub fn setKeepAlive(this: *This, globalThis: *JSC.JSGlobalObject, callframe: *JSC.CallFrame) bun.JSError!JSValue {
            JSC.markBinding(@src());
            const args = callframe.arguments_old(2);

            const enabled: bool = brk: {
                if (args.len >= 1) {
                    break :brk args.ptr[0].coerce(bool, globalThis);
                }
                break :brk false;
            };

            const initialDelay: u32 = brk: {
                if (args.len > 1) {
                    break :brk @intCast(try globalThis.validateIntegerRange(args.ptr[1], i32, 0, .{ .min = 0, .field_name = "initialDelay" }));
                }
                break :brk 0;
            };
            log("setKeepAlive({}, {})", .{ enabled, initialDelay });

            return JSValue.jsBoolean(this.socket.setKeepAlive(enabled, initialDelay));
        }

        pub fn setNoDelay(this: *This, globalThis: *JSC.JSGlobalObject, callframe: *JSC.CallFrame) bun.JSError!JSValue {
            JSC.markBinding(@src());

            const args = callframe.arguments_old(1);
            const enabled: bool = brk: {
                if (args.len >= 1) {
                    break :brk args.ptr[0].coerce(bool, globalThis);
                }
                break :brk true;
            };
            log("setNoDelay({})", .{enabled});

            return JSValue.jsBoolean(this.socket.setNoDelay(enabled));
        }

        pub fn handleError(this: *This, err_value: JSC.JSValue) void {
            log("handleError", .{});
            const handlers = this.handlers;
            var vm = handlers.vm;
            if (vm.isShuttingDown()) {
                return;
            }
            vm.eventLoop().enter();
            defer vm.eventLoop().exit();
            const globalObject = handlers.globalObject;
            const this_value = this.getThisValue(globalObject);
            _ = handlers.callErrorHandler(this_value, &.{ this_value, err_value });
        }

        pub fn onWritable(this: *This, _: Socket) void {
            JSC.markBinding(@src());
            if (this.socket.isDetached()) return;
            if (this.native_callback.onWritable()) return;
            const handlers = this.handlers;
            const callback = handlers.onWritable;
            if (callback == .zero) return;

            var vm = handlers.vm;
            if (vm.isShuttingDown()) {
                return;
            }
            this.ref();
            defer this.deref();
            this.internalFlush();
            log("onWritable buffered_data_for_node_net {d}", .{this.buffered_data_for_node_net.len});
            // is not writable if we have buffered data or if we are already detached
            if (this.buffered_data_for_node_net.len > 0 or this.socket.isDetached()) return;

            vm.eventLoop().enter();
            defer vm.eventLoop().exit();

            const globalObject = handlers.globalObject;
            const this_value = this.getThisValue(globalObject);
            _ = callback.call(globalObject, this_value, &.{this_value}) catch |err| {
                _ = handlers.callErrorHandler(this_value, &.{ this_value, globalObject.takeError(err) });
            };
        }

        pub fn onTimeout(this: *This, _: Socket) void {
            JSC.markBinding(@src());
            if (this.socket.isDetached()) return;
            log("onTimeout {s}", .{if (this.handlers.is_server) "S" else "C"});
            const handlers = this.handlers;
            const callback = handlers.onTimeout;
            if (callback == .zero or this.flags.finalizing) return;
            if (handlers.vm.isShuttingDown()) {
                return;
            }

            // the handlers must be kept alive for the duration of the function call
            // that way if we need to call the error handler, we can
            var scope = handlers.enter();
            defer scope.exit();

            const globalObject = handlers.globalObject;
            const this_value = this.getThisValue(globalObject);
            _ = callback.call(globalObject, this_value, &.{this_value}) catch |err| {
                _ = handlers.callErrorHandler(this_value, &.{ this_value, globalObject.takeError(err) });
            };
        }

        fn handleConnectError(this: *This, errno: c_int) void {
            log("onConnectError {s} ({d}, {d})", .{ if (this.handlers.is_server) "S" else "C", errno, this.ref_count.active_counts });
            // Ensure the socket is still alive for any defer's we have
            this.ref();
            defer this.deref();
            this.buffered_data_for_node_net.deinitWithAllocator(bun.default_allocator);

            const needs_deref = !this.socket.isDetached();
            this.socket = Socket.detached;
            defer this.markInactive();
            defer if (needs_deref) this.deref();

            const handlers = this.handlers;
            const vm = handlers.vm;
            this.poll_ref.unrefOnNextTick(vm);
            if (vm.isShuttingDown()) {
                return;
            }

            bun.assert(errno >= 0);
            var errno_: c_int = if (errno == @intFromEnum(bun.sys.SystemErrno.ENOENT)) @intFromEnum(bun.sys.SystemErrno.ENOENT) else @intFromEnum(bun.sys.SystemErrno.ECONNREFUSED);
            const code_ = if (errno == @intFromEnum(bun.sys.SystemErrno.ENOENT)) bun.String.static("ENOENT") else bun.String.static("ECONNREFUSED");
            if (Environment.isWindows and errno_ == @intFromEnum(bun.sys.SystemErrno.ENOENT)) errno_ = @intFromEnum(bun.sys.SystemErrno.UV_ENOENT);
            if (Environment.isWindows and errno_ == @intFromEnum(bun.sys.SystemErrno.ECONNREFUSED)) errno_ = @intFromEnum(bun.sys.SystemErrno.UV_ECONNREFUSED);

            const callback = handlers.onConnectError;
            const globalObject = handlers.globalObject;
            const err = JSC.SystemError{
                .errno = -errno_,
                .message = bun.String.static("Failed to connect"),
                .syscall = bun.String.static("connect"),
                .code = code_,
            };
            vm.eventLoop().enter();
            defer {
                vm.eventLoop().exit();
            }

            if (callback == .zero) {
                if (handlers.promise.trySwap()) |promise| {
                    handlers.promise.deinit();
                    if (this.this_value != .zero) {
                        this.this_value = .zero;
                    }
                    this.has_pending_activity.store(false, .release);

                    // reject the promise on connect() error
                    const err_value = err.toErrorInstance(globalObject);
                    promise.asPromise().?.reject(globalObject, err_value);
                }

                return;
            }

            const this_value = this.getThisValue(globalObject);
            this.this_value = .zero;
            this.has_pending_activity.store(false, .release);

            const err_value = err.toErrorInstance(globalObject);
            const result = callback.call(globalObject, this_value, &[_]JSValue{
                this_value,
                err_value,
            }) catch |e| globalObject.takeException(e);

            if (result.toError()) |err_val| {
                if (handlers.rejectPromise(err_val)) return;
                _ = handlers.callErrorHandler(this_value, &.{ this_value, err_val });
            } else if (handlers.promise.trySwap()) |val| {
                // They've defined a `connectError` callback
                // The error is effectively handled, but we should still reject the promise.
                var promise = val.asPromise().?;
                const err_ = err.toErrorInstance(globalObject);
                promise.rejectAsHandled(globalObject, err_);
            }
        }

        pub fn onConnectError(this: *This, _: Socket, errno: c_int) void {
            JSC.markBinding(@src());
            this.handleConnectError(errno);
        }

        pub fn markActive(this: *This) void {
            if (!this.flags.is_active) {
                this.handlers.markActive();
                this.flags.is_active = true;
                this.has_pending_activity.store(true, .release);
            }
        }

        pub fn closeAndDetach(this: *This, code: uws.Socket.CloseCode) void {
            const socket = this.socket;
            this.buffered_data_for_node_net.deinitWithAllocator(bun.default_allocator);

            this.socket.detach();
            this.detachNativeCallback();

            socket.close(code);
        }

        pub fn markInactive(this: *This) void {
            if (this.flags.is_active) {
                // we have to close the socket before the socket context is closed
                // otherwise we will get a segfault
                // uSockets will defer freeing the TCP socket until the next tick
                if (!this.socket.isClosed()) {
                    this.closeAndDetach(.normal);
                    // onClose will call markInactive again
                    return;
                }

                this.flags.is_active = false;
                const vm = this.handlers.vm;
                this.handlers.markInactive();
                this.poll_ref.unref(vm);
                this.has_pending_activity.store(false, .release);
            }
        }

        pub fn onOpen(this: *This, socket: Socket) void {
            log("onOpen {s} {*} {} {}", .{ if (this.handlers.is_server) "S" else "C", this, this.socket.isDetached(), this.ref_count.active_counts });
            // Ensure the socket remains alive until this is finished
            this.ref();
            defer this.deref();

            // update the internal socket instance to the one that was just connected
            // This socket must be replaced because the previous one is a connecting socket not a uSockets socket
            this.socket = socket;
            JSC.markBinding(@src());

            // Add SNI support for TLS (mongodb and others requires this)
            if (comptime ssl) {
                if (this.socket.ssl()) |ssl_ptr| {
                    if (!ssl_ptr.isInitFinished()) {
                        if (this.server_name) |server_name| {
                            const host = normalizeHost(server_name);
                            if (host.len > 0) {
                                const host__ = default_allocator.dupeZ(u8, host) catch bun.outOfMemory();
                                defer default_allocator.free(host__);
                                ssl_ptr.setHostname(host__);
                            }
                        } else if (this.connection) |connection| {
                            if (connection == .host) {
                                const host = normalizeHost(connection.host.host);
                                if (host.len > 0) {
                                    const host__ = default_allocator.dupeZ(u8, host) catch bun.outOfMemory();
                                    defer default_allocator.free(host__);
                                    ssl_ptr.setHostname(host__);
                                }
                            }
                        }
                        if (this.protos) |protos| {
                            if (this.handlers.is_server) {
                                BoringSSL.SSL_CTX_set_alpn_select_cb(BoringSSL.SSL_get_SSL_CTX(ssl_ptr), selectALPNCallback, bun.cast(*anyopaque, this));
                            } else {
                                _ = BoringSSL.SSL_set_alpn_protos(ssl_ptr, protos.ptr, @as(c_uint, @intCast(protos.len)));
                            }
                        }
                    }
                }
            }

            if (this.wrapped == .none) {
                if (socket.ext(**anyopaque)) |ctx| {
                    ctx.* = bun.cast(**anyopaque, this);
                }
            }

            const handlers = this.handlers;
            const callback = handlers.onOpen;
            const handshake_callback = handlers.onHandshake;

            const globalObject = handlers.globalObject;
            const this_value = this.getThisValue(globalObject);

            this.markActive();
            handlers.resolvePromise(this_value);

            if (comptime ssl) {
                // only calls open callback if handshake callback is provided
                // If handshake is provided, open is called on connection open
                // If is not provided, open is called after handshake
                if (callback == .zero or handshake_callback == .zero) return;
            } else {
                if (callback == .zero) return;
            }
            const vm = handlers.vm;
            vm.eventLoop().enter();
            defer vm.eventLoop().exit();
            const result = callback.call(globalObject, this_value, &[_]JSValue{this_value}) catch |err| globalObject.takeException(err);

            if (result.toError()) |err| {
                defer this.markInactive();
                if (!this.socket.isClosed()) {
                    log("Closing due to error", .{});
                } else {
                    log("Already closed", .{});
                }

                if (handlers.rejectPromise(err)) return;
                _ = handlers.callErrorHandler(this_value, &.{ this_value, err });
            }
        }

        pub fn getThisValue(this: *This, globalObject: *JSC.JSGlobalObject) JSValue {
            if (this.this_value == .zero) {
                const value = this.toJS(globalObject);
                value.ensureStillAlive();
                this.this_value = value;
                return value;
            }

            return this.this_value;
        }

        pub fn onEnd(this: *This, _: Socket) void {
            JSC.markBinding(@src());
            if (this.socket.isDetached()) return;
            log("onEnd {s}", .{if (this.handlers.is_server) "S" else "C"});
            // Ensure the socket remains alive until this is finished
            this.ref();
            defer this.deref();

            const handlers = this.handlers;

            const callback = handlers.onEnd;
            if (callback == .zero or handlers.vm.isShuttingDown()) {
                this.poll_ref.unref(handlers.vm);

                // If you don't handle TCP fin, we assume you're done.
                this.markInactive();
                return;
            }

            // the handlers must be kept alive for the duration of the function call
            // that way if we need to call the error handler, we can
            var scope = handlers.enter();
            defer scope.exit();

            const globalObject = handlers.globalObject;
            const this_value = this.getThisValue(globalObject);
            _ = callback.call(globalObject, this_value, &.{this_value}) catch |err| {
                _ = handlers.callErrorHandler(this_value, &.{ this_value, globalObject.takeError(err) });
            };
        }

        pub fn onHandshake(this: *This, _: Socket, success: i32, ssl_error: uws.us_bun_verify_error_t) void {
            JSC.markBinding(@src());
            this.flags.handshake_complete = true;
            if (this.socket.isDetached()) return;
            log("onHandshake {s} ({d})", .{ if (this.handlers.is_server) "S" else "C", success });

            const authorized = if (success == 1) true else false;

            this.flags.authorized = authorized;

            const handlers = this.handlers;
            var callback = handlers.onHandshake;
            var is_open = false;

            if (handlers.vm.isShuttingDown()) {
                return;
            }

            // Use open callback when handshake is not provided
            if (callback == .zero) {
                callback = handlers.onOpen;
                if (callback == .zero) {
                    return;
                }
                is_open = true;
            }

            // the handlers must be kept alive for the duration of the function call
            // that way if we need to call the error handler, we can
            var scope = handlers.enter();
            defer scope.exit();

            const globalObject = handlers.globalObject;
            const this_value = this.getThisValue(globalObject);

            var result: JSC.JSValue = JSC.JSValue.zero;
            // open callback only have 1 parameters and its the socket
            // you should use getAuthorizationError and authorized getter to get those values in this case
            if (is_open) {
                result = callback.call(globalObject, this_value, &[_]JSValue{this_value}) catch |err| globalObject.takeException(err);

                // only call onOpen once for clients
                if (!handlers.is_server) {
                    // clean onOpen callback so only called in the first handshake and not in every renegotiation
                    // on servers this would require a different approach but it's not needed because our servers will not call handshake multiple times
                    // servers don't support renegotiation
                    this.handlers.onOpen.unprotect();
                    this.handlers.onOpen = .zero;
                }
            } else {
                // call handhsake callback with authorized and authorization error if has one
                const authorization_error: JSValue = if (ssl_error.error_no == 0)
                    JSValue.jsNull()
                else
                    ssl_error.toJS(globalObject);

                result = callback.call(globalObject, this_value, &[_]JSValue{
                    this_value,
                    JSValue.jsBoolean(authorized),
                    authorization_error,
                }) catch |err| globalObject.takeException(err);
            }

            if (result.toError()) |err_value| {
                _ = handlers.callErrorHandler(this_value, &.{ this_value, err_value });
            }
        }

        pub fn onClose(this: *This, _: Socket, err: c_int, _: ?*anyopaque) void {
            JSC.markBinding(@src());
            log("onClose {s}", .{if (this.handlers.is_server) "S" else "C"});
            this.detachNativeCallback();
            this.socket.detach();
            defer this.deref();
            defer this.markInactive();

            if (this.flags.finalizing) {
                return;
            }

            const handlers = this.handlers;
            const vm = handlers.vm;
            this.poll_ref.unref(vm);

            const callback = handlers.onClose;

            if (callback == .zero)
                return;

            if (vm.isShuttingDown()) {
                return;
            }

            // the handlers must be kept alive for the duration of the function call
            // that way if we need to call the error handler, we can
            var scope = handlers.enter();
            defer scope.exit();

            const globalObject = handlers.globalObject;
            const this_value = this.getThisValue(globalObject);
            var js_error: JSValue = .js_undefined;
            if (err != 0) {
                // errors here are always a read error
                js_error = bun.sys.Error.fromCodeInt(err, .read).toJSC(globalObject);
            }

            _ = callback.call(globalObject, this_value, &[_]JSValue{
                this_value,
                js_error,
            }) catch |e| {
                _ = handlers.callErrorHandler(this_value, &.{ this_value, globalObject.takeError(e) });
            };
        }

        pub fn onData(this: *This, _: Socket, data: []const u8) void {
            JSC.markBinding(@src());
            if (this.socket.isDetached()) return;
            log("onData {s} ({d})", .{ if (this.handlers.is_server) "S" else "C", data.len });
            if (this.native_callback.onData(data)) return;

            const handlers = this.handlers;
            const callback = handlers.onData;
            if (callback == .zero or this.flags.finalizing) return;
            if (handlers.vm.isShuttingDown()) {
                return;
            }

            const globalObject = handlers.globalObject;
            const this_value = this.getThisValue(globalObject);
            const output_value = handlers.binary_type.toJS(data, globalObject);

            // the handlers must be kept alive for the duration of the function call
            // that way if we need to call the error handler, we can
            var scope = handlers.enter();
            defer scope.exit();

            // const encoding = handlers.encoding;
            _ = callback.call(globalObject, this_value, &[_]JSValue{
                this_value,
                output_value,
            }) catch |err| {
                _ = handlers.callErrorHandler(this_value, &.{ this_value, globalObject.takeError(err) });
            };
        }

        pub fn getData(_: *This, _: *JSC.JSGlobalObject) JSValue {
            log("getData()", .{});
            return .js_undefined;
        }

        pub fn setData(this: *This, globalObject: *JSC.JSGlobalObject, value: JSC.JSValue) void {
            log("setData()", .{});
            This.js.dataSetCached(this.this_value, globalObject, value);
        }

        pub fn getListener(this: *This, _: *JSC.JSGlobalObject) JSValue {
            if (!this.handlers.is_server or this.socket.isDetached()) {
                return .js_undefined;
            }

            const l: *Listener = @fieldParentPtr("handlers", this.handlers);
            return l.strong_self.get() orelse .js_undefined;
        }

        pub fn getReadyState(this: *This, _: *JSC.JSGlobalObject) JSValue {
            if (this.socket.isDetached()) {
                return JSValue.jsNumber(@as(i32, -1));
            } else if (this.socket.isClosed()) {
                return JSValue.jsNumber(@as(i32, 0));
            } else if (this.socket.isEstablished()) {
                return JSValue.jsNumber(@as(i32, 1));
            } else if (this.socket.isShutdown()) {
                return JSValue.jsNumber(@as(i32, -2));
            } else {
                return JSValue.jsNumber(@as(i32, 2));
            }
        }

        pub fn getAuthorized(this: *This, _: *JSC.JSGlobalObject) JSValue {
            log("getAuthorized()", .{});
            return JSValue.jsBoolean(this.flags.authorized);
        }

        pub fn timeout(this: *This, globalObject: *JSC.JSGlobalObject, callframe: *JSC.CallFrame) bun.JSError!JSValue {
            JSC.markBinding(@src());
            const args = callframe.arguments_old(1);
            if (this.socket.isDetached()) return .js_undefined;
            if (args.len == 0) {
                return globalObject.throw("Expected 1 argument, got 0", .{});
            }
            const t = args.ptr[0].coerce(i32, globalObject);
            if (t < 0) {
                return globalObject.throw("Timeout must be a positive integer", .{});
            }
            log("timeout({d})", .{t});

            this.socket.setTimeout(@as(c_uint, @intCast(t)));

            return .js_undefined;
        }

        pub fn getAuthorizationError(this: *This, globalObject: *JSC.JSGlobalObject, _: *JSC.CallFrame) bun.JSError!JSValue {
            JSC.markBinding(@src());

            if (this.socket.isDetached()) {
                return JSValue.jsNull();
            }

            // this error can change if called in different stages of hanshake
            // is very usefull to have this feature depending on the user workflow
            const ssl_error = this.socket.getVerifyError();
            if (ssl_error.error_no == 0) {
                return JSValue.jsNull();
            }

            const code = if (ssl_error.code == null) "" else ssl_error.code[0..bun.len(ssl_error.code)];

            const reason = if (ssl_error.reason == null) "" else ssl_error.reason[0..bun.len(ssl_error.reason)];

            const fallback = JSC.SystemError{
                .code = bun.String.createUTF8(code),
                .message = bun.String.createUTF8(reason),
            };

            return fallback.toErrorInstance(globalObject);
        }

        pub fn write(this: *This, globalObject: *JSC.JSGlobalObject, callframe: *JSC.CallFrame) bun.JSError!JSValue {
            JSC.markBinding(@src());

            if (this.socket.isDetached()) {
                return JSValue.jsNumber(@as(i32, -1));
            }

            var args = callframe.argumentsUndef(5);

            return switch (this.writeOrEnd(globalObject, args.mut(), false, false)) {
                .fail => .zero,
                .success => |result| JSValue.jsNumber(result.wrote),
            };
        }

        pub fn getLocalFamily(this: *This, globalThis: *JSC.JSGlobalObject) JSValue {
            if (this.socket.isDetached()) {
                return .js_undefined;
            }

            var buf: [64]u8 = [_]u8{0} ** 64;
            const address_bytes: []const u8 = this.socket.localAddress(&buf) orelse return .js_undefined;
            return switch (address_bytes.len) {
                4 => bun.String.static("IPv4").toJS(globalThis),
                16 => bun.String.static("IPv6").toJS(globalThis),
                else => return .js_undefined,
            };
        }

        pub fn getLocalAddress(this: *This, globalThis: *JSC.JSGlobalObject) JSValue {
            if (this.socket.isDetached()) {
                return .js_undefined;
            }

            var buf: [64]u8 = [_]u8{0} ** 64;
            var text_buf: [512]u8 = undefined;

            const address_bytes: []const u8 = this.socket.localAddress(&buf) orelse return .js_undefined;
            const address: std.net.Address = switch (address_bytes.len) {
                4 => std.net.Address.initIp4(address_bytes[0..4].*, 0),
                16 => std.net.Address.initIp6(address_bytes[0..16].*, 0, 0, 0),
                else => return .js_undefined,
            };

            const text = bun.fmt.formatIp(address, &text_buf) catch unreachable;
            return ZigString.init(text).toJS(globalThis);
        }

        pub fn getLocalPort(this: *This, _: *JSC.JSGlobalObject) JSValue {
            if (this.socket.isDetached()) {
                return .js_undefined;
            }

            return JSValue.jsNumber(this.socket.localPort());
        }

        pub fn getRemoteFamily(this: *This, globalThis: *JSC.JSGlobalObject) JSValue {
            if (this.socket.isDetached()) {
                return .js_undefined;
            }

            var buf: [64]u8 = [_]u8{0} ** 64;
            const address_bytes: []const u8 = this.socket.remoteAddress(&buf) orelse return .js_undefined;
            return switch (address_bytes.len) {
                4 => bun.String.static("IPv4").toJS(globalThis),
                16 => bun.String.static("IPv6").toJS(globalThis),
                else => return .js_undefined,
            };
        }

        pub fn getRemoteAddress(this: *This, globalThis: *JSC.JSGlobalObject) JSValue {
            if (this.socket.isDetached()) {
                return .js_undefined;
            }

            var buf: [64]u8 = [_]u8{0} ** 64;
            var text_buf: [512]u8 = undefined;

            const address_bytes: []const u8 = this.socket.remoteAddress(&buf) orelse return .js_undefined;
            const address: std.net.Address = switch (address_bytes.len) {
                4 => std.net.Address.initIp4(address_bytes[0..4].*, 0),
                16 => std.net.Address.initIp6(address_bytes[0..16].*, 0, 0, 0),
                else => return .js_undefined,
            };

            const text = bun.fmt.formatIp(address, &text_buf) catch unreachable;
            return ZigString.init(text).toJS(globalThis);
        }

        pub fn getRemotePort(this: *This, _: *JSC.JSGlobalObject) JSValue {
            if (this.socket.isDetached()) {
                return .js_undefined;
            }

            return JSValue.jsNumber(this.socket.remotePort());
        }

        pub fn writeMaybeCorked(this: *This, buffer: []const u8) i32 {
            if (this.socket.isShutdown() or this.socket.isClosed()) {
                return -1;
            }

            // we don't cork yet but we might later
            if (comptime ssl) {
                // TLS wrapped but in TCP mode
                if (this.wrapped == .tcp) {
                    const res = this.socket.rawWrite(buffer, false);
                    const uwrote: usize = @intCast(@max(res, 0));
                    this.bytes_written += uwrote;
                    log("write({d}) = {d}", .{ buffer.len, res });
                    return res;
                }
            }

            const res = this.socket.write(buffer, false);
            const uwrote: usize = @intCast(@max(res, 0));
            this.bytes_written += uwrote;
            log("write({d}) = {d}", .{ buffer.len, res });
            return res;
        }

        pub fn writeBuffered(this: *This, globalObject: *JSC.JSGlobalObject, callframe: *JSC.CallFrame) bun.JSError!JSValue {
            if (this.socket.isDetached()) {
                this.buffered_data_for_node_net.deinitWithAllocator(bun.default_allocator);
                return JSValue.jsBoolean(false);
            }

            const args = callframe.argumentsUndef(2);

            return switch (this.writeOrEndBuffered(globalObject, args.ptr[0], args.ptr[1], false)) {
                .fail => .zero,
                .success => |result| if (@max(result.wrote, 0) == result.total) .true else .false,
            };
        }

        pub fn endBuffered(this: *This, globalObject: *JSC.JSGlobalObject, callframe: *JSC.CallFrame) bun.JSError!JSValue {
            if (this.socket.isDetached()) {
                this.buffered_data_for_node_net.deinitWithAllocator(bun.default_allocator);
                return JSValue.jsBoolean(false);
            }

            const args = callframe.argumentsUndef(2);
            this.ref();
            defer this.deref();
            return switch (this.writeOrEndBuffered(globalObject, args.ptr[0], args.ptr[1], true)) {
                .fail => .zero,
                .success => |result| brk: {
                    if (result.wrote == result.total) {
                        this.internalFlush();
                    }

                    break :brk JSValue.jsBoolean(@as(usize, @max(result.wrote, 0)) == result.total);
                },
            };
        }

        fn writeOrEndBuffered(this: *This, globalObject: *JSC.JSGlobalObject, data_value: JSC.JSValue, encoding_value: JSC.JSValue, comptime is_end: bool) WriteResult {
            if (this.buffered_data_for_node_net.len == 0) {
                var values = [4]JSC.JSValue{ data_value, .js_undefined, .js_undefined, encoding_value };
                return this.writeOrEnd(globalObject, &values, true, is_end);
            }

            var stack_fallback = std.heap.stackFallback(16 * 1024, bun.default_allocator);
            const allow_string_object = true;
            const buffer: JSC.Node.StringOrBuffer = if (data_value.isUndefined())
                JSC.Node.StringOrBuffer.empty
            else
                JSC.Node.StringOrBuffer.fromJSWithEncodingValueMaybeAsync(globalObject, stack_fallback.get(), data_value, encoding_value, false, allow_string_object) catch {
                    return .fail;
                } orelse {
                    if (!globalObject.hasException()) {
                        globalObject.throwInvalidArgumentTypeValue("data", "string, buffer, or blob", data_value) catch {};
                        return .fail;
                    }
                    return .fail;
                };
            defer buffer.deinit();
            if (!this.flags.end_after_flush and is_end) {
                this.flags.end_after_flush = true;
            }

            if (this.socket.isShutdown() or this.socket.isClosed()) {
                return .{
                    .success = .{
                        .wrote = -1,
                        .total = buffer.slice().len + this.buffered_data_for_node_net.len,
                    },
                };
            }

            const total_to_write: usize = buffer.slice().len + @as(usize, this.buffered_data_for_node_net.len);
            if (total_to_write == 0) {
                if (ssl) {
                    log("total_to_write == 0", .{});
                    if (!data_value.isUndefined()) {
                        log("data_value is not undefined", .{});
                        // special condition for SSL_write(0, "", 0)
                        // we need to send an empty packet after the buffer is flushed and after the handshake is complete
                        // and in this case we need to ignore SSL_write() return value because 0 should not be treated as an error
                        this.flags.empty_packet_pending = true;
                        if (!this.tryWriteEmptyPacket()) {
                            return .{ .success = .{
                                .wrote = -1,
                                .total = total_to_write,
                            } };
                        }
                    }
                }

                return .{ .success = .{} };
            }

            const wrote: i32 = brk: {
                if (comptime !ssl and Environment.isPosix) {
                    // fast-ish path: use writev() to avoid cloning to another buffer.
                    if (this.socket.socket == .connected and buffer.slice().len > 0) {
                        const rc = this.socket.socket.connected.write2(ssl, this.buffered_data_for_node_net.slice(), buffer.slice());
                        const written: usize = @intCast(@max(rc, 0));
                        const leftover = total_to_write -| written;
                        if (leftover == 0) {
                            this.buffered_data_for_node_net.deinitWithAllocator(bun.default_allocator);
                            this.buffered_data_for_node_net = .{};
                            break :brk rc;
                        }

                        const remaining_in_buffered_data = this.buffered_data_for_node_net.slice()[@min(written, this.buffered_data_for_node_net.len)..];
                        const remaining_in_input_data = buffer.slice()[@min(this.buffered_data_for_node_net.len -| written, buffer.slice().len)..];

                        if (written > 0) {
                            if (remaining_in_buffered_data.len > 0) {
                                var input_buffer = this.buffered_data_for_node_net.slice();
                                _ = bun.c.memmove(input_buffer.ptr, input_buffer.ptr[written..], remaining_in_buffered_data.len);
                                this.buffered_data_for_node_net.len = @truncate(remaining_in_buffered_data.len);
                            }
                        }

                        if (remaining_in_input_data.len > 0) {
                            this.buffered_data_for_node_net.append(bun.default_allocator, remaining_in_input_data) catch bun.outOfMemory();
                        }

                        break :brk rc;
                    }
                }

                // slower-path: clone the data, do one write.
                this.buffered_data_for_node_net.append(bun.default_allocator, buffer.slice()) catch bun.outOfMemory();
                const rc = this.writeMaybeCorked(this.buffered_data_for_node_net.slice());
                if (rc > 0) {
                    const wrote: usize = @intCast(@max(rc, 0));
                    // did we write everything?
                    // we can free this temporary buffer.
                    if (wrote == this.buffered_data_for_node_net.len) {
                        this.buffered_data_for_node_net.deinitWithAllocator(bun.default_allocator);
                        this.buffered_data_for_node_net = .{};
                    } else {
                        // Otherwise, let's move the temporary buffer back.
                        const len = @as(usize, @intCast(this.buffered_data_for_node_net.len)) - wrote;
                        bun.debugAssert(len <= this.buffered_data_for_node_net.len);
                        bun.debugAssert(len <= this.buffered_data_for_node_net.cap);
                        _ = bun.c.memmove(this.buffered_data_for_node_net.ptr, this.buffered_data_for_node_net.ptr[wrote..], len);
                        this.buffered_data_for_node_net.len = @truncate(len);
                    }
                }

                break :brk rc;
            };

            return .{
                .success = .{
                    .wrote = wrote,
                    .total = total_to_write,
                },
            };
        }

        fn writeOrEnd(this: *This, globalObject: *JSC.JSGlobalObject, args: []JSC.JSValue, buffer_unwritten_data: bool, comptime is_end: bool) WriteResult {
            if (args[0].isUndefined()) {
                if (!this.flags.end_after_flush and is_end) {
                    this.flags.end_after_flush = true;
                }
                log("writeOrEnd undefined", .{});
                return .{ .success = .{} };
            }

            bun.debugAssert(this.buffered_data_for_node_net.len == 0);
            var encoding_value: JSC.JSValue = args[3];
            if (args[2].isString()) {
                encoding_value = args[2];
                args[2] = .js_undefined;
            } else if (args[1].isString()) {
                encoding_value = args[1];
                args[1] = .js_undefined;
            }

            const offset_value = args[1];
            const length_value = args[2];

            if (!encoding_value.isUndefined() and (!offset_value.isUndefined() or !length_value.isUndefined())) {
                return globalObject.throwTODO("Support encoding with offset and length altogether. Only either encoding or offset, length is supported, but not both combinations yet.") catch .fail;
            }

            var stack_fallback = std.heap.stackFallback(16 * 1024, bun.default_allocator);
            const buffer: JSC.Node.BlobOrStringOrBuffer = if (args[0].isUndefined())
                JSC.Node.BlobOrStringOrBuffer{ .string_or_buffer = JSC.Node.StringOrBuffer.empty }
            else
                JSC.Node.BlobOrStringOrBuffer.fromJSWithEncodingValueMaybeAsyncAllowRequestResponse(globalObject, stack_fallback.get(), args[0], encoding_value, false, true) catch {
                    return .fail;
                } orelse {
                    if (!globalObject.hasException()) {
                        return globalObject.throwInvalidArgumentTypeValue("data", "string, buffer, or blob", args[0]) catch .fail;
                    }
                    return .fail;
                };

            defer buffer.deinit();
            if (buffer == .blob and buffer.blob.needsToReadFile()) {
                return globalObject.throw("File blob not supported yet in this function.", .{}) catch .fail;
            }

            const label = if (comptime is_end) "end" else "write";

            const byte_offset: usize = brk: {
                if (offset_value.isUndefined()) break :brk 0;
                if (!offset_value.isAnyInt()) {
                    return globalObject.throwInvalidArgumentType(comptime "Socket." ++ label, "byteOffset", "integer") catch .fail;
                }
                const i = offset_value.toInt64();
                if (i < 0) {
                    return globalObject.throwRangeError(i, .{ .field_name = "byteOffset", .min = 0, .max = JSC.MAX_SAFE_INTEGER }) catch .fail;
                }
                break :brk @intCast(i);
            };

            const byte_length: usize = brk: {
                if (length_value.isUndefined()) break :brk buffer.slice().len;
                if (!length_value.isAnyInt()) {
                    return globalObject.throwInvalidArgumentType(comptime "Socket." ++ label, "byteLength", "integer") catch .fail;
                }

                const l = length_value.toInt64();

                if (l < 0) {
                    return globalObject.throwRangeError(l, .{ .field_name = "byteLength", .min = 0, .max = JSC.MAX_SAFE_INTEGER }) catch .fail;
                }
                break :brk @intCast(l);
            };

            var bytes = buffer.slice();

            if (byte_offset > bytes.len) {
                return globalObject.throwRangeError(@as(i64, @intCast(byte_offset)), .{ .field_name = "byteOffset", .min = 0, .max = @intCast(bytes.len) }) catch .fail;
            }

            bytes = bytes[byte_offset..];

            if (byte_length > bytes.len) {
                return globalObject.throwRangeError(@as(i64, @intCast(byte_length)), .{ .field_name = "byteLength", .min = 0, .max = @intCast(bytes.len) }) catch .fail;
            }

            bytes = bytes[0..byte_length];

            if (globalObject.hasException()) {
                return .fail;
            }

            if (this.socket.isShutdown() or this.socket.isClosed()) {
                return .{
                    .success = .{
                        .wrote = -1,
                        .total = bytes.len,
                    },
                };
            }
            if (!this.flags.end_after_flush and is_end) {
                this.flags.end_after_flush = true;
            }

            if (bytes.len == 0) {
                if (ssl) {
                    log("writeOrEnd 0", .{});
                    // special condition for SSL_write(0, "", 0)
                    // we need to send an empty packet after the buffer is flushed and after the handshake is complete
                    // and in this case we need to ignore SSL_write() return value because 0 should not be treated as an error
                    this.flags.empty_packet_pending = true;
                    if (!this.tryWriteEmptyPacket()) {
                        return .{ .success = .{
                            .wrote = -1,
                            .total = bytes.len,
                        } };
                    }
                }
                return .{ .success = .{} };
            }
            log("writeOrEnd {d}", .{bytes.len});
            const wrote = this.writeMaybeCorked(bytes);
            const uwrote: usize = @intCast(@max(wrote, 0));
            if (buffer_unwritten_data) {
                const remaining = bytes[uwrote..];
                if (remaining.len > 0) {
                    this.buffered_data_for_node_net.append(bun.default_allocator, remaining) catch bun.outOfMemory();
                }
            }

            return .{
                .success = .{
                    .wrote = wrote,
                    .total = bytes.len,
                },
            };
        }

        fn tryWriteEmptyPacket(this: *This) bool {
            if (ssl) {
                // just mimic the side-effect dont actually write empty non-TLS data onto the socket, we just wanna to have same behavior of node.js
                if (!this.flags.handshake_complete or this.buffered_data_for_node_net.len > 0) return false;

                this.flags.empty_packet_pending = false;
                return true;
            }
            return false;
        }

        fn canEndAfterFlush(this: *This) bool {
            return this.flags.is_active and this.flags.end_after_flush and !this.flags.empty_packet_pending and this.buffered_data_for_node_net.len == 0;
        }

        fn internalFlush(this: *This) void {
            if (this.buffered_data_for_node_net.len > 0) {
                const written: usize = @intCast(@max(this.socket.write(this.buffered_data_for_node_net.slice(), false), 0));
                this.bytes_written += written;
                if (written > 0) {
                    if (this.buffered_data_for_node_net.len > written) {
                        const remaining = this.buffered_data_for_node_net.slice()[written..];
                        _ = bun.c.memmove(this.buffered_data_for_node_net.ptr, remaining.ptr, remaining.len);
                        this.buffered_data_for_node_net.len = @truncate(remaining.len);
                    } else {
                        this.buffered_data_for_node_net.deinitWithAllocator(bun.default_allocator);
                        this.buffered_data_for_node_net = .{};
                    }
                }
            }

            _ = this.tryWriteEmptyPacket();
            this.socket.flush();

            if (this.canEndAfterFlush()) {
                this.markInactive();
            }
        }

        pub fn flush(this: *This, _: *JSC.JSGlobalObject, _: *JSC.CallFrame) bun.JSError!JSValue {
            JSC.markBinding(@src());
            this.internalFlush();
            return .js_undefined;
        }

        pub fn terminate(this: *This, _: *JSC.JSGlobalObject, _: *JSC.CallFrame) bun.JSError!JSValue {
            JSC.markBinding(@src());
            this.closeAndDetach(.failure);
            return .js_undefined;
        }

        pub fn shutdown(this: *This, _: *JSC.JSGlobalObject, callframe: *JSC.CallFrame) bun.JSError!JSValue {
            JSC.markBinding(@src());
            const args = callframe.arguments_old(1);
            if (args.len > 0 and args.ptr[0].toBoolean()) {
                this.socket.shutdownRead();
            } else {
                this.socket.shutdown();
            }

            return .js_undefined;
        }

        pub fn close(this: *This, globalObject: *JSC.JSGlobalObject, callframe: *JSC.CallFrame) bun.JSError!JSValue {
            JSC.markBinding(@src());
            _ = callframe;
            this.socket.close(.normal);
            this.socket.detach();
            this.poll_ref.unref(globalObject.bunVM());
            return .js_undefined;
        }

        pub fn end(this: *This, globalObject: *JSC.JSGlobalObject, callframe: *JSC.CallFrame) bun.JSError!JSValue {
            JSC.markBinding(@src());

            var args = callframe.argumentsUndef(5);

            log("end({d} args)", .{args.len});
            if (this.socket.isDetached()) {
                return JSValue.jsNumber(@as(i32, -1));
            }

            this.ref();
            defer this.deref();

            return switch (this.writeOrEnd(globalObject, args.mut(), false, true)) {
                .fail => .zero,
                .success => |result| brk: {
                    if (result.wrote == result.total) {
                        this.internalFlush();
                    }
                    break :brk JSValue.jsNumber(result.wrote);
                },
            };
        }

        pub fn jsRef(this: *This, globalObject: *JSC.JSGlobalObject, _: *JSC.CallFrame) bun.JSError!JSValue {
            JSC.markBinding(@src());
            if (this.socket.isDetached()) this.ref_pollref_on_connect = true;
            if (this.socket.isDetached()) return .js_undefined;
            this.poll_ref.ref(globalObject.bunVM());
            return .js_undefined;
        }

        pub fn jsUnref(this: *This, globalObject: *JSC.JSGlobalObject, _: *JSC.CallFrame) bun.JSError!JSValue {
            JSC.markBinding(@src());
            if (this.socket.isDetached()) this.ref_pollref_on_connect = false;
            this.poll_ref.unref(globalObject.bunVM());
            return .js_undefined;
        }

        pub fn deinit(this: *This) void {
            this.markInactive();
            this.detachNativeCallback();

            this.buffered_data_for_node_net.deinitWithAllocator(bun.default_allocator);

            this.poll_ref.unref(JSC.VirtualMachine.get());
            // need to deinit event without being attached
            if (this.flags.owned_protos) {
                if (this.protos) |protos| {
                    this.protos = null;
                    default_allocator.free(protos);
                }
            }

            if (this.server_name) |server_name| {
                this.server_name = null;
                default_allocator.free(server_name);
            }

            if (this.connection) |connection| {
                this.connection = null;
                connection.deinit();
            }
            if (this.socket_context) |socket_context| {
                this.socket_context = null;
                socket_context.deinit(ssl);
            }
            bun.destroy(this);
        }

        pub fn finalize(this: *This) void {
            log("finalize() {d} {}", .{ @intFromPtr(this), this.socket_context != null });
            this.flags.finalizing = true;
            if (!this.socket.isClosed()) {
                this.closeAndDetach(.failure);
            }

            this.deref();
        }

        pub fn reload(this: *This, globalObject: *JSC.JSGlobalObject, callframe: *JSC.CallFrame) bun.JSError!JSValue {
            const args = callframe.arguments_old(1);

            if (args.len < 1) {
                return globalObject.throw("Expected 1 argument", .{});
            }

            if (this.socket.isDetached()) {
                return .js_undefined;
            }

            const opts = args.ptr[0];
            if (opts.isEmptyOrUndefinedOrNull() or opts.isBoolean() or !opts.isObject()) {
                return globalObject.throw("Expected options object", .{});
            }

            const socket_obj = try opts.get(globalObject, "socket") orelse {
                return globalObject.throw("Expected \"socket\" option", .{});
            };

            const handlers = try Handlers.fromJS(globalObject, socket_obj, this.handlers.is_server);

            var prev_handlers = this.handlers;
            prev_handlers.unprotect();
            this.handlers.* = handlers; // TODO: this is a memory leak
            this.handlers.protect();

            return .js_undefined;
        }

        pub fn disableRenegotiation(this: *This, _: *JSC.JSGlobalObject, _: *JSC.CallFrame) bun.JSError!JSValue {
            if (comptime ssl == false) {
                return .js_undefined;
            }
            const ssl_ptr = this.socket.ssl() orelse return .js_undefined;
            BoringSSL.SSL_set_renegotiate_mode(ssl_ptr, BoringSSL.ssl_renegotiate_never);
            return .js_undefined;
        }

        pub fn setVerifyMode(this: *This, globalObject: *JSC.JSGlobalObject, callframe: *JSC.CallFrame) bun.JSError!JSValue {
            if (comptime ssl == false) {
                return .js_undefined;
            }
            if (this.socket.isDetached()) {
                return .js_undefined;
            }

            const args = callframe.arguments_old(2);

            if (args.len < 2) {
                return globalObject.throw("Expected requestCert and rejectUnauthorized arguments", .{});
            }
            const request_cert_js = args.ptr[0];
            const reject_unauthorized_js = args.ptr[1];
            if (!request_cert_js.isBoolean() or !reject_unauthorized_js.isBoolean()) {
                return globalObject.throw("Expected requestCert and rejectUnauthorized arguments to be boolean", .{});
            }

            const request_cert = request_cert_js.toBoolean();
            const reject_unauthorized = request_cert_js.toBoolean();
            var verify_mode: c_int = BoringSSL.SSL_VERIFY_NONE;
            if (this.handlers.is_server) {
                if (request_cert) {
                    verify_mode = BoringSSL.SSL_VERIFY_PEER;
                    if (reject_unauthorized)
                        verify_mode |= BoringSSL.SSL_VERIFY_FAIL_IF_NO_PEER_CERT;
                }
            }
            const ssl_ptr = this.socket.ssl();
            // we always allow and check the SSL certificate after the handshake or renegotiation
            BoringSSL.SSL_set_verify(ssl_ptr, verify_mode, alwaysAllowSSLVerifyCallback);
            return .js_undefined;
        }

        pub fn renegotiate(this: *This, globalObject: *JSC.JSGlobalObject, _: *JSC.CallFrame) bun.JSError!JSValue {
            if (comptime ssl == false) {
                return .js_undefined;
            }

            const ssl_ptr = this.socket.ssl() orelse return .js_undefined;
            BoringSSL.ERR_clear_error();
            if (BoringSSL.SSL_renegotiate(ssl_ptr) != 1) {
                return globalObject.throwValue(getSSLException(globalObject, "SSL_renegotiate error"));
            }
            return .js_undefined;
        }

        pub fn getTLSTicket(this: *This, globalObject: *JSC.JSGlobalObject, _: *JSC.CallFrame) bun.JSError!JSValue {
            if (comptime ssl == false) {
                return .js_undefined;
            }

            const ssl_ptr = this.socket.ssl() orelse return .js_undefined;
            const session = BoringSSL.SSL_get_session(ssl_ptr) orelse return .js_undefined;
            var ticket: [*c]const u8 = undefined;
            var length: usize = 0;
            //The pointer is only valid while the connection is in use so we need to copy it
            BoringSSL.SSL_SESSION_get0_ticket(session, @as([*c][*c]const u8, @ptrCast(&ticket)), &length);

            if (ticket == null or length == 0) {
                return .js_undefined;
            }

            return JSC.ArrayBuffer.createBuffer(globalObject, ticket[0..length]);
        }

        pub fn setSession(this: *This, globalObject: *JSC.JSGlobalObject, callframe: *JSC.CallFrame) bun.JSError!JSValue {
            if (comptime ssl == false) {
                return .js_undefined;
            }

            if (this.socket.isDetached()) {
                return .js_undefined;
            }

            const args = callframe.arguments_old(1);

            if (args.len < 1) {
                return globalObject.throw("Expected session to be a string, Buffer or TypedArray", .{});
            }

            const session_arg = args.ptr[0];
            var arena: bun.ArenaAllocator = bun.ArenaAllocator.init(bun.default_allocator);
            defer arena.deinit();

            if (try JSC.Node.StringOrBuffer.fromJS(globalObject, arena.allocator(), session_arg)) |sb| {
                defer sb.deinit();
                const session_slice = sb.slice();
                const ssl_ptr = this.socket.ssl();
                var tmp = @as([*c]const u8, @ptrCast(session_slice.ptr));
                const session = BoringSSL.d2i_SSL_SESSION(null, &tmp, @as(c_long, @intCast(session_slice.len))) orelse return .js_undefined;
                if (BoringSSL.SSL_set_session(ssl_ptr, session) != 1) {
                    return globalObject.throwValue(getSSLException(globalObject, "SSL_set_session error"));
                }
                return .js_undefined;
            } else {
                return globalObject.throw("Expected session to be a string, Buffer or TypedArray", .{});
            }
        }

        pub fn getSession(this: *This, globalObject: *JSC.JSGlobalObject, _: *JSC.CallFrame) bun.JSError!JSValue {
            if (comptime ssl == false) {
                return .js_undefined;
            }

            const ssl_ptr = this.socket.ssl() orelse return .js_undefined;
            const session = BoringSSL.SSL_get_session(ssl_ptr) orelse return .js_undefined;
            const size = BoringSSL.i2d_SSL_SESSION(session, null);
            if (size <= 0) {
                return .js_undefined;
            }

            const buffer_size = @as(usize, @intCast(size));
            var buffer = JSValue.createBufferFromLength(globalObject, buffer_size);
            var buffer_ptr = @as([*c]u8, @ptrCast(buffer.asArrayBuffer(globalObject).?.ptr));

            const result_size = BoringSSL.i2d_SSL_SESSION(session, &buffer_ptr);
            bun.assert(result_size == size);
            return buffer;
        }

        pub fn getBytesWritten(this: *This, _: *JSC.JSGlobalObject) JSValue {
            return JSC.JSValue.jsNumber(this.bytes_written + this.buffered_data_for_node_net.len);
        }

        pub fn getALPNProtocol(this: *This, globalObject: *JSC.JSGlobalObject) JSValue {
            if (comptime ssl == false) {
                return JSValue.jsBoolean(false);
            }

            var alpn_proto: [*c]const u8 = null;
            var alpn_proto_len: u32 = 0;

            const ssl_ptr = this.socket.ssl() orelse return JSValue.jsBoolean(false);

            BoringSSL.SSL_get0_alpn_selected(ssl_ptr, &alpn_proto, &alpn_proto_len);
            if (alpn_proto == null or alpn_proto_len == 0) {
                return JSValue.jsBoolean(false);
            }

            const slice = alpn_proto[0..alpn_proto_len];
            if (strings.eql(slice, "h2")) {
                return bun.String.static("h2").toJS(globalObject);
            }
            if (strings.eql(slice, "http/1.1")) {
                return bun.String.static("http/1.1").toJS(globalObject);
            }
            return ZigString.fromUTF8(slice).toJS(globalObject);
        }

        pub fn exportKeyingMaterial(this: *This, globalObject: *JSC.JSGlobalObject, callframe: *JSC.CallFrame) bun.JSError!JSValue {
            if (comptime ssl == false) {
                return .js_undefined;
            }

            if (this.socket.isDetached()) {
                return .js_undefined;
            }

            const args = callframe.arguments_old(3);
            if (args.len < 2) {
                return globalObject.throw("Expected length and label to be provided", .{});
            }
            const length_arg = args.ptr[0];
            if (!length_arg.isNumber()) {
                return globalObject.throw("Expected length to be a number", .{});
            }

            const length = length_arg.coerceToInt64(globalObject);
            if (length < 0) {
                return globalObject.throw("Expected length to be a positive number", .{});
            }

            const label_arg = args.ptr[1];
            if (!label_arg.isString()) {
                return globalObject.throw("Expected label to be a string", .{});
            }

            var label = try label_arg.toSliceOrNull(globalObject);

            defer label.deinit();
            const label_slice = label.slice();
            const ssl_ptr = this.socket.ssl() orelse return .js_undefined;

            if (args.len > 2) {
                const context_arg = args.ptr[2];

                var arena: bun.ArenaAllocator = bun.ArenaAllocator.init(bun.default_allocator);
                defer arena.deinit();

                if (try JSC.Node.StringOrBuffer.fromJS(globalObject, arena.allocator(), context_arg)) |sb| {
                    defer sb.deinit();
                    const context_slice = sb.slice();

                    const buffer_size = @as(usize, @intCast(length));
                    var buffer = JSValue.createBufferFromLength(globalObject, buffer_size);
                    const buffer_ptr = @as([*c]u8, @ptrCast(buffer.asArrayBuffer(globalObject).?.ptr));

                    const result = BoringSSL.SSL_export_keying_material(ssl_ptr, buffer_ptr, buffer_size, @as([*c]const u8, @ptrCast(label_slice.ptr)), label_slice.len, @as([*c]const u8, @ptrCast(context_slice.ptr)), context_slice.len, 1);
                    if (result != 1) {
                        return globalObject.throwValue(getSSLException(globalObject, "Failed to export keying material"));
                    }
                    return buffer;
                } else {
                    return globalObject.throw("Expected context to be a string, Buffer or TypedArray", .{});
                }
            } else {
                const buffer_size = @as(usize, @intCast(length));
                var buffer = JSValue.createBufferFromLength(globalObject, buffer_size);
                const buffer_ptr = @as([*c]u8, @ptrCast(buffer.asArrayBuffer(globalObject).?.ptr));

                const result = BoringSSL.SSL_export_keying_material(ssl_ptr, buffer_ptr, buffer_size, @as([*c]const u8, @ptrCast(label_slice.ptr)), label_slice.len, null, 0, 0);
                if (result != 1) {
                    return globalObject.throwValue(getSSLException(globalObject, "Failed to export keying material"));
                }
                return buffer;
            }
        }

        pub fn getEphemeralKeyInfo(this: *This, globalObject: *JSC.JSGlobalObject, _: *JSC.CallFrame) bun.JSError!JSValue {
            if (comptime ssl == false) {
                return JSValue.jsNull();
            }

            // only available for clients
            if (this.handlers.is_server) {
                return JSValue.jsNull();
            }
            var result = JSValue.createEmptyObject(globalObject, 3);

            const ssl_ptr = this.socket.ssl() orelse return JSValue.jsNull();

            // TODO: investigate better option or compatible way to get the key
            // this implementation follows nodejs but for BoringSSL SSL_get_server_tmp_key will always return 0
            // wich will result in a empty object
            // var raw_key: [*c]BoringSSL.EVP_PKEY = undefined;
            // if (BoringSSL.SSL_get_server_tmp_key(ssl_ptr, @ptrCast([*c][*c]BoringSSL.EVP_PKEY, &raw_key)) == 0) {
            //     return result;
            // }
            const raw_key: [*c]BoringSSL.EVP_PKEY = BoringSSL.SSL_get_privatekey(ssl_ptr);
            if (raw_key == null) {
                return result;
            }

            const kid = BoringSSL.EVP_PKEY_id(raw_key);
            const bits = BoringSSL.EVP_PKEY_bits(raw_key);

            switch (kid) {
                BoringSSL.EVP_PKEY_DH => {
                    result.put(globalObject, ZigString.static("type"), bun.String.static("DH").toJS(globalObject));
                    result.put(globalObject, ZigString.static("size"), JSValue.jsNumber(bits));
                },

                BoringSSL.EVP_PKEY_EC, BoringSSL.EVP_PKEY_X25519, BoringSSL.EVP_PKEY_X448 => {
                    var curve_name: []const u8 = undefined;
                    if (kid == BoringSSL.EVP_PKEY_EC) {
                        const ec = BoringSSL.EVP_PKEY_get1_EC_KEY(raw_key);
                        const nid = BoringSSL.EC_GROUP_get_curve_name(BoringSSL.EC_KEY_get0_group(ec));
                        const nid_str = BoringSSL.OBJ_nid2sn(nid);
                        if (nid_str != null) {
                            curve_name = nid_str[0..bun.len(nid_str)];
                        } else {
                            curve_name = "";
                        }
                    } else {
                        const kid_str = BoringSSL.OBJ_nid2sn(kid);
                        if (kid_str != null) {
                            curve_name = kid_str[0..bun.len(kid_str)];
                        } else {
                            curve_name = "";
                        }
                    }
                    result.put(globalObject, ZigString.static("type"), bun.String.static("ECDH").toJS(globalObject));
                    result.put(globalObject, ZigString.static("name"), ZigString.fromUTF8(curve_name).toJS(globalObject));
                    result.put(globalObject, ZigString.static("size"), JSValue.jsNumber(bits));
                },
                else => {},
            }
            return result;
        }

        pub fn getCipher(this: *This, globalObject: *JSC.JSGlobalObject, _: *JSC.CallFrame) bun.JSError!JSValue {
            if (comptime ssl == false) {
                return .js_undefined;
            }

            const ssl_ptr = this.socket.ssl() orelse return .js_undefined;
            const cipher = BoringSSL.SSL_get_current_cipher(ssl_ptr);
            var result = JSValue.createEmptyObject(globalObject, 3);

            if (cipher == null) {
                result.put(globalObject, ZigString.static("name"), JSValue.jsNull());
                result.put(globalObject, ZigString.static("standardName"), JSValue.jsNull());
                result.put(globalObject, ZigString.static("version"), JSValue.jsNull());
                return result;
            }

            const name = BoringSSL.SSL_CIPHER_get_name(cipher);
            if (name == null) {
                result.put(globalObject, ZigString.static("name"), JSValue.jsNull());
            } else {
                result.put(globalObject, ZigString.static("name"), ZigString.fromUTF8(name[0..bun.len(name)]).toJS(globalObject));
            }

            const standard_name = BoringSSL.SSL_CIPHER_standard_name(cipher);
            if (standard_name == null) {
                result.put(globalObject, ZigString.static("standardName"), JSValue.jsNull());
            } else {
                result.put(globalObject, ZigString.static("standardName"), ZigString.fromUTF8(standard_name[0..bun.len(standard_name)]).toJS(globalObject));
            }

            const version = BoringSSL.SSL_CIPHER_get_version(cipher);
            if (version == null) {
                result.put(globalObject, ZigString.static("version"), JSValue.jsNull());
            } else {
                result.put(globalObject, ZigString.static("version"), ZigString.fromUTF8(version[0..bun.len(version)]).toJS(globalObject));
            }

            return result;
        }

        pub fn getTLSPeerFinishedMessage(this: *This, globalObject: *JSC.JSGlobalObject, _: *JSC.CallFrame) bun.JSError!JSValue {
            if (comptime ssl == false) {
                return .js_undefined;
            }

            const ssl_ptr = this.socket.ssl() orelse return .js_undefined;
            // We cannot just pass nullptr to SSL_get_peer_finished()
            // because it would further be propagated to memcpy(),
            // where the standard requirements as described in ISO/IEC 9899:2011
            // sections 7.21.2.1, 7.21.1.2, and 7.1.4, would be violated.
            // Thus, we use a dummy byte.
            var dummy: [1]u8 = undefined;
            const size = BoringSSL.SSL_get_peer_finished(ssl_ptr, @as(*anyopaque, @ptrCast(&dummy)), @sizeOf(@TypeOf(dummy)));
            if (size == 0) return .js_undefined;

            const buffer_size = @as(usize, @intCast(size));
            var buffer = JSValue.createBufferFromLength(globalObject, buffer_size);
            const buffer_ptr = @as(*anyopaque, @ptrCast(buffer.asArrayBuffer(globalObject).?.ptr));

            const result_size = BoringSSL.SSL_get_peer_finished(ssl_ptr, buffer_ptr, buffer_size);
            bun.assert(result_size == size);
            return buffer;
        }

        pub fn getTLSFinishedMessage(this: *This, globalObject: *JSC.JSGlobalObject, _: *JSC.CallFrame) bun.JSError!JSValue {
            if (comptime ssl == false) {
                return .js_undefined;
            }

            const ssl_ptr = this.socket.ssl() orelse return .js_undefined;
            // We cannot just pass nullptr to SSL_get_finished()
            // because it would further be propagated to memcpy(),
            // where the standard requirements as described in ISO/IEC 9899:2011
            // sections 7.21.2.1, 7.21.1.2, and 7.1.4, would be violated.
            // Thus, we use a dummy byte.
            var dummy: [1]u8 = undefined;
            const size = BoringSSL.SSL_get_finished(ssl_ptr, @as(*anyopaque, @ptrCast(&dummy)), @sizeOf(@TypeOf(dummy)));
            if (size == 0) return .js_undefined;

            const buffer_size = @as(usize, @intCast(size));
            var buffer = JSValue.createBufferFromLength(globalObject, buffer_size);
            const buffer_ptr = @as(*anyopaque, @ptrCast(buffer.asArrayBuffer(globalObject).?.ptr));

            const result_size = BoringSSL.SSL_get_finished(ssl_ptr, buffer_ptr, buffer_size);
            bun.assert(result_size == size);
            return buffer;
        }

        pub fn getSharedSigalgs(this: *This, globalObject: *JSC.JSGlobalObject, _: *JSC.CallFrame) bun.JSError!JSValue {
            JSC.markBinding(@src());
            if (comptime ssl == false) {
                return JSValue.jsNull();
            }

            const ssl_ptr = this.socket.ssl() orelse return JSValue.jsNull();

            const nsig = BoringSSL.SSL_get_shared_sigalgs(ssl_ptr, 0, null, null, null, null, null);

            const array = try JSC.JSValue.createEmptyArray(globalObject, @as(usize, @intCast(nsig)));

            for (0..@as(usize, @intCast(nsig))) |i| {
                var hash_nid: c_int = 0;
                var sign_nid: c_int = 0;
                var sig_with_md: []const u8 = "";

                _ = BoringSSL.SSL_get_shared_sigalgs(ssl_ptr, @as(c_int, @intCast(i)), &sign_nid, &hash_nid, null, null, null);
                switch (sign_nid) {
                    BoringSSL.EVP_PKEY_RSA => {
                        sig_with_md = "RSA";
                    },
                    BoringSSL.EVP_PKEY_RSA_PSS => {
                        sig_with_md = "RSA-PSS";
                    },

                    BoringSSL.EVP_PKEY_DSA => {
                        sig_with_md = "DSA";
                    },

                    BoringSSL.EVP_PKEY_EC => {
                        sig_with_md = "ECDSA";
                    },

                    BoringSSL.NID_ED25519 => {
                        sig_with_md = "Ed25519";
                    },

                    BoringSSL.NID_ED448 => {
                        sig_with_md = "Ed448";
                    },
                    BoringSSL.NID_id_GostR3410_2001 => {
                        sig_with_md = "gost2001";
                    },

                    BoringSSL.NID_id_GostR3410_2012_256 => {
                        sig_with_md = "gost2012_256";
                    },
                    BoringSSL.NID_id_GostR3410_2012_512 => {
                        sig_with_md = "gost2012_512";
                    },
                    else => {
                        const sn_str = BoringSSL.OBJ_nid2sn(sign_nid);
                        if (sn_str != null) {
                            sig_with_md = sn_str[0..bun.len(sn_str)];
                        } else {
                            sig_with_md = "UNDEF";
                        }
                    },
                }

                const hash_str = BoringSSL.OBJ_nid2sn(hash_nid);
                if (hash_str != null) {
                    const hash_str_len = bun.len(hash_str);
                    const hash_slice = hash_str[0..hash_str_len];
                    const buffer = bun.default_allocator.alloc(u8, sig_with_md.len + hash_str_len + 1) catch bun.outOfMemory();
                    defer bun.default_allocator.free(buffer);

                    bun.copy(u8, buffer, sig_with_md);
                    buffer[sig_with_md.len] = '+';
                    bun.copy(u8, buffer[sig_with_md.len + 1 ..], hash_slice);
                    array.putIndex(globalObject, @as(u32, @intCast(i)), JSC.ZigString.fromUTF8(buffer).toJS(globalObject));
                } else {
                    const buffer = bun.default_allocator.alloc(u8, sig_with_md.len + 6) catch bun.outOfMemory();
                    defer bun.default_allocator.free(buffer);

                    bun.copy(u8, buffer, sig_with_md);
                    bun.copy(u8, buffer[sig_with_md.len..], "+UNDEF");
                    array.putIndex(globalObject, @as(u32, @intCast(i)), JSC.ZigString.fromUTF8(buffer).toJS(globalObject));
                }
            }
            return array;
        }

        pub fn getTLSVersion(this: *This, globalObject: *JSC.JSGlobalObject, _: *JSC.CallFrame) bun.JSError!JSValue {
            JSC.markBinding(@src());
            if (comptime ssl == false) {
                return JSValue.jsNull();
            }

            const ssl_ptr = this.socket.ssl() orelse return JSValue.jsNull();
            const version = BoringSSL.SSL_get_version(ssl_ptr);
            if (version == null) return JSValue.jsNull();
            const version_len = bun.len(version);
            if (version_len == 0) return JSValue.jsNull();
            const slice = version[0..version_len];
            return ZigString.fromUTF8(slice).toJS(globalObject);
        }

        pub fn setMaxSendFragment(this: *This, globalObject: *JSC.JSGlobalObject, callframe: *JSC.CallFrame) bun.JSError!JSValue {
            JSC.markBinding(@src());
            if (comptime ssl == false) {
                return JSValue.jsBoolean(false);
            }

            const args = callframe.arguments_old(1);

            if (args.len < 1) {
                return globalObject.throw("Expected size to be a number", .{});
            }

            const arg = args.ptr[0];
            if (!arg.isNumber()) {
                return globalObject.throw("Expected size to be a number", .{});
            }
            const size = args.ptr[0].coerceToInt64(globalObject);
            if (size < 1) {
                return globalObject.throw("Expected size to be greater than 1", .{});
            }
            if (size > 16384) {
                return globalObject.throw("Expected size to be less than 16385", .{});
            }

            const ssl_ptr = this.socket.ssl() orelse return JSValue.jsBoolean(false);
            return JSValue.jsBoolean(BoringSSL.SSL_set_max_send_fragment(ssl_ptr, @as(usize, @intCast(size))) == 1);
        }

        pub fn getPeerCertificate(this: *This, globalObject: *JSC.JSGlobalObject, callframe: *JSC.CallFrame) bun.JSError!JSValue {
            JSC.markBinding(@src());
            if (comptime ssl == false) {
                return .js_undefined;
            }

            const args = callframe.arguments_old(1);
            var abbreviated: bool = true;
            if (args.len > 0) {
                const arg = args.ptr[0];
                if (!arg.isBoolean()) {
                    return globalObject.throw("Expected abbreviated to be a boolean", .{});
                }
                abbreviated = arg.toBoolean();
            }

            const ssl_ptr = this.socket.ssl() orelse return .js_undefined;

            if (abbreviated) {
                if (this.handlers.is_server) {
                    const cert = BoringSSL.SSL_get_peer_certificate(ssl_ptr);
                    if (cert) |x509| {
                        return X509.toJS(x509, globalObject);
                    }
                }

                const cert_chain = BoringSSL.SSL_get_peer_cert_chain(ssl_ptr) orelse return .js_undefined;
                const cert = BoringSSL.sk_X509_value(cert_chain, 0) orelse return .js_undefined;
                return X509.toJS(cert, globalObject);
            }
            var cert: ?*BoringSSL.X509 = null;
            if (this.handlers.is_server) {
                cert = BoringSSL.SSL_get_peer_certificate(ssl_ptr);
            }

            const cert_chain = BoringSSL.SSL_get_peer_cert_chain(ssl_ptr);
            const first_cert = if (cert) |c| c else if (cert_chain) |cc| BoringSSL.sk_X509_value(cc, 0) else null;

            if (first_cert == null) {
                return .js_undefined;
            }

            // TODO: we need to support the non abbreviated version of this
            return .js_undefined;
        }

        pub fn getCertificate(this: *This, globalObject: *JSC.JSGlobalObject, _: *JSC.CallFrame) bun.JSError!JSValue {
            if (comptime ssl == false) {
                return .js_undefined;
            }
            const ssl_ptr = this.socket.ssl() orelse return .js_undefined;
            const cert = BoringSSL.SSL_get_certificate(ssl_ptr);

            if (cert) |x509| {
                return X509.toJS(x509, globalObject);
            }
            return .js_undefined;
        }

        pub fn getPeerX509Certificate(this: *This, globalObject: *JSC.JSGlobalObject, _: *JSC.CallFrame) bun.JSError!JSValue {
            if (comptime ssl == false) {
                return .js_undefined;
            }
            const ssl_ptr = this.socket.ssl() orelse return .js_undefined;
            const cert = BoringSSL.SSL_get_peer_certificate(ssl_ptr);
            if (cert) |x509| {
                return X509.toJSObject(x509, globalObject);
            }
            return .js_undefined;
        }

        pub fn getX509Certificate(this: *This, globalObject: *JSC.JSGlobalObject, _: *JSC.CallFrame) bun.JSError!JSValue {
            if (comptime ssl == false) {
                return .js_undefined;
            }

            const ssl_ptr = this.socket.ssl() orelse return .js_undefined;
            const cert = BoringSSL.SSL_get_certificate(ssl_ptr);
            if (cert) |x509| {
                return X509.toJSObject(x509.ref(), globalObject);
            }
            return .js_undefined;
        }

        pub fn getServername(this: *This, globalObject: *JSC.JSGlobalObject, _: *JSC.CallFrame) bun.JSError!JSValue {
            if (comptime ssl == false) {
                return .js_undefined;
            }
            const ssl_ptr = this.socket.ssl();

            const servername = BoringSSL.SSL_get_servername(ssl_ptr, BoringSSL.TLSEXT_NAMETYPE_host_name);
            if (servername == null) {
                return .js_undefined;
            }
            return ZigString.fromUTF8(servername[0..bun.len(servername)]).toJS(globalObject);
        }

        pub fn setServername(this: *This, globalObject: *JSC.JSGlobalObject, callframe: *JSC.CallFrame) bun.JSError!JSValue {
            if (comptime ssl == false) {
                return .js_undefined;
            }

            if (this.handlers.is_server) {
                return globalObject.throw("Cannot issue SNI from a TLS server-side socket", .{});
            }

            const args = callframe.arguments_old(1);
            if (args.len < 1) {
                return globalObject.throw("Expected 1 argument", .{});
            }

            const server_name = args.ptr[0];
            if (!server_name.isString()) {
                return globalObject.throw("Expected \"serverName\" to be a string", .{});
            }

            const slice = try (try server_name.getZigString(globalObject)).toOwnedSlice(bun.default_allocator);
            if (this.server_name) |old| {
                this.server_name = slice;
                default_allocator.free(old);
            } else {
                this.server_name = slice;
            }

            const host = normalizeHost(@as([]const u8, slice));
            if (host.len > 0) {
                var ssl_ptr = this.socket.ssl() orelse return .js_undefined;

                if (ssl_ptr.isInitFinished()) {
                    // match node.js exceptions
                    return globalObject.throw("Already started.", .{});
                }
                const host__ = default_allocator.dupeZ(u8, host) catch bun.outOfMemory();
                defer default_allocator.free(host__);
                ssl_ptr.setHostname(host__);
            }

            return .js_undefined;
        }

        // this invalidates the current socket returning 2 new sockets
        // one for non-TLS and another for TLS
        // handlers for non-TLS are preserved
        pub fn upgradeTLS(this: *This, globalObject: *JSC.JSGlobalObject, callframe: *JSC.CallFrame) bun.JSError!JSValue {
            JSC.markBinding(@src());
            const this_js = callframe.this();

            if (comptime ssl) {
                return .js_undefined;
            }
            if (this.socket.isDetached() or this.socket.isNamedPipe()) {
                return .js_undefined;
            }
            const args = callframe.arguments_old(1);

            if (args.len < 1) {
                return globalObject.throw("Expected 1 arguments", .{});
            }

            var success = false;

            const opts = args.ptr[0];
            if (opts.isEmptyOrUndefinedOrNull() or opts.isBoolean() or !opts.isObject()) {
                return globalObject.throw("Expected options object", .{});
            }

            const socket_obj = try opts.get(globalObject, "socket") orelse {
                return globalObject.throw("Expected \"socket\" option", .{});
            };
            if (globalObject.hasException()) {
                return .zero;
            }

            const handlers = try Handlers.fromJS(globalObject, socket_obj, this.handlers.is_server);

            if (globalObject.hasException()) {
                return .zero;
            }

            var ssl_opts: ?JSC.API.ServerConfig.SSLConfig = null;
            defer {
                if (!success) {
                    if (ssl_opts) |*ssl_config| {
                        ssl_config.deinit();
                    }
                }
            }

            if (try opts.getTruthy(globalObject, "tls")) |tls| {
                if (tls.isBoolean()) {
                    if (tls.toBoolean()) {
                        ssl_opts = JSC.API.ServerConfig.SSLConfig.zero;
                    }
                } else {
                    if (try JSC.API.ServerConfig.SSLConfig.fromJS(JSC.VirtualMachine.get(), globalObject, tls)) |ssl_config| {
                        ssl_opts = ssl_config;
                    }
                }
            }

            if (globalObject.hasException()) {
                return .zero;
            }

            if (ssl_opts == null) {
                return globalObject.throw("Expected \"tls\" option", .{});
            }

            var default_data = JSValue.zero;
            if (try opts.fastGet(globalObject, .data)) |default_data_value| {
                default_data = default_data_value;
                default_data.ensureStillAlive();
            }
            if (globalObject.hasException()) {
                return .zero;
            }

            var socket_config = ssl_opts.?;
            ssl_opts = null;
            defer socket_config.deinit();
            const options = socket_config.asUSockets();

            const protos = socket_config.protos;
            const protos_len = socket_config.protos_len;

            const ext_size = @sizeOf(WrappedSocket);

            var handlers_ptr = bun.default_allocator.create(Handlers) catch bun.outOfMemory();
            handlers_ptr.* = handlers;
            handlers_ptr.protect();
            var tls = bun.new(TLSSocket, .{
                .ref_count = .init(),
                .handlers = handlers_ptr,
                .this_value = .zero,
                .socket = TLSSocket.Socket.detached,
                .connection = if (this.connection) |c| c.clone() else null,
                .wrapped = .tls,
                .protos = if (protos) |p| (bun.default_allocator.dupe(u8, p[0..protos_len]) catch bun.outOfMemory()) else null,
                .server_name = if (socket_config.server_name) |server_name| (bun.default_allocator.dupe(u8, server_name[0..bun.len(server_name)]) catch bun.outOfMemory()) else null,
                .socket_context = null, // only set after the wrapTLS
                .flags = .{
                    .is_active = false,
                },
            });

            const TCPHandler = NewWrappedHandler(false);

            // reconfigure context to use the new wrapper handlers
            Socket.unsafeConfigure(this.socket.context().?, true, true, WrappedSocket, TCPHandler);
            const TLSHandler = NewWrappedHandler(true);
            const new_socket = this.socket.wrapTLS(options, ext_size, true, WrappedSocket, TLSHandler) orelse {
                const err = BoringSSL.ERR_get_error();
                defer if (err != 0) BoringSSL.ERR_clear_error();
                tls.wrapped = .none;

                // Reset config to TCP
                uws.NewSocketHandler(false).configure(
                    this.socket.context().?,
                    true,
                    *TCPSocket,
                    struct {
                        pub const onOpen = NewSocket(false).onOpen;
                        pub const onClose = NewSocket(false).onClose;
                        pub const onData = NewSocket(false).onData;
                        pub const onWritable = NewSocket(false).onWritable;
                        pub const onTimeout = NewSocket(false).onTimeout;
                        pub const onConnectError = NewSocket(false).onConnectError;
                        pub const onEnd = NewSocket(false).onEnd;
                        pub const onHandshake = NewSocket(false).onHandshake;
                    },
                );

                tls.deref();

                handlers_ptr.unprotect();
                bun.default_allocator.destroy(handlers_ptr);

                // If BoringSSL gave us an error code, let's use it.
                if (err != 0 and !globalObject.hasException()) {
                    return globalObject.throwValue(bun.BoringSSL.ERR_toJS(globalObject, err));
                }

                // If BoringSSL did not give us an error code, let's throw a generic error.
                if (!globalObject.hasException()) {
                    return globalObject.throw("Failed to upgrade socket from TCP -> TLS. Is the TLS config correct?", .{});
                }

                return .js_undefined;
            };

            // Do not create the JS Wrapper object until _after_ we've validated the TLS config.
            // Otherwise, JSC will GC it and the lifetime gets very complicated.
            const tls_js_value = tls.getThisValue(globalObject);
            TLSSocket.js.dataSetCached(tls_js_value, globalObject, default_data);

            tls.socket = new_socket;
            const new_context = new_socket.context().?;
            tls.socket_context = new_context; // owns the new tls context that have a ref from the old one
            tls.ref();
            const vm = handlers.vm;

            var raw_handlers_ptr = bun.default_allocator.create(Handlers) catch bun.outOfMemory();
            raw_handlers_ptr.* = .{
                .vm = vm,
                .globalObject = globalObject,
                .onOpen = this.handlers.onOpen,
                .onClose = this.handlers.onClose,
                .onData = this.handlers.onData,
                .onWritable = this.handlers.onWritable,
                .onTimeout = this.handlers.onTimeout,
                .onConnectError = this.handlers.onConnectError,
                .onEnd = this.handlers.onEnd,
                .onError = this.handlers.onError,
                .onHandshake = this.handlers.onHandshake,
                .binary_type = this.handlers.binary_type,
                .is_server = this.handlers.is_server,
            };

            raw_handlers_ptr.protect();

            const raw = bun.new(TLSSocket, .{
                .ref_count = .init(),
                .handlers = raw_handlers_ptr,
                .this_value = .zero,
                .socket = new_socket,
                .connection = if (this.connection) |c| c.clone() else null,
                .wrapped = .tcp,
                .protos = null,
                .socket_context = new_context.ref(true),
            });
            raw.ref();

            const raw_js_value = raw.getThisValue(globalObject);
            if (JSSocketType(ssl).dataGetCached(this_js)) |raw_default_data| {
                raw_default_data.ensureStillAlive();
                TLSSocket.js.dataSetCached(raw_js_value, globalObject, raw_default_data);
            }

            // marks both as active
            raw.markActive();
            // this will keep tls alive until socket.open() is called to start TLS certificate and the handshake process
            // open is not immediately called because we need to set bunSocketInternal
            tls.markActive();

            // we're unrefing the original instance and refing the TLS instance
            tls.poll_ref.ref(this.handlers.vm);

            // mark both instances on socket data
            if (new_socket.ext(WrappedSocket)) |ctx| {
                ctx.* = .{ .tcp = raw, .tls = tls };
            }

            if (this.flags.is_active) {
                this.poll_ref.disable();
                this.flags.is_active = false;
                // will free handlers when hits 0 active connections
                // the connection can be upgraded inside a handler call so we need to guarantee that it will be still alive
                this.handlers.markInactive();

                this.has_pending_activity.store(false, .release);
            }

            const array = try JSC.JSValue.createEmptyArray(globalObject, 2);
            array.putIndex(globalObject, 0, raw_js_value);
            array.putIndex(globalObject, 1, tls_js_value);

            defer this.deref();

            // detach and invalidate the old instance
            this.detachNativeCallback();
            this.socket.detach();

            // start TLS handshake after we set extension on the socket
            new_socket.startTLS(!handlers_ptr.is_server);

            success = true;
            return array;
        }
    };
}

pub const TCPSocket = NewSocket(false);
pub const TLSSocket = NewSocket(true);

pub const WrappedSocket = extern struct {
    // both shares the same socket but one behaves as TLS and the other as TCP
    tls: *TLSSocket,
    tcp: *TLSSocket,
};

pub fn NewWrappedHandler(comptime tls: bool) type {
    const Socket = uws.NewSocketHandler(true);
    return struct {
        pub fn onOpen(this: WrappedSocket, socket: Socket) void {
            // only TLS will call onOpen
            if (comptime tls) {
                TLSSocket.onOpen(this.tls, socket);
            }
        }

        pub fn onEnd(this: WrappedSocket, socket: Socket) void {
            if (comptime tls) {
                TLSSocket.onEnd(this.tls, socket);
            } else {
                TLSSocket.onEnd(this.tcp, socket);
            }
        }

        pub fn onHandshake(this: WrappedSocket, socket: Socket, success: i32, ssl_error: uws.us_bun_verify_error_t) void {
            // only TLS will call onHandshake
            if (comptime tls) {
                TLSSocket.onHandshake(this.tls, socket, success, ssl_error);
            }
        }

        pub fn onClose(this: WrappedSocket, socket: Socket, err: c_int, data: ?*anyopaque) void {
            if (comptime tls) {
                TLSSocket.onClose(this.tls, socket, err, data);
            } else {
                TLSSocket.onClose(this.tcp, socket, err, data);
            }
        }

        pub fn onData(this: WrappedSocket, socket: Socket, data: []const u8) void {
            if (comptime tls) {
                TLSSocket.onData(this.tls, socket, data);
            } else {
                // tedius use this (tedius is a pure-javascript implementation of TDS protocol used to interact with instances of Microsoft's SQL Server)
                TLSSocket.onData(this.tcp, socket, data);
            }
        }

        pub const onFd = null;

        pub fn onWritable(this: WrappedSocket, socket: Socket) void {
            if (comptime tls) {
                TLSSocket.onWritable(this.tls, socket);
            } else {
                TLSSocket.onWritable(this.tcp, socket);
            }
        }

        pub fn onTimeout(this: WrappedSocket, socket: Socket) void {
            if (comptime tls) {
                TLSSocket.onTimeout(this.tls, socket);
            } else {
                TLSSocket.onTimeout(this.tcp, socket);
            }
        }

        pub fn onLongTimeout(this: WrappedSocket, socket: Socket) void {
            if (comptime tls) {
                TLSSocket.onTimeout(this.tls, socket);
            } else {
                TLSSocket.onTimeout(this.tcp, socket);
            }
        }

        pub fn onConnectError(this: WrappedSocket, socket: Socket, errno: c_int) void {
            if (comptime tls) {
                TLSSocket.onConnectError(this.tls, socket, errno);
            } else {
                TLSSocket.onConnectError(this.tcp, socket, errno);
            }
        }
    };
}

pub const DuplexUpgradeContext = struct {
    upgrade: uws.UpgradedDuplex,
    // We only us a tls and not a raw socket when upgrading a Duplex, Duplex dont support socketpairs
    tls: ?*TLSSocket,
    // task used to deinit the context in the next tick, vm is used to enqueue the task
    vm: *JSC.VirtualMachine,
    task: JSC.AnyTask,
    task_event: EventState = .StartTLS,
    ssl_config: ?JSC.API.ServerConfig.SSLConfig,
    is_open: bool = false,

    pub const EventState = enum(u8) {
        StartTLS,
        Close,
    };

    pub const new = bun.TrivialNew(DuplexUpgradeContext);

    fn onOpen(this: *DuplexUpgradeContext) void {
        this.is_open = true;
        const socket = TLSSocket.Socket.fromDuplex(&this.upgrade);

        if (this.tls) |tls| {
            tls.onOpen(socket);
        }
    }

    fn onData(this: *DuplexUpgradeContext, decoded_data: []const u8) void {
        const socket = TLSSocket.Socket.fromDuplex(&this.upgrade);

        if (this.tls) |tls| {
            tls.onData(socket, decoded_data);
        }
    }

    fn onHandshake(this: *DuplexUpgradeContext, success: bool, ssl_error: uws.us_bun_verify_error_t) void {
        const socket = TLSSocket.Socket.fromDuplex(&this.upgrade);

        if (this.tls) |tls| {
            tls.onHandshake(socket, @intFromBool(success), ssl_error);
        }
    }

    fn onEnd(this: *DuplexUpgradeContext) void {
        const socket = TLSSocket.Socket.fromDuplex(&this.upgrade);
        if (this.tls) |tls| {
            tls.onEnd(socket);
        }
    }

    fn onWritable(this: *DuplexUpgradeContext) void {
        const socket = TLSSocket.Socket.fromDuplex(&this.upgrade);

        if (this.tls) |tls| {
            tls.onWritable(socket);
        }
    }

    fn onError(this: *DuplexUpgradeContext, err_value: JSC.JSValue) void {
        if (this.is_open) {
            if (this.tls) |tls| {
                tls.handleError(err_value);
            }
        } else {
            if (this.tls) |tls| {
                tls.handleConnectError(@intFromEnum(bun.sys.SystemErrno.ECONNREFUSED));
            }
        }
    }

    fn onTimeout(this: *DuplexUpgradeContext) void {
        const socket = TLSSocket.Socket.fromDuplex(&this.upgrade);

        if (this.tls) |tls| {
            tls.onTimeout(socket);
        }
    }

    fn onClose(this: *DuplexUpgradeContext) void {
        const socket = TLSSocket.Socket.fromDuplex(&this.upgrade);

        if (this.tls) |tls| {
            tls.onClose(socket, 0, null);
        }

        this.deinitInNextTick();
    }

    fn runEvent(this: *DuplexUpgradeContext) void {
        switch (this.task_event) {
            .StartTLS => {
                if (this.ssl_config) |config| {
                    this.upgrade.startTLS(config, true) catch |err| {
                        switch (err) {
                            error.OutOfMemory => {
                                bun.outOfMemory();
                            },
                            else => {
                                const errno = @intFromEnum(bun.sys.SystemErrno.ECONNREFUSED);
                                if (this.tls) |tls| {
                                    const socket = TLSSocket.Socket.fromDuplex(&this.upgrade);

                                    tls.handleConnectError(errno);
                                    tls.onClose(socket, errno, null);
                                }
                            },
                        }
                    };
                    this.ssl_config.?.deinit();
                    this.ssl_config = null;
                }
            },
            .Close => {
                this.upgrade.close();
            },
        }
    }

    fn deinitInNextTick(this: *DuplexUpgradeContext) void {
        this.task_event = .Close;
        this.vm.enqueueTask(JSC.Task.init(&this.task));
    }

    fn startTLS(this: *DuplexUpgradeContext) void {
        this.task_event = .StartTLS;
        this.vm.enqueueTask(JSC.Task.init(&this.task));
    }

    fn deinit(this: *DuplexUpgradeContext) void {
        if (this.tls) |tls| {
            this.tls = null;
            tls.deref();
        }
        this.upgrade.deinit();
        this.destroy();
    }
};

pub const WindowsNamedPipeListeningContext = if (Environment.isWindows) struct {
    uvPipe: uv.Pipe = std.mem.zeroes(uv.Pipe),
    listener: ?*Listener,
    globalThis: *JSC.JSGlobalObject,
    vm: *JSC.VirtualMachine,
    ctx: ?*BoringSSL.SSL_CTX = null, // server reuses the same ctx
    pub const new = bun.TrivialNew(WindowsNamedPipeListeningContext);

    fn onClientConnect(this: *WindowsNamedPipeListeningContext, status: uv.ReturnCode) void {
        if (status != uv.ReturnCode.zero or this.vm.isShuttingDown() or this.listener == null) {
            // connection dropped or vm is shutting down or we are deiniting/closing
            return;
        }
        const listener = this.listener.?;
        const socket: WindowsNamedPipeContext.SocketType = brk: {
            if (this.ctx) |_| {
                break :brk .{ .tls = Listener.onNamePipeCreated(true, listener) };
            } else {
                break :brk .{ .tcp = Listener.onNamePipeCreated(false, listener) };
            }
        };

        const client = WindowsNamedPipeContext.create(this.globalThis, socket);

        const result = client.named_pipe.getAcceptedBy(&this.uvPipe, this.ctx);
        if (result == .err) {
            // connection dropped
            client.deinit();
        }
    }

    fn onPipeClosed(pipe: *uv.Pipe) callconv(.C) void {
        const this: *WindowsNamedPipeListeningContext = @ptrCast(@alignCast(pipe.data));
        this.deinit();
    }

    pub fn closePipeAndDeinit(this: *WindowsNamedPipeListeningContext) void {
        this.listener = null;
        this.uvPipe.data = this;
        this.uvPipe.close(onPipeClosed);
    }

    pub fn listen(globalThis: *JSC.JSGlobalObject, path: []const u8, backlog: i32, ssl_config: ?JSC.API.ServerConfig.SSLConfig, listener: *Listener) !*WindowsNamedPipeListeningContext {
        const this = WindowsNamedPipeListeningContext.new(.{
            .globalThis = globalThis,
            .vm = globalThis.bunVM(),
            .listener = listener,
        });

        if (ssl_config) |ssl_options| {
            bun.BoringSSL.load();

            const ctx_opts: uws.SocketContext.BunSocketContextOptions = JSC.API.ServerConfig.SSLConfig.asUSockets(ssl_options);
            var err: uws.create_bun_socket_error_t = .none;
            // Create SSL context using uSockets to match behavior of node.js
            const ctx = ctx_opts.createSSLContext(&err) orelse return error.InvalidOptions; // invalid options
            this.ctx = ctx;
        }

        const initResult = this.uvPipe.init(this.vm.uvLoop(), false);
        if (initResult == .err) {
            return error.FailedToInitPipe;
        }
        if (path[path.len - 1] == 0) {
            // is already null terminated
            const slice_z = path[0 .. path.len - 1 :0];
            this.uvPipe.listenNamedPipe(slice_z, backlog, this, onClientConnect).unwrap() catch return error.FailedToBindPipe;
        } else {
            var path_buf: bun.PathBuffer = undefined;
            // we need to null terminate the path
            const len = @min(path.len, path_buf.len - 1);

            @memcpy(path_buf[0..len], path[0..len]);
            path_buf[len] = 0;
            const slice_z = path_buf[0..len :0];
            this.uvPipe.listenNamedPipe(slice_z, backlog, this, onClientConnect).unwrap() catch return error.FailedToBindPipe;
        }
        //TODO: add readableAll and writableAll support if someone needs it
        // if(uv.uv_pipe_chmod(&this.uvPipe, uv.UV_WRITABLE | uv.UV_READABLE) != 0) {
        // this.closePipeAndDeinit();
        // return error.FailedChmodPipe;
        //}

        return this;
    }

    fn runEvent(this: *WindowsNamedPipeListeningContext) void {
        switch (this.task_event) {
            .deinit => {
                this.deinit();
            },
            .none => @panic("Invalid event state"),
        }
    }

    fn deinitInNextTick(this: *WindowsNamedPipeListeningContext) void {
        bun.assert(this.task_event != .deinit);
        this.task_event = .deinit;
        this.vm.enqueueTask(JSC.Task.init(&this.task));
    }

    fn deinit(this: *WindowsNamedPipeListeningContext) void {
        this.listener = null;
        if (this.ctx) |ctx| {
            this.ctx = null;
            BoringSSL.SSL_CTX_free(ctx);
        }
        bun.destroy(this);
    }
} else void;

pub const WindowsNamedPipeContext = if (Environment.isWindows) struct {
    named_pipe: uws.WindowsNamedPipe,
    socket: SocketType,

    // task used to deinit the context in the next tick, vm is used to enqueue the task
    vm: *JSC.VirtualMachine,
    globalThis: *JSC.JSGlobalObject,
    task: JSC.AnyTask,
    task_event: EventState = .none,
    is_open: bool = false,

    pub const EventState = enum(u8) {
        deinit,
        none,
    };

    pub const SocketType = union(enum) {
        tls: *TLSSocket,
        tcp: *TCPSocket,
        none: void,
    };

    pub const new = bun.TrivialNew(WindowsNamedPipeContext);
    const log = Output.scoped(.WindowsNamedPipeContext, false);

    fn onOpen(this: *WindowsNamedPipeContext) void {
        this.is_open = true;
        switch (this.socket) {
            .tls => |tls| {
                const socket = TLSSocket.Socket.fromNamedPipe(&this.named_pipe);
                tls.onOpen(socket);
            },
            .tcp => |tcp| {
                const socket = TCPSocket.Socket.fromNamedPipe(&this.named_pipe);
                tcp.onOpen(socket);
            },
            .none => {},
        }
    }

    fn onData(this: *WindowsNamedPipeContext, decoded_data: []const u8) void {
        switch (this.socket) {
            .tls => |tls| {
                const socket = TLSSocket.Socket.fromNamedPipe(&this.named_pipe);
                tls.onData(socket, decoded_data);
            },
            .tcp => |tcp| {
                const socket = TCPSocket.Socket.fromNamedPipe(&this.named_pipe);
                tcp.onData(socket, decoded_data);
            },
            .none => {},
        }
    }

    fn onHandshake(this: *WindowsNamedPipeContext, success: bool, ssl_error: uws.us_bun_verify_error_t) void {
        switch (this.socket) {
            .tls => |tls| {
                const socket = TLSSocket.Socket.fromNamedPipe(&this.named_pipe);
                tls.onHandshake(socket, @intFromBool(success), ssl_error);
            },
            .tcp => |tcp| {
                const socket = TCPSocket.Socket.fromNamedPipe(&this.named_pipe);
                tcp.onHandshake(socket, @intFromBool(success), ssl_error);
            },
            .none => {},
        }
    }

    fn onEnd(this: *WindowsNamedPipeContext) void {
        switch (this.socket) {
            .tls => |tls| {
                const socket = TLSSocket.Socket.fromNamedPipe(&this.named_pipe);
                tls.onEnd(socket);
            },
            .tcp => |tcp| {
                const socket = TCPSocket.Socket.fromNamedPipe(&this.named_pipe);
                tcp.onEnd(socket);
            },
            .none => {},
        }
    }

    fn onWritable(this: *WindowsNamedPipeContext) void {
        switch (this.socket) {
            .tls => |tls| {
                const socket = TLSSocket.Socket.fromNamedPipe(&this.named_pipe);
                tls.onWritable(socket);
            },
            .tcp => |tcp| {
                const socket = TCPSocket.Socket.fromNamedPipe(&this.named_pipe);
                tcp.onWritable(socket);
            },
            .none => {},
        }
    }

    fn onError(this: *WindowsNamedPipeContext, err: bun.sys.Error) void {
        if (this.is_open) {
            if (this.vm.isShuttingDown()) {
                // dont touch global just wait to close vm is shutting down
                return;
            }

            switch (this.socket) {
                .tls => |tls| {
                    tls.handleError(err.toJSC(this.globalThis));
                },
                .tcp => |tcp| {
                    tcp.handleError(err.toJSC(this.globalThis));
                },
                else => {},
            }
        } else {
            switch (this.socket) {
                .tls => |tls| {
                    tls.handleConnectError(err.errno);
                },
                .tcp => |tcp| {
                    tcp.handleConnectError(err.errno);
                },
                else => {},
            }
        }
    }

    fn onTimeout(this: *WindowsNamedPipeContext) void {
        switch (this.socket) {
            .tls => |tls| {
                const socket = TLSSocket.Socket.fromNamedPipe(&this.named_pipe);
                tls.onTimeout(socket);
            },
            .tcp => |tcp| {
                const socket = TCPSocket.Socket.fromNamedPipe(&this.named_pipe);
                tcp.onTimeout(socket);
            },
            .none => {},
        }
    }

    fn onClose(this: *WindowsNamedPipeContext) void {
        const socket = this.socket;
        this.socket = .none;
        switch (socket) {
            .tls => |tls| {
                tls.onClose(TLSSocket.Socket.fromNamedPipe(&this.named_pipe), 0, null);
                tls.deref();
            },
            .tcp => |tcp| {
                tcp.onClose(TCPSocket.Socket.fromNamedPipe(&this.named_pipe), 0, null);
                tcp.deref();
            },
            .none => {},
        }

        this.deinitInNextTick();
    }

    fn runEvent(this: *WindowsNamedPipeContext) void {
        switch (this.task_event) {
            .deinit => {
                this.deinit();
            },
            .none => @panic("Invalid event state"),
        }
    }

    fn deinitInNextTick(this: *WindowsNamedPipeContext) void {
        bun.assert(this.task_event != .deinit);
        this.task_event = .deinit;
        this.vm.enqueueTask(JSC.Task.init(&this.task));
    }

    fn create(globalThis: *JSC.JSGlobalObject, socket: SocketType) *WindowsNamedPipeContext {
        const vm = globalThis.bunVM();
        const this = WindowsNamedPipeContext.new(.{
            .vm = vm,
            .globalThis = globalThis,
            .task = undefined,
            .socket = socket,
            .named_pipe = undefined,
        });

        // named_pipe owns the pipe (PipeWriter owns the pipe and will close and deinit it)
        this.named_pipe = uws.WindowsNamedPipe.from(bun.default_allocator.create(uv.Pipe) catch bun.outOfMemory(), .{
            .ctx = this,
            .onOpen = @ptrCast(&WindowsNamedPipeContext.onOpen),
            .onData = @ptrCast(&WindowsNamedPipeContext.onData),
            .onHandshake = @ptrCast(&WindowsNamedPipeContext.onHandshake),
            .onEnd = @ptrCast(&WindowsNamedPipeContext.onEnd),
            .onWritable = @ptrCast(&WindowsNamedPipeContext.onWritable),
            .onError = @ptrCast(&WindowsNamedPipeContext.onError),
            .onTimeout = @ptrCast(&WindowsNamedPipeContext.onTimeout),
            .onClose = @ptrCast(&WindowsNamedPipeContext.onClose),
        }, vm);
        this.task = JSC.AnyTask.New(WindowsNamedPipeContext, WindowsNamedPipeContext.runEvent).init(this);

        switch (socket) {
            .tls => |tls| {
                tls.ref();
            },
            .tcp => |tcp| {
                tcp.ref();
            },
            .none => {},
        }

        return this;
    }

    pub fn open(globalThis: *JSC.JSGlobalObject, fd: bun.FileDescriptor, ssl_config: ?JSC.API.ServerConfig.SSLConfig, socket: SocketType) !*uws.WindowsNamedPipe {
        // TODO: reuse the same context for multiple connections when possibles

        const this = WindowsNamedPipeContext.create(globalThis, socket);

        errdefer {
            switch (socket) {
                .tls => |tls| {
                    tls.handleConnectError(@intFromEnum(bun.sys.SystemErrno.ENOENT));
                },
                .tcp => |tcp| {
                    tcp.handleConnectError(@intFromEnum(bun.sys.SystemErrno.ENOENT));
                },
                .none => {},
            }
            this.deinitInNextTick();
        }
        try this.named_pipe.open(fd, ssl_config).unwrap();
        return &this.named_pipe;
    }

    pub fn connect(globalThis: *JSC.JSGlobalObject, path: []const u8, ssl_config: ?JSC.API.ServerConfig.SSLConfig, socket: SocketType) !*uws.WindowsNamedPipe {
        // TODO: reuse the same context for multiple connections when possibles

        const this = WindowsNamedPipeContext.create(globalThis, socket);
        errdefer {
            switch (socket) {
                .tls => |tls| {
                    tls.handleConnectError(@intFromEnum(bun.sys.SystemErrno.ENOENT));
                },
                .tcp => |tcp| {
                    tcp.handleConnectError(@intFromEnum(bun.sys.SystemErrno.ENOENT));
                },
                .none => {},
            }
            this.deinitInNextTick();
        }

        if (path[path.len - 1] == 0) {
            // is already null terminated
            const slice_z = path[0 .. path.len - 1 :0];
            try this.named_pipe.connect(slice_z, ssl_config).unwrap();
        } else {
            var path_buf: bun.PathBuffer = undefined;
            // we need to null terminate the path
            const len = @min(path.len, path_buf.len - 1);

            @memcpy(path_buf[0..len], path[0..len]);
            path_buf[len] = 0;
            const slice_z = path_buf[0..len :0];
            try this.named_pipe.connect(slice_z, ssl_config).unwrap();
        }
        return &this.named_pipe;
    }

    fn deinit(this: *WindowsNamedPipeContext) void {
        log("deinit", .{});
        const socket = this.socket;
        this.socket = .none;
        switch (socket) {
            .tls => |tls| {
                tls.deref();
            },
            .tcp => |tcp| {
                tcp.deref();
            },
            else => {},
        }

        this.named_pipe.deinit();
        bun.destroy(this);
    }
} else void;

pub fn jsAddServerName(global: *JSC.JSGlobalObject, callframe: *JSC.CallFrame) bun.JSError!JSValue {
    JSC.markBinding(@src());

    const arguments = callframe.arguments_old(3);
    if (arguments.len < 3) {
        return global.throwNotEnoughArguments("addServerName", 3, arguments.len);
    }
    const listener = arguments.ptr[0];
    if (listener.as(Listener)) |this| {
        return this.addServerName(global, arguments.ptr[1], arguments.ptr[2]);
    }
    return global.throw("Expected a Listener instance", .{});
}

pub fn jsUpgradeDuplexToTLS(globalObject: *JSC.JSGlobalObject, callframe: *JSC.CallFrame) bun.JSError!JSValue {
    JSC.markBinding(@src());

    const args = callframe.arguments_old(2);
    if (args.len < 2) {
        return globalObject.throw("Expected 2 arguments", .{});
    }
    const duplex = args.ptr[0];
    // TODO: do better type checking
    if (duplex.isEmptyOrUndefinedOrNull()) {
        return globalObject.throw("Expected a Duplex instance", .{});
    }

    const opts = args.ptr[1];
    if (opts.isEmptyOrUndefinedOrNull() or opts.isBoolean() or !opts.isObject()) {
        return globalObject.throw("Expected options object", .{});
    }

    const socket_obj = try opts.get(globalObject, "socket") orelse {
        return globalObject.throw("Expected \"socket\" option", .{});
    };

    var handlers = try Handlers.fromJS(globalObject, socket_obj, false);

    var ssl_opts: ?JSC.API.ServerConfig.SSLConfig = null;
    if (try opts.getTruthy(globalObject, "tls")) |tls| {
        if (tls.isBoolean()) {
            if (tls.toBoolean()) {
                ssl_opts = JSC.API.ServerConfig.SSLConfig.zero;
            }
        } else {
            if (try JSC.API.ServerConfig.SSLConfig.fromJS(JSC.VirtualMachine.get(), globalObject, tls)) |ssl_config| {
                ssl_opts = ssl_config;
            }
        }
    }
    if (ssl_opts == null) {
        return globalObject.throw("Expected \"tls\" option", .{});
    }

    var default_data = JSValue.zero;
    if (try opts.fastGet(globalObject, .data)) |default_data_value| {
        default_data = default_data_value;
        default_data.ensureStillAlive();
    }

    const socket_config = ssl_opts.?;

    const protos = socket_config.protos;
    const protos_len = socket_config.protos_len;

    const is_server = false; // A duplex socket is always handled as a client

    var handlers_ptr = handlers.vm.allocator.create(Handlers) catch bun.outOfMemory();
    handlers_ptr.* = handlers;
    handlers_ptr.is_server = is_server;
    handlers_ptr.protect();
    var tls = bun.new(TLSSocket, .{
        .ref_count = .init(),
        .handlers = handlers_ptr,
        .this_value = .zero,
        .socket = TLSSocket.Socket.detached,
        .connection = null,
        .wrapped = .tls,
        .protos = if (protos) |p| (bun.default_allocator.dupe(u8, p[0..protos_len]) catch bun.outOfMemory()) else null,
        .server_name = if (socket_config.server_name) |server_name| (bun.default_allocator.dupe(u8, server_name[0..bun.len(server_name)]) catch bun.outOfMemory()) else null,
        .socket_context = null, // only set after the wrapTLS
    });
    const tls_js_value = tls.getThisValue(globalObject);
    TLSSocket.js.dataSetCached(tls_js_value, globalObject, default_data);

    var duplexContext = DuplexUpgradeContext.new(.{
        .upgrade = undefined,
        .tls = tls,
        .vm = globalObject.bunVM(),
        .task = undefined,
        .ssl_config = socket_config,
    });
    tls.ref();

    duplexContext.task = JSC.AnyTask.New(DuplexUpgradeContext, DuplexUpgradeContext.runEvent).init(duplexContext);
    duplexContext.upgrade = uws.UpgradedDuplex.from(globalObject, duplex, .{
        .onOpen = @ptrCast(&DuplexUpgradeContext.onOpen),
        .onData = @ptrCast(&DuplexUpgradeContext.onData),
        .onHandshake = @ptrCast(&DuplexUpgradeContext.onHandshake),
        .onClose = @ptrCast(&DuplexUpgradeContext.onClose),
        .onEnd = @ptrCast(&DuplexUpgradeContext.onEnd),
        .onWritable = @ptrCast(&DuplexUpgradeContext.onWritable),
        .onError = @ptrCast(&DuplexUpgradeContext.onError),
        .onTimeout = @ptrCast(&DuplexUpgradeContext.onTimeout),
        .ctx = @ptrCast(duplexContext),
    });

    tls.socket = TLSSocket.Socket.fromDuplex(&duplexContext.upgrade);
    tls.markActive();
    tls.poll_ref.ref(globalObject.bunVM());

    duplexContext.startTLS();

    const array = try JSC.JSValue.createEmptyArray(globalObject, 2);
    array.putIndex(globalObject, 0, tls_js_value);
    // data, end, drain and close events must be reported
    array.putIndex(globalObject, 1, try duplexContext.upgrade.getJSHandlers(globalObject));

    return array;
}

pub fn jsIsNamedPipeSocket(global: *JSC.JSGlobalObject, callframe: *JSC.CallFrame) bun.JSError!JSValue {
    JSC.markBinding(@src());

    const arguments = callframe.arguments_old(3);
    if (arguments.len < 1) {
        return global.throwNotEnoughArguments("isNamedPipeSocket", 1, arguments.len);
    }
    const socket = arguments.ptr[0];
    if (socket.as(TCPSocket)) |this| {
        return JSC.JSValue.jsBoolean(this.socket.isNamedPipe());
    } else if (socket.as(TLSSocket)) |this| {
        return JSC.JSValue.jsBoolean(this.socket.isNamedPipe());
    }
    return JSC.JSValue.jsBoolean(false);
}

pub fn jsGetBufferedAmount(global: *JSC.JSGlobalObject, callframe: *JSC.CallFrame) bun.JSError!JSValue {
    JSC.markBinding(@src());

    const arguments = callframe.arguments_old(3);
    if (arguments.len < 1) {
        return global.throwNotEnoughArguments("getBufferedAmount", 1, arguments.len);
    }
    const socket = arguments.ptr[0];
    if (socket.as(TCPSocket)) |this| {
        return JSC.JSValue.jsNumber(this.buffered_data_for_node_net.len);
    } else if (socket.as(TLSSocket)) |this| {
        return JSC.JSValue.jsNumber(this.buffered_data_for_node_net.len);
    }
    return JSC.JSValue.jsNumber(0);
}

pub fn jsCreateSocketPair(global: *JSC.JSGlobalObject, _: *JSC.CallFrame) bun.JSError!JSValue {
    JSC.markBinding(@src());

    if (Environment.isWindows) {
        return global.throw("Not implemented on Windows", .{});
    }

    var fds_: [2]std.c.fd_t = .{ 0, 0 };
    const rc = std.c.socketpair(std.posix.AF.UNIX, std.posix.SOCK.STREAM, 0, &fds_);
    if (rc != 0) {
        const err = bun.sys.Error.fromCode(bun.sys.getErrno(rc), .socketpair);
        return global.throwValue(err.toJSC(global));
    }

    _ = bun.FD.fromNative(fds_[0]).updateNonblocking(true);
    _ = bun.FD.fromNative(fds_[1]).updateNonblocking(true);

    const array = try JSC.JSValue.createEmptyArray(global, 2);
    array.putIndex(global, 0, JSC.jsNumber(fds_[0]));
    array.putIndex(global, 1, JSC.jsNumber(fds_[1]));
    return array;
}

pub fn jsSetSocketOptions(global: *JSC.JSGlobalObject, callframe: *JSC.CallFrame) bun.JSError!JSC.JSValue {
    const arguments = callframe.arguments();

    if (arguments.len < 3) {
        return global.throwNotEnoughArguments("setSocketOptions", 3, arguments.len);
    }

    const socket = arguments.ptr[0].as(TCPSocket) orelse {
        return global.throw("Expected a SocketTCP instance", .{});
    };

    const is_for_send_buffer = arguments.ptr[1].toInt32() == 1;
    const is_for_recv_buffer = arguments.ptr[1].toInt32() == 2;
    const buffer_size = arguments.ptr[2].toInt32();
    const file_descriptor = socket.socket.fd();

    if (bun.Environment.isPosix) {
        if (is_for_send_buffer) {
            const result = bun.sys.setsockopt(file_descriptor, std.posix.SOL.SOCKET, std.posix.SO.SNDBUF, buffer_size);
            if (result.asErr()) |err| {
                return global.throwValue(err.toJSC(global));
            }
        } else if (is_for_recv_buffer) {
            const result = bun.sys.setsockopt(file_descriptor, std.posix.SOL.SOCKET, std.posix.SO.RCVBUF, buffer_size);
            if (result.asErr()) |err| {
                return global.throwValue(err.toJSC(global));
            }
        }
    }

    return .js_undefined;
}
