/// Reactor aware IO (file descriptor) operations
module mecca.reactor.io;

import core.stdc.errno;
import unistd = core.sys.posix.unistd;
import fcntl = core.sys.posix.fcntl;
import core.sys.posix.sys.types;
import std.algorithm;
import std.traits;

import mecca.lib.exception;
import mecca.lib.io;
import mecca.lib.string;
import mecca.log;
import mecca.reactor.subsystems.epoll;

private extern(C) nothrow @trusted @nogc {
    int pipe2(ref int[2], int flags);
}

struct ListenerSocket {
}

struct ConnectedSocket {
}

struct DatagramSocket {
}

struct ConnectedDatagramSocket {
}

/// Reactor aware FD wrapper for pipes
struct Pipe {
    ReactorFD fd;

    alias fd this;

    static void create(out Pipe readEnd, out Pipe writeEnd) @trusted @nogc {
        int[2] pipeRawFD;

        errnoEnforceNGC( pipe2(pipeRawFD, fcntl.O_NONBLOCK)>=0, "OS pipe creation failed" );

        readEnd = Pipe( ReactorFD( FD( pipeRawFD[0] ) ) );
        writeEnd = Pipe( ReactorFD( FD( pipeRawFD[1] ) ) );
    }
}

struct File {
    ReactorFD fd;

    alias fd this;

    void open(string pathname, int flags) @trusted @nogc {
        DBG_ASSERT!"open called with O_CREAT but no file mode argument. Flags %x"( (flags & fcntl.O_CREAT)==0, flags );
        open(pathname, flags, 0);
    }

    void open(string pathname, int flags, mode_t mode) @trusted @nogc {
        ASSERT!"open called on already open file."(!fd.isValid);

        int osFd = fcntl.open(toStringzNGC(pathname), flags, mode);
        errnoEnforceNGC( osFd>=0, "Failed to open file" );

        fd = ReactorFD(osFd);
    }
}

/**
 * An FD capable of performing sleeping operations through the reactor, when necessary
 */
struct ReactorFD {
private:
    FD fd;
    Epoll.FdContext* ctx;

public:
    @disable this(this);

    /**
     * Constructor from existing mecca.lib.FD
     *
     * Parameters:
     * fd = bare OS fd. Ownership is handed to the ReactorFD.
     * alreadyNonBlocking = whether the OS fd has NONBLOCKING already set on it. Setting to true saves a call to fcntl, but will hang the
     *             reactor in some cases.
     */
    this(int fd, bool alreadyNonBlocking = false) @safe @nogc {
        this( FD(fd), alreadyNonBlocking );
    }

    /**
     * Constructor from existing mecca.lib.FD
     *
     * Parameters:
     * fd = an FD rvalue
     * alreadyNonBlocking = whether the OS fd has NONBLOCKING already set on it. Setting to true saves a call to fcntl, but will hang the
     *             reactor in some cases.
     */
    this(FD fd, bool alreadyNonBlocking = false) @safe @nogc {
        move( fd, this.fd );
        ctx = epoller.registerFD(this.fd, alreadyNonBlocking);
    }

    ~this() nothrow @safe @nogc {
        close();
    }

    /// Move semantics opAssign
    ref ReactorFD opAssign(ReactorFD rhs) nothrow @safe @nogc {
        swap( rhs.fd, fd );
        swap( rhs.ctx, ctx );

        return this;
    }

    /// Cleanly closes an FD
    void close() nothrow @safe @nogc {
        if( fd.isValid ) {
            assert(ctx !is null);

            epoller.deregisterFd( fd, ctx );

            fd.close();
            ctx = null;
        }
    }

    /// Tests for open descriptor
    @property bool isValid() const pure nothrow @safe @nogc {
        return fd.isValid;
    }

    /// Returns the underlying mecca.lib.io.FD
    @property ref FD get() nothrow @safe @nogc {
        return fd;
    }

    /// Perform reactor aware @safe read
    ssize_t read(void[] buffer) @trusted @nogc {
        return blockingCall!(unistd.read)( buffer.ptr, buffer.length );
    }

    /// Perform reactor aware @safe write
    ssize_t write(void[] buffer) @trusted @nogc {
        return blockingCall!(unistd.write)( buffer.ptr, buffer.length );
    }

package:
    auto blockingCall(alias F)(Parameters!F[1 .. $] args) @system @nogc {
        static assert (is(Parameters!F[0] == int));
        static assert (isSigned!(ReturnType!F));

        while (true) {
            auto ret = fd.osCall!F(args);
            if (ret < 0) {
                if (errno == EAGAIN || errno == EWOULDBLOCK) {
                    epoller.waitForEvent(ctx);
                }
                else {
                    throw mkExFmt!ErrnoException("%s(%s)", __traits(identifier, F), fd.fileNo);
                }
            }
            else {
                return ret;
            }
        }
    }

    auto osCall(alias F)(Parameters!F[1..$] args) nothrow @system @nogc {
        return fd.osCall!F(args);
    }
}

void openReactorEpoll() {
    epoller.open();
}

void closeReactorEpoll() {
    epoller.close();
}

unittest {
    import core.sys.posix.sys.types;

    import mecca.lib.consts;
    import mecca.reactor.reactor;

    theReactor.setup();
    scope(exit) theReactor.teardown();

    openReactorEpoll();
    scope(exit) closeReactorEpoll();

    Pipe pipeRead, pipeWrite;
    Pipe.create(pipeRead, pipeWrite);

    void reader() {
        uint[1024] buffer;
        enum BUFF_SIZE = typeof(buffer).sizeof;
        uint lastNum = -1;

        // Send 2MB over the pipe
        ssize_t res;
        while((res = pipeRead.read(buffer))>0) {
            DEBUG!"Received %s bytes"(res);
            assert(res==BUFF_SIZE, "Short read from pipe");
            assert(buffer[0] == ++lastNum, "Read incorrect value from buffer");
        }

        errnoEnforceNGC(res==0, "Read failed from pipe");
        INFO!"Reader finished"();
        theReactor.stop();
    }

    void writer() {
        uint[1024] buffer;
        enum BUFF_SIZE = typeof(buffer).sizeof;

        // Send 2MB over the pipe
        while(buffer[0] < (2*MB/BUFF_SIZE)) {
            DEBUG!"Sending %s bytes"(BUFF_SIZE);
            ssize_t res = pipeWrite.write(buffer);
            errnoEnforceNGC( res>=0, "Write failed on pipe");
            assert( res==BUFF_SIZE, "Short write to pipe" );
            buffer[0]++;
        }

        INFO!"Writer finished - closing pipe"();
        pipeWrite.close();
    }

    theReactor.spawnFiber(&reader);
    theReactor.spawnFiber(&writer);

    theReactor.start();
}
